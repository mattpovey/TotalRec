import SwiftUI
import AVFoundation
import Speech
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import CoreGraphics

private func configureInitialWindowSize(for window: NSWindow) {
    let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let targetHeight = max(min(visibleFrame.height * 0.55, 900), 520)
    let targetWidth = min(max(visibleFrame.width * 0.55, 900), visibleFrame.width - 80)
    let originX = visibleFrame.midX - targetWidth / 2
    let originY = visibleFrame.midY - targetHeight / 2
    let frame = NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
    window.setFrame(frame, display: true, animate: false)
}
#endif

struct ContentView: View {
    enum WorkflowSection: String, CaseIterable, Identifiable {
        case capture = "Capture"
        case transcript = "Transcript"
        case insights = "Insights"

        var id: String { rawValue }
    }

    enum TranscriptExportFormat: String, CaseIterable, Identifiable {
        case plainText
        case json
        case webVTT
        case srt

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plainText:
                return "Plain Text (.txt)"
            case .json:
                return "JSON (.json)"
            case .webVTT:
                return "WebVTT Caption (.vtt)"
            case .srt:
                return "SubRip Caption (.srt)"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText:
                return .plainText
            case .json:
                return .json
            case .webVTT:
                return UTType(filenameExtension: "vtt") ?? .plainText
            case .srt:
                return UTType(filenameExtension: "srt") ?? .plainText
            }
        }

        func suggestedFilename(hasSpeakerLabels: Bool) -> String {
            switch self {
            case .plainText:
                return hasSpeakerLabels ? "transcript_with_speakers.txt" : "transcript.txt"
            case .json:
                return "transcript.json"
            case .webVTT:
                return "transcript.vtt"
            case .srt:
                return "transcript.srt"
            }
        }
    }

    @EnvironmentObject private var appModel: AppModel

    @State private var showStartFreshRecordingPrompt = false
    @State private var showTranscriptFormatDialog = false
    @State private var showImportOptionsDialog = false
    @State private var showURLImportSheet = false
    @State private var importURLString = ""
    @State private var knownSpeakerNamesInputs = Array(repeating: "", count: 4)
    @State private var knownSpeakerRefsInputs = Array(repeating: "", count: 4)
    @State private var showSettingsSheet = false
    @State private var openAIAPIKey: String = ""
    @State private var tScriptConfiguration = TScriptConfiguration()
    @State private var tScriptModelsResponse: TScriptModelsResponse?
    @State private var isTScriptModelsLoading = false
    @State private var tScriptModelsError: String?
    @AppStorage("openAIChunkingStrategy") private var openAIChunkingStrategy: String = "auto"
    @State private var provider: TranscriptionProvider = .appleCloud
    @State private var nameSuggestionProvider: NameSuggestionProvider = .openAI
    @State private var selectedSection: WorkflowSection = .capture
    @State private var nameSuggestionRequestSignal = 0
    @State private var isNameSuggestionRequestInFlight = false
    @State private var customInsightsPrompt = MeetingNotesService.defaultPrompt
    @State private var selectedInsightsPreset = MeetingNotesService.Preset.meetingNotes
    @State private var useCustomInsightsPrompt = false
    @State private var transcriptViewID = UUID()
    @State private var isKnownSpeakerHintsExpanded = false
    @State private var isTScriptAdvancedOptionsExpanded = false
    @State private var isSessionDiagnosticsExpanded = false
    @State private var sessionPendingDeletion: RecordingSession?

    private let nameSuggestionService = NameSuggestionService()

    init() {
        let config = AIConfigManager.shared.configuration
        _provider = State(initialValue: TranscriptionProvider.fromStoredValue(config.defaultProvider))
        _openAIAPIKey = State(initialValue: AIConfigManager.shared.openAIKey() ?? "")
        _tScriptConfiguration = State(initialValue: config.tscript)
        if let storedSuggestionProvider = NameSuggestionProvider(rawValue: config.nameSuggestionProvider.lowercased()) {
            _nameSuggestionProvider = State(initialValue: storedSuggestionProvider)
        } else {
            _nameSuggestionProvider = State(initialValue: .openAI)
        }
    }

    private var hasPartialKnownSpeaker: Bool {
        let count = min(knownSpeakerNamesInputs.count, knownSpeakerRefsInputs.count)
        for index in 0..<count {
            let name = knownSpeakerNamesInputs[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = knownSpeakerRefsInputs[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if (name.isEmpty && !ref.isEmpty) || (!name.isEmpty && ref.isEmpty) {
                return true
            }
        }
        return false
    }

    private var preparedKnownSpeakers: [OpenAITranscriber.KnownSpeaker] {
        let count = min(4, min(knownSpeakerNamesInputs.count, knownSpeakerRefsInputs.count))
        return (0..<count).compactMap { index in
            let name = knownSpeakerNamesInputs[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = knownSpeakerRefsInputs[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !ref.isEmpty else { return nil }
            return OpenAITranscriber.KnownSpeaker(name: name, reference: ref)
        }
    }

    private var isOpenAIKeyConfigured: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tScriptBaseURLConfigured: Bool {
        !tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedTScriptBaseURL: String {
        tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedTScriptBaseURL: String {
        guard !trimmedTScriptBaseURL.isEmpty else { return "" }
        if trimmedTScriptBaseURL.contains("://") {
            return trimmedTScriptBaseURL
        }
        return "https://\(trimmedTScriptBaseURL)"
    }

    private var tScriptBaseURLScheme: String? {
        guard !normalizedTScriptBaseURL.isEmpty else { return nil }
        return URL(string: normalizedTScriptBaseURL)?.scheme?.lowercased()
    }

    private var tScriptRequiresHTTPOverride: Bool {
        tScriptBaseURLScheme == "http" && !tScriptConfiguration.allowInsecureHTTP
    }

    private var tScriptUsesHTTPOverride: Bool {
        tScriptBaseURLScheme == "http" && tScriptConfiguration.allowInsecureHTTP
    }

    private var tScriptTransportReadinessItem: ReadinessItem {
        if !tScriptBaseURLConfigured {
            return ReadinessItem(
                title: "Server URL required",
                detail: "Add the TScript server base URL in Settings before using this provider.",
                systemImage: "network.slash",
                tint: .orange
            )
        }
        if tScriptRequiresHTTPOverride {
            return ReadinessItem(
                title: "Secure connection required",
                detail: "This TScript endpoint uses HTTP. Enable the insecure HTTP override in Settings only if you trust this server and network.",
                systemImage: "lock.trianglebadge.exclamationmark",
                tint: .orange
            )
        }
        if tScriptUsesHTTPOverride {
            return ReadinessItem(
                title: "HTTP override enabled",
                detail: "TScript is using plain HTTP because you explicitly allowed it for this private server.",
                systemImage: "exclamationmark.shield.fill",
                tint: .orange
            )
        }
        if tScriptConfiguration.allowInvalidTLSCertificates {
            return ReadinessItem(
                title: "TLS override enabled",
                detail: "The app will accept an invalid TLS certificate for this TScript host. Use this only for a server you control.",
                systemImage: "checkmark.shield.fill",
                tint: .orange
            )
        }
        return ReadinessItem(
            title: "Secure connection ready",
            detail: "TScript is configured to use HTTPS for model discovery and transcription.",
            systemImage: "lock.shield.fill",
            tint: .green
        )
    }

    private var tScriptTransportWarningText: String? {
        if tScriptUsesHTTPOverride {
            return "Insecure HTTP override is enabled for TScript. Use this only on a trusted private network."
        }
        if tScriptConfiguration.allowInvalidTLSCertificates {
            return "Invalid TLS certificate override is enabled for TScript. Only keep this on for a host you control."
        }
        return nil
    }

    private var tScriptModels: [TScriptModel] {
        tScriptModelsResponse?.allModels ?? []
    }

    private var selectedTScriptModelID: String {
        let configured = tScriptConfiguration.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        if let response = tScriptModelsResponse {
            if let defaultID = response.defaultModelID,
               response.models[defaultID]?.runtimeAvailable == true {
                return defaultID
            }
            return response.allModels.first(where: \.runtimeAvailable)?.id ?? response.allModels.first?.id ?? ""
        }
        return ""
    }

    private var selectedTScriptModel: TScriptModel? {
        let selectedID = selectedTScriptModelID
        guard !selectedID.isEmpty else { return nil }
        return tScriptModelsResponse?.models[selectedID]
    }

    private var availableTScriptDiarizationModes: [TScriptDiarizationMode] {
        selectedTScriptModel?.availableDiarizationModes ?? [.off]
    }

    private var effectiveTScriptDiarizationMode: TScriptDiarizationMode {
        if let model = selectedTScriptModel {
            return model.normalizedDiarizationMode(tScriptConfiguration.diarizationMode)
        }
        switch tScriptConfiguration.diarizationMode {
        case .tiny:
            return .standard
        case .off, .standard:
            return tScriptConfiguration.diarizationMode
        }
    }

    private var knownSpeakerHintCount: Int {
        preparedKnownSpeakers.count
    }

    private var openAIChunkingDisplayName: String {
        openAIChunkingStrategy == "none" ? "Single upload" : "Auto chunking"
    }

    private var providerSystemImage: String {
        switch provider {
        case .openAI:
            return "brain.head.profile"
        case .tscript:
            return "server.rack"
        case .appleOnDevice, .appleCloud:
            return "waveform"
        }
    }

    private var transcriptBinding: Binding<TranscriptState> {
        Binding(
            get: { appModel.transcriptState },
            set: { appModel.updateTranscriptState($0) }
        )
    }

    private var hasTranscriptDisplayText: Bool {
        appModel.transcriptState.hasDisplayText
    }

    private var captureTranscriptPreviewText: String {
        appModel.transcriptState.previewText(maxSegments: 8, maxCharacters: 900)
    }

    private var hasCustomSpeakerAliases: Bool {
        for label in appModel.transcriptState.orderedSpeakerLabels {
            let alias = appModel.transcriptState.alias(for: label).trimmingCharacters(in: .whitespacesAndNewlines)
            if alias.caseInsensitiveCompare(label) != .orderedSame {
                return true
            }
        }
        return false
    }

    private var isTranscriptionActionDisabled: Bool {
        appModel.audioURL == nil ||
        appModel.isTranscribing ||
        appModel.isImportingAudio ||
        appModel.isRecording ||
        (provider == .openAI && hasPartialKnownSpeaker) ||
        (provider == .tscript && !tScriptBaseURLConfigured)
    }

    private var formattedDurationSuffix: String {
        guard let duration = appModel.mixedAudioDuration else { return "" }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: " (~%d:%02d)", minutes, seconds)
    }

    private var captureReadinessItems: [ReadinessItem] {
        [
            ReadinessItem(
                title: appModel.audioURL == nil ? "Session audio pending" : "Session audio ready",
                detail: appModel.isRecording
                    ? "Recording is active. Stop when you want to prepare the session audio for transcription."
                    : (appModel.audioURL == nil
                        ? "Start a protected recording or import audio into this session."
                        : "Audio has been prepared\(formattedDurationSuffix) and is ready for transcription."),
                systemImage: appModel.isRecording ? "record.circle.fill" : (appModel.audioURL == nil ? "waveform.badge.plus" : "checkmark.circle.fill"),
                tint: appModel.isRecording ? .red : (appModel.audioURL == nil ? .blue : .green)
            ),
            screenCaptureReadinessItem,
            microphoneReadinessItem,
            ReadinessItem(
                title: "Session safety",
                detail: appModel.hasProtectedActivity
                    ? "This session is locked while recording or processing is active."
                    : "Session switching and exports are safe right now.",
                systemImage: appModel.hasProtectedActivity ? "lock.shield.fill" : "checkmark.shield.fill",
                tint: appModel.hasProtectedActivity ? .blue : .green
            )
        ]
    }

    private var transcriptionReadinessItems: [ReadinessItem] {
        [
            ReadinessItem(
                title: appModel.audioURL == nil ? "Audio required" : "Audio ready",
                detail: appModel.audioURL == nil
                    ? "Capture or import audio before starting transcription."
                    : "The current session audio is available\(formattedDurationSuffix).",
                systemImage: appModel.audioURL == nil ? "waveform.slash" : "waveform.badge.checkmark",
                tint: appModel.audioURL == nil ? .orange : .green
            ),
            ReadinessItem(
                title: "Provider",
                detail: providerReadinessDetail,
                systemImage: providerSystemImage,
                tint: workflowSectionTint(.transcript)
            ),
            transcriptionPrerequisiteItem,
            transcriptionModeReadinessItem
        ]
    }

    private var insightsReadinessItems: [ReadinessItem] {
        let trimmedPrompt = customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesCount = appModel.meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : appModel.meetingNotes.count

        return [
            ReadinessItem(
                title: hasTranscriptDisplayText ? "Transcript ready" : "Transcript required",
                detail: hasTranscriptDisplayText
                    ? "The current session transcript is available for notes generation."
                    : "Generate a transcript before creating meeting notes.",
                systemImage: hasTranscriptDisplayText ? "text.quote.star" : "text.quote",
                tint: hasTranscriptDisplayText ? .green : .orange
            ),
            ReadinessItem(
                title: isOpenAIKeyConfigured ? "API key ready" : "API key required",
                detail: isOpenAIKeyConfigured
                    ? "OpenAI notes generation can run with the current key."
                    : "Add an OpenAI API key in Settings before generating notes.",
                systemImage: isOpenAIKeyConfigured ? "key.fill" : "exclamationmark.triangle.fill",
                tint: isOpenAIKeyConfigured ? .green : .orange
            ),
            ReadinessItem(
                title: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty ? "Custom prompt required" : "Custom prompt ready")
                    : "Preset ready",
                detail: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty
                        ? "Enter a custom prompt or switch back to the preset workflow."
                        : "The custom prompt will override the \(selectedInsightsPreset.rawValue.lowercased()) preset on the next run.")
                    : "\(selectedInsightsPreset.rawValue) is selected for the next notes run.",
                systemImage: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty ? "text.badge.xmark" : "slider.horizontal.below.rectangle")
                    : "sparkles.rectangle.stack",
                tint: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty ? .orange : .indigo)
                    : .green
            ),
            ReadinessItem(
                title: appModel.isGeneratingMeetingNotes ? "Notes in progress" : (notesCount == 0 ? "Notes pending" : "Notes saved"),
                detail: appModel.isGeneratingMeetingNotes
                    ? "A notes job is currently running for this session."
                    : (notesCount == 0
                        ? "Generate notes when you want a structured summary and action list."
                        : "\(notesCount) characters of notes are already stored in this session."),
                systemImage: appModel.isGeneratingMeetingNotes ? "hourglass" : (notesCount == 0 ? "list.bullet.rectangle" : "checkmark.rectangle.stack"),
                tint: appModel.isGeneratingMeetingNotes ? .blue : (notesCount == 0 ? .secondary : .green)
            )
        ]
    }

    private var providerReadinessDetail: String {
        switch provider {
        case .openAI:
            return "OpenAI diarized transcription with server-side auto chunking."
        case .tscript:
            if let model = selectedTScriptModel {
                return "TScript using \(model.displayName) on \(normalizedTScriptBaseURL)."
            }
            return "TScript uses the configured server and model registry to drive model selection and feature gating."
        case .appleOnDevice:
            return "Apple on-device transcription stays local when the platform can handle it."
        case .appleCloud:
            return "Apple cloud transcription can fall back to Apple's speech service."
        }
    }

    private var transcriptionPrerequisiteItem: ReadinessItem {
        switch provider {
        case .openAI:
            return ReadinessItem(
                title: isOpenAIKeyConfigured ? "API key ready" : "API key required",
                detail: isOpenAIKeyConfigured
                    ? "OpenAI is configured and ready for diarized transcription."
                    : "Add an OpenAI API key in Settings before running this provider.",
                systemImage: isOpenAIKeyConfigured ? "key.fill" : "exclamationmark.triangle.fill",
                tint: isOpenAIKeyConfigured ? .green : .orange
            )
        case .tscript:
            if !tScriptBaseURLConfigured ||
                tScriptRequiresHTTPOverride ||
                tScriptUsesHTTPOverride ||
                tScriptConfiguration.allowInvalidTLSCertificates {
                return tScriptTransportReadinessItem
            }

            let detail: String
            let title: String
            let icon: String
            let tint: Color
            if isTScriptModelsLoading {
                title = "Loading models"
                detail = "Refreshing the TScript model registry for the current server."
                icon = "arrow.triangle.2.circlepath"
                tint = .blue
            } else if let error = tScriptModelsError, !error.isEmpty {
                title = "Model registry needs attention"
                detail = error
                icon = "exclamationmark.triangle.fill"
                tint = .orange
            } else if let model = selectedTScriptModel {
                title = model.runtimeAvailable ? "Model ready" : "Model unavailable"
                detail = model.runtimeAvailable
                    ? "\(model.displayName) is available on the current TScript server."
                    : "\(model.displayName) is currently unavailable on the current TScript server."
                icon = model.runtimeAvailable ? "server.rack" : "server.rack"
                tint = model.runtimeAvailable ? .green : .orange
            } else {
                title = "Model registry pending"
                detail = "Refresh models to inspect server capabilities and choose a specific TScript model."
                icon = "square.stack.3d.up.slash"
                tint = .secondary
            }
            return ReadinessItem(
                title: title,
                detail: detail,
                systemImage: icon,
                tint: tint
            )
        case .appleOnDevice, .appleCloud:
            return speechRecognitionReadinessItem
        }
    }

    private var transcriptionModeReadinessItem: ReadinessItem {
        switch provider {
        case .openAI:
            let hintSummary = knownSpeakerHintCount == 0 ? "No known-speaker hints configured." : "\(knownSpeakerHintCount) known-speaker hint\(knownSpeakerHintCount == 1 ? "" : "s") ready."
            let detail = hasPartialKnownSpeaker
                ? "Finish or clear the incomplete speaker-hint rows before you run transcription."
                : "\(openAIChunkingDisplayName) selected. \(hintSummary)"
            return ReadinessItem(
                title: hasPartialKnownSpeaker ? "Speaker hints need attention" : "Upload mode",
                detail: detail,
                systemImage: hasPartialKnownSpeaker ? "person.crop.rectangle.stack.fill" : (openAIChunkingStrategy == "none" ? "arrow.up.doc" : "square.split.2x2"),
                tint: hasPartialKnownSpeaker ? .orange : .indigo
            )
        case .tscript:
            let selectedModelName = selectedTScriptModel?.displayName ?? "Server default"
            let diarization = effectiveTScriptDiarizationMode == .off
                ? "Diarization off"
                : "Diarization: \(effectiveTScriptDiarizationMode.displayName)"
            let timestamps = tScriptConfiguration.timestamps ? "timestamps on" : "timestamps off"
            return ReadinessItem(
                title: selectedTScriptModel?.supportsTimestamps == true || availableTScriptDiarizationModes.count > 1 ? "Model options" : "Model selection",
                detail: "\(selectedModelName) selected with \(timestamps). \(diarization).",
                systemImage: "slider.horizontal.3",
                tint: .indigo
            )
        case .appleOnDevice, .appleCloud:
            return ReadinessItem(
                title: appModel.isTranscribing ? "Transcription in progress" : "Preview behavior",
                detail: appModel.isTranscribing
                    ? "Partial text appears below while Apple transcription runs."
                    : "Apple transcription can stream partial text into the live preview area while it runs.",
                systemImage: appModel.isTranscribing ? "text.badge.clock" : "text.line.first.and.arrowtriangle.forward",
                tint: appModel.isTranscribing ? .blue : .secondary
            )
        }
    }

    private var screenCaptureReadinessItem: ReadinessItem {
#if os(macOS)
        let granted = CGPreflightScreenCaptureAccess()
        return ReadinessItem(
            title: granted ? "Screen recording ready" : "Screen recording required",
            detail: granted
                ? "System audio capture can start immediately."
                : "Grant Screen Recording access before starting a system capture. Audio import still works without it.",
            systemImage: granted ? "display.badge.checkmark" : "exclamationmark.triangle.fill",
            tint: granted ? .green : .orange
        )
#else
        return ReadinessItem(
            title: "Screen recording",
            detail: "System audio readiness is only shown on macOS.",
            systemImage: "display",
            tint: .secondary
        )
#endif
    }

    private var microphoneReadinessItem: ReadinessItem {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return ReadinessItem(
                title: "Microphone ready",
                detail: "Mic access is granted for system-plus-mic recordings.",
                systemImage: "mic.fill",
                tint: .green
            )
        case .notDetermined:
            return ReadinessItem(
                title: "Microphone permission pending",
                detail: "macOS will ask for mic access the first time you start recording.",
                systemImage: "mic.badge.plus",
                tint: .blue
            )
        case .denied, .restricted:
            return ReadinessItem(
                title: "Microphone access blocked",
                detail: "Grant Microphone access in System Settings to capture your voice alongside system audio.",
                systemImage: "mic.slash.fill",
                tint: .orange
            )
        @unknown default:
            return ReadinessItem(
                title: "Microphone status unavailable",
                detail: "The app could not determine microphone authorization state.",
                systemImage: "questionmark.circle",
                tint: .secondary
            )
        }
    }

    private var speechRecognitionReadinessItem: ReadinessItem {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return ReadinessItem(
                title: "Speech access ready",
                detail: "Apple transcription has the speech-recognition permission it needs.",
                systemImage: "waveform.badge.checkmark",
                tint: .green
            )
        case .notDetermined:
            return ReadinessItem(
                title: "Speech permission pending",
                detail: "The system will request speech-recognition permission the first time Apple transcription runs.",
                systemImage: "waveform.badge.plus",
                tint: .blue
            )
        case .denied, .restricted:
            return ReadinessItem(
                title: "Speech access blocked",
                detail: "Grant Speech Recognition access in System Settings before using the Apple providers.",
                systemImage: "waveform.slash",
                tint: .orange
            )
        @unknown default:
            return ReadinessItem(
                title: "Speech access unknown",
                detail: "The app could not determine speech-recognition authorization state.",
                systemImage: "questionmark.circle",
                tint: .secondary
            )
        }
    }

    private var sessionDiagnosticsItems: [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        if let activeSession = appModel.activeSession {
            items.append(DiagnosticItem(label: "Session stage", value: sessionStageTitle(activeSession.stage)))
            items.append(DiagnosticItem(label: "Status", value: activeSession.statusMessage))
            items.append(DiagnosticItem(label: "Session folder", value: appModel.activeSessionDirectoryURL?.path ?? activeSession.sessionDirectoryName))

            if let provider = activeSession.lastTranscriptionProvider, !provider.isEmpty {
                items.append(DiagnosticItem(label: "Last transcription provider", value: provider))
            }

            if let mov = appModel.tempMOVURL {
                items.append(DiagnosticItem(label: "Raw capture", value: mov.path))
            }

            if let audioURL = appModel.audioURL {
                items.append(DiagnosticItem(label: "Session audio", value: audioURL.path))
            }

            if !appModel.transcriptState.isEmpty {
                items.append(DiagnosticItem(label: "Transcript", value: transcriptDiagnosticSummary))
            }

            if !appModel.meetingNotes.isEmpty {
                items.append(DiagnosticItem(label: "Meeting notes", value: "\(appModel.meetingNotes.count) characters saved"))
            }
        } else {
            items.append(DiagnosticItem(label: "Session", value: "No active session yet"))
        }

        return items
    }

    private var transcriptDiagnosticSummary: String {
        let speakerCount = appModel.transcriptState.orderedSpeakerLabels.count
        let segmentCount = appModel.transcriptState.segments.count
        if segmentCount > 0 {
            return "\(speakerCount) speaker\(speakerCount == 1 ? "" : "s"), \(segmentCount) segment\(segmentCount == 1 ? "" : "s")"
        }
        let lineCount = appModel.transcriptState.rawText.split(whereSeparator: \.isNewline).count
        return "\(lineCount) transcript line\(lineCount == 1 ? "" : "s")"
    }

    private var hasInvalidCustomInsightsPrompt: Bool {
        useCustomInsightsPrompt && customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isMeetingNotesActionDisabled: Bool {
        appModel.isGeneratingMeetingNotes ||
        !hasTranscriptDisplayText ||
        appModel.isTranscribing ||
        !isOpenAIKeyConfigured ||
        hasInvalidCustomInsightsPrompt
    }

    private var deleteSessionDialogBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { newValue in
                if !newValue {
                    sessionPendingDeletion = nil
                }
            }
        )
    }

    private var permissionAlertBinding: Binding<Bool> {
        Binding(
            get: { appModel.showPermissionAlert },
            set: { newValue in
                if !newValue {
                    appModel.clearPermissionAlert()
                }
            }
        )
    }

    private var splitWorkspace: some View {
        HSplitView {
            sessionSidebarPane
            mainWorkspacePane
        }
    }

    private var sessionSidebarPane: some View {
        SessionSidebarView(
            selectedSection: $selectedSection,
            sessionPendingDeletion: $sessionPendingDeletion,
            onToggleRecording: toggleRecordingFromSidebar,
            onImportAudio: {
                selectedSection = .capture
                showImportOptionsDialog = true
            },
            onClearWorkspace: {
                appModel.showNewSessionWorkspace()
                selectedSection = .capture
            }
        )
        .environmentObject(appModel)
        .padding(.trailing, 12)
        .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
    }

    private var mainWorkspacePane: some View {
        mainContent
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentWithChangeHandlers: some View {
        splitWorkspace
            .padding()
            .onChange(of: appModel.transcriptState.hasDisplayText) { oldValue, newValue in
                if !oldValue && newValue {
                    selectedSection = .transcript
                    transcriptViewID = UUID()
                }
            }
            .onChange(of: appModel.meetingNotes) { oldValue, newValue in
                if oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedSection = .insights
                }
            }
    }

    private var contentWithDialogs: some View {
        contentWithChangeHandlers
            .confirmationDialog(
            "Start a fresh recording?",
            isPresented: $showStartFreshRecordingPrompt,
            titleVisibility: .visible
        ) {
            Button("Save Audio…") { saveAudio() }
            Button("Save Transcript…") { showTranscriptFormatDialog = true }
                .disabled(appModel.transcriptState.isEmpty)
            Button("Start Fresh Recording", role: .destructive) {
                appModel.startRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing session remains on disk, but the main window will switch to a new recording session.")
        }
        .confirmationDialog(
            "Save Transcript As…",
            isPresented: $showTranscriptFormatDialog,
            titleVisibility: .visible
        ) {
            ForEach(TranscriptExportFormat.allCases) { format in
                Button(format.displayName) {
                    showTranscriptFormatDialog = false
                    saveTranscript(as: format)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Import Audio",
            isPresented: $showImportOptionsDialog,
            titleVisibility: .visible
        ) {
            Button("Choose File…") {
                showImportOptionsDialog = false
                importAudioFromFileSystem()
            }
            Button("Download from URL…") {
                showImportOptionsDialog = false
                importURLString = ""
                showURLImportSheet = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: deleteSessionDialogBinding,
            titleVisibility: .visible,
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete \(session.sourceDescription)", role: .destructive) {
                appModel.deleteSession(session.id)
                if appModel.activeSession == nil {
                    selectedSection = .capture
                }
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("This removes the session and its saved audio, transcript, and notes from disk.")
        }
        .alert(
            "Screen capture permission required",
            isPresented: permissionAlertBinding
        ) {
            Button("OK", role: .cancel) {
                appModel.clearPermissionAlert()
            }
        } message: {
            Text("Grant Screen Recording permission in System Settings > Privacy & Security > Screen Recording, then try again.")
        }
    }

    private var contentWithPreferences: some View {
        contentWithDialogs
            .onChange(of: provider) { _, newProvider in
                switch newProvider {
                case .openAI:
                    if hasPartialKnownSpeaker || knownSpeakerHintCount > 0 {
                        isKnownSpeakerHintsExpanded = true
                    }
                case .tscript:
                    if tScriptModelsResponse == nil && tScriptBaseURLConfigured {
                        refreshTScriptModels()
                    }
                case .appleOnDevice, .appleCloud:
                    break
                }
                do {
                    try AIConfigManager.shared.setDefaultProvider(newProvider.storageValue)
                } catch {
                    appModel.setStatusMessage("Failed to save default provider: \(error.localizedDescription)")
                }
            }
            .onChange(of: nameSuggestionProvider) { _, newProvider in
                do {
                    try AIConfigManager.shared.setNameSuggestionProvider(newProvider.rawValue)
                } catch {
                    appModel.setStatusMessage("Failed to save name suggestion provider: \(error.localizedDescription)")
                }
            }
            .onChange(of: openAIAPIKey) { _, newKey in
                do {
                    try AIConfigManager.shared.updateOpenAIKey(newKey.isEmpty ? nil : newKey)
                } catch {
                    appModel.setStatusMessage("Failed to save OpenAI key: \(error.localizedDescription)")
                }
            }
            .onChange(of: tScriptConfiguration) { oldValue, newValue in
                do {
                    try AIConfigManager.shared.updateTScriptConfiguration(newValue)
                } catch {
                    appModel.setStatusMessage("Failed to save TScript settings: \(error.localizedDescription)")
                }
                if oldValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != newValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) {
                    tScriptModelsResponse = nil
                    tScriptModelsError = nil
                }
            }
            .onChange(of: tScriptConfiguration.selectedModelID) { _, _ in
                guard let model = selectedTScriptModel else { return }
                normalizeTScriptDiarizationSelection(for: model)
                if !model.supportsTimestamps {
                    tScriptConfiguration.timestamps = false
                }
                if !model.supportsTranslation {
                    tScriptConfiguration.translate = false
                }
            }
            .onChange(of: useCustomInsightsPrompt) { _, newValue in
                if newValue && customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    customInsightsPrompt = selectedInsightsPreset.promptTemplate
                }
            }
            .onChange(of: selectedInsightsPreset) { _, newPreset in
                if !useCustomInsightsPrompt {
                    customInsightsPrompt = newPreset.promptTemplate
                }
            }
    }

    private var presentedContent: some View {
        contentWithPreferences
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsSheetView(
                    nameSuggestionProvider: $nameSuggestionProvider,
                    openAIAPIKey: $openAIAPIKey,
                    tScriptConfiguration: $tScriptConfiguration,
                    onClose: { showSettingsSheet = false }
                )
                .frame(minWidth: 520, minHeight: 340)
            }
            .sheet(isPresented: $showURLImportSheet) {
                URLImportSheet(
                    urlString: $importURLString,
                    isImporting: appModel.isImportingAudio,
                    onImport: { beginURLImport(from: $0) },
                    onDismiss: { showURLImportSheet = false }
                )
                .frame(minWidth: 380, minHeight: 220)
            }
#if os(macOS)
            .background(WindowConfigurator { window in
                configureInitialWindowSize(for: window)
            })
#endif
    }

    var body: some View {
        presentedContent
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerContent
            sectionNavigation
            currentSectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 4)
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TotalRec")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(headerSubtitle)
                        .font(.title3.weight(.semibold))
                    Text(appModel.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let elapsed = appModel.recordingElapsedText {
                    detailBadge(
                        elapsed,
                        systemImage: "record.circle.fill",
                        tint: .red
                    )
                }
            }

            providerStatusBadge

            if let recoveryNotice = appModel.recoveryNotice {
                statusBanner(
                    recoveryNotice,
                    systemImage: "arrow.triangle.2.circlepath.circle.fill",
                    tint: .orange,
                    dismissAction: {
                        appModel.dismissRecoveryNotice()
                    }
                )
            }

            if appModel.hasProtectedActivity {
                statusBanner(
                    "This session is protected while recording or processing is active. Session switching is locked until the current work is safe.",
                    systemImage: "lock.shield",
                    tint: .blue
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    private var headerSubtitle: String {
        if let activeSession = appModel.activeSession {
            return activeSession.sourceDescription
        }
        return "Ready for a new session"
    }

    private var providerStatusBadge: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                detailBadge(
                    provider.rawValue,
                    systemImage: providerSystemImage,
                    tint: workflowSectionTint(selectedSection)
                )

                if provider == .openAI {
                    detailBadge(
                        isOpenAIKeyConfigured ? "API key configured" : "API key missing",
                        systemImage: isOpenAIKeyConfigured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        tint: isOpenAIKeyConfigured ? .green : .orange
                    )
                } else if provider == .tscript {
                    detailBadge(
                        selectedTScriptModel?.displayName ?? "Model registry pending",
                        systemImage: selectedTScriptModel == nil ? "server.rack" : "square.stack.3d.up.fill",
                        tint: selectedTScriptModel == nil ? .secondary : .green
                    )
                }

                if let activeSession = appModel.activeSession {
                    detailBadge(
                        activeSession.sourceDescription,
                        systemImage: "square.stack.3d.up",
                        tint: .secondary
                    )
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                detailBadge(
                    provider.rawValue,
                    systemImage: providerSystemImage,
                    tint: workflowSectionTint(selectedSection)
                )

                HStack(spacing: 10) {
                    if provider == .openAI {
                        detailBadge(
                            isOpenAIKeyConfigured ? "API key configured" : "API key missing",
                            systemImage: isOpenAIKeyConfigured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                            tint: isOpenAIKeyConfigured ? .green : .orange
                        )
                    } else if provider == .tscript {
                        detailBadge(
                            selectedTScriptModel?.displayName ?? "Model registry pending",
                            systemImage: selectedTScriptModel == nil ? "server.rack" : "square.stack.3d.up.fill",
                            tint: selectedTScriptModel == nil ? .secondary : .green
                        )
                    }

                    if let activeSession = appModel.activeSession {
                        detailBadge(
                            activeSession.sourceDescription,
                            systemImage: "square.stack.3d.up",
                            tint: .secondary
                        )
                    }
                }
            }
        }
    }

    private var sectionNavigation: some View {
        ViewThatFits(in: .horizontal) {
            compactSectionNavigation(vertical: false)
            compactSectionNavigation(vertical: true)
        }
        .padding(4)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.gray.opacity(0.10), lineWidth: 1)
        )
    }

    private func compactSectionNavigation(vertical: Bool) -> some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            ForEach(WorkflowSection.allCases) { section in
                sectionNavigationButton(for: section)
            }
        }
    }

    private func sectionNavigationButton(for section: WorkflowSection) -> some View {
        let isSelected = selectedSection == section
        let tint = workflowSectionTint(section)
        let backgroundColor = isSelected ? tint.opacity(0.14) : Color.clear
        let borderColor = isSelected ? tint.opacity(0.35) : Color.gray.opacity(0.10)

        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: workflowSectionIcon(section))
                    .imageScale(.medium)
                Text(section.rawValue)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? tint : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var currentSectionContent: some View {
        switch selectedSection {
        case .capture:
            captureSection
        case .transcript:
            transcriptSection
        case .insights:
            insightsSection
        }
    }

    private func workflowSectionIcon(_ section: WorkflowSection) -> String {
        switch section {
        case .capture:
            return "waveform.circle.fill"
        case .transcript:
            return "text.quote"
        case .insights:
            return "list.bullet.rectangle.portrait"
        }
    }

    private func workflowSectionDescription(_ section: WorkflowSection) -> String {
        switch section {
        case .capture:
            return "Record system audio or import a file into a recoverable session."
        case .transcript:
            return "Run transcription, review diarization, and tune speaker names."
        case .insights:
            return "Generate notes and structured summaries from the session transcript."
        }
    }

    private func workflowSectionTint(_ section: WorkflowSection) -> Color {
        switch section {
        case .capture:
            return appModel.isRecording ? .red : .blue
        case .transcript:
            return .indigo
        case .insights:
            return .green
        }
    }

    private func sessionStageTitle(_ stage: SessionStage) -> String {
        switch stage {
        case .idle:
            return "Idle"
        case .preparingRecording:
            return "Preparing"
        case .recording:
            return "Recording"
        case .mixingDown:
            return "Mixing"
        case .importingAudio:
            return "Importing"
        case .readyToTranscribe:
            return "Ready"
        case .transcribing:
            return "Transcribing"
        case .generatingInsights:
            return "Notes"
        case .completed:
            return "Complete"
        case .failed:
            return "Attention"
        }
    }

    private func sessionStageIcon(_ stage: SessionStage) -> String {
        switch stage {
        case .idle:
            return "circle"
        case .preparingRecording:
            return "record.circle.dotted"
        case .recording:
            return "record.circle.fill"
        case .mixingDown:
            return "slider.horizontal.3"
        case .importingAudio:
            return "square.and.arrow.down"
        case .readyToTranscribe:
            return "waveform"
        case .transcribing:
            return "text.badge.clock"
        case .generatingInsights:
            return "sparkles.rectangle.stack"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private func sessionStageTint(_ stage: SessionStage) -> Color {
        switch stage {
        case .recording:
            return .red
        case .failed:
            return .orange
        case .preparingRecording, .mixingDown, .importingAudio, .transcribing, .generatingInsights:
            return .blue
        case .readyToTranscribe, .completed:
            return .green
        case .idle:
            return .secondary
        }
    }

    private func detailBadge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private func statusBanner(
        _ message: String,
        systemImage: String,
        tint: Color,
        dismissAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .padding(.top, 2)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            if let dismissAction {
                Button("Dismiss", action: dismissAction)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        )
    }

    private func pageCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    private func sectionScrollContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func readinessCard(
        title: String,
        subtitle: String,
        items: [ReadinessItem]
    ) -> some View {
        pageCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(items) { item in
                        readinessTile(item)
                    }
                }
            }
        }
    }

    private func readinessTile(_ item: ReadinessItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(item.tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(item.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(item.tint.opacity(0.16), lineWidth: 1)
        )
    }

    private var sessionDiagnosticsCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Details and Diagnostics")
                        .font(.headline)
                    Text("Inspect the current session state, artifacts, and the last surfaced error without leaving the workflow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = appModel.activeSession?.lastError, !error.isEmpty {
                    statusBanner(
                        error,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                DisclosureGroup(isExpanded: $isSessionDiagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sessionDiagnosticsItems) { item in
                            diagnosticRow(item)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text("Show paths and job details")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(sessionDiagnosticsItems.count) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func diagnosticRow(_ item: DiagnosticItem) -> some View {
        LabeledContent(item.label) {
            Text(item.value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func workspaceHero(
        title: String,
        description: String,
        systemImage: String,
        tint: Color,
        detail: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let detail {
                detailBadge(detail, systemImage: "sparkles", tint: tint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.12), tint.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }

    private var captureSection: some View {
        sectionScrollContainer {
            workspaceHero(
                title: appModel.isRecording ? "Recording in progress" : "Capture and prepare audio",
                description: "Record system audio or import an existing file. Every run is stored as a recoverable session before you move on to transcription.",
                systemImage: appModel.isRecording ? "record.circle.fill" : "waveform.circle.fill",
                tint: workflowSectionTint(.capture),
                detail: appModel.audioURL == nil ? nil : "Audio ready\(formattedDurationSuffix)"
            )

            readinessCard(
                title: "Capture readiness",
                subtitle: "Check recording permissions, session safety, and whether audio is ready before you start or stop a capture.",
                items: captureReadinessItems
            )

            pageCard {
                Text("Session Assets")
                    .font(.headline)

                Text("Start and stop capture from the Sessions sidebar. Use this area for exports and file inspection for the current session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                captureActionLayout

                Divider()

                if appModel.isRecording {
                    statusBanner(
                        "Recording continues even if you close the main window. Use the explicit stop action here or from the menu bar.",
                        systemImage: "shield.lefthalf.filled",
                        tint: .blue
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let mov = appModel.tempMOVURL {
                        LabeledContent("Raw capture") {
                            Text(mov.lastPathComponent)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let audioURL = appModel.audioURL {
                        LabeledContent("Session audio") {
                            Text(audioURL.lastPathComponent)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            sessionDiagnosticsCard

            if hasTranscriptDisplayText {
                pageCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest Transcript Preview")
                                .font(.headline)
                            Text("Jump back into transcript review without losing the current capture context.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Open Transcript Tools") {
                            selectedSection = .transcript
                        }
                        .buttonStyle(.bordered)
                    }

                    ScrollView {
                        Text(captureTranscriptPreviewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color.gray.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .frame(minHeight: 140, maxHeight: 240)
                }
            } else {
                pageCard {
                    Text("What Happens Next")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Capture or import audio into a dedicated session.", systemImage: "1.circle.fill")
                        Label("Run transcription when the audio is ready.", systemImage: "2.circle.fill")
                        Label("Review speakers, then generate notes and insights.", systemImage: "3.circle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var captureActionLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                captureButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                captureButtons
            }
        }
    }

    private var captureButtons: some View {
        Group {
            Button("Save Audio…", action: saveAudio)
                .disabled(appModel.audioURL == nil)

            Button("Save Transcript…") {
                showTranscriptFormatDialog = true
            }
            .disabled(appModel.transcriptState.isEmpty)

            Button("Go to Transcript") {
                selectedSection = .transcript
            }
            .disabled(appModel.audioURL == nil)
        }
    }

    private var transcriptSection: some View {
        sectionScrollContainer {
            transcriptSectionOverview

            if hasTranscriptDisplayText {
                pageCard {
                    TranscriptView(
                        transcript: transcriptBinding,
                        suggestionService: nameSuggestionService,
                        externalSuggestionTrigger: $nameSuggestionRequestSignal,
                        externalRequestInFlight: $isNameSuggestionRequestInFlight
                    )
                    .id(transcriptViewID)
                }
            } else {
                transcriptUnavailableCard
            }
        }
    }

    private var transcriptSectionOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            workspaceHero(
                title: hasTranscriptDisplayText ? "Transcript review and speaker tools" : "Transcript workspace",
                description: hasTranscriptDisplayText
                    ? "Review diarized text, request speaker suggestions, and export clean transcripts."
                    : "Run transcription when your session audio is ready, then refine names and speaker groupings.",
                systemImage: "text.quote",
                tint: workflowSectionTint(.transcript),
                detail: hasTranscriptDisplayText
                    ? "\(appModel.transcriptState.orderedSpeakerLabels.count) speakers"
                    : (appModel.audioURL == nil ? nil : "Audio ready\(formattedDurationSuffix)")
            )

            transcriptionSetupCard
            readinessCard(
                title: "Transcription readiness",
                subtitle: "Verify provider requirements, audio availability, and hint quality before you run or re-run transcription.",
                items: transcriptionReadinessItems
            )
            sessionDiagnosticsCard

            if hasTranscriptDisplayText {
                pageCard {
                    Text("Transcript Actions")
                        .font(.headline)
                    transcriptManagementToolbar
                }
            }
        }
    }

    private var transcriptUnavailableCard: some View {
        pageCard {
            Text("Transcript not available yet")
                .font(.headline)

            Text(appModel.audioURL == nil
                 ? "Record or import audio from the Capture page, then run transcription."
                 : "Your session audio is ready\(formattedDurationSuffix). Run transcription when you are ready.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Transcribe Audio") {
                    transcribe()
                }
                .disabled(isTranscriptionActionDisabled)
                .buttonStyle(.borderedProminent)

                Button("Go to Capture") {
                    selectedSection = .capture
                }
                .buttonStyle(.bordered)
            }

            if !appModel.processingPreviewText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live Preview")
                        .font(.headline)
                    Text(appModel.processingPreviewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.gray.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var transcriptionSetupCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcription Setup")
                            .font(.headline)
                        Text("Choose how this session should be transcribed before you run or re-run the job.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if provider == .openAI || provider == .tscript {
                        Button(provider == .openAI ? "Manage API Key" : "Manage Server") {
                            showSettingsSheet = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Picker("Transcription Provider", selection: $provider) {
                    ForEach(TranscriptionProvider.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if provider == .openAI {
                    openAITranscriptionSettings
                } else if provider == .tscript {
                    tScriptTranscriptionSettings
                } else {
                    Text(provider == .appleOnDevice
                         ? "On-device transcription keeps the run local when the platform can handle it."
                         : "Apple Cloud transcription uses Apple's cloud speech service when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var openAITranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    detailBadge(
                        isOpenAIKeyConfigured ? "API key ready" : "API key required",
                        systemImage: isOpenAIKeyConfigured ? "key.fill" : "exclamationmark.triangle.fill",
                        tint: isOpenAIKeyConfigured ? .green : .orange
                    )

                    detailBadge(
                        openAIChunkingDisplayName,
                        systemImage: openAIChunkingStrategy == "none" ? "arrow.up.doc" : "square.split.2x2",
                        tint: .blue
                    )

                    detailBadge(
                        knownSpeakerHintCount == 0 ? "No speaker hints" : "\(knownSpeakerHintCount) speaker hints",
                        systemImage: "person.2.fill",
                        tint: knownSpeakerHintCount == 0 ? .secondary : .indigo
                    )

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    detailBadge(
                        isOpenAIKeyConfigured ? "API key ready" : "API key required",
                        systemImage: isOpenAIKeyConfigured ? "key.fill" : "exclamationmark.triangle.fill",
                        tint: isOpenAIKeyConfigured ? .green : .orange
                    )

                    HStack(spacing: 8) {
                        detailBadge(
                            openAIChunkingDisplayName,
                            systemImage: openAIChunkingStrategy == "none" ? "arrow.up.doc" : "square.split.2x2",
                            tint: .blue
                        )

                        detailBadge(
                            knownSpeakerHintCount == 0 ? "No speaker hints" : "\(knownSpeakerHintCount) speaker hints",
                            systemImage: "person.2.fill",
                            tint: knownSpeakerHintCount == 0 ? .secondary : .indigo
                        )
                    }
                }
            }

            if !isOpenAIKeyConfigured {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)

                    Text("OpenAI transcription requires an API key stored in Keychain. Use Settings to add or replace it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings") {
                        showSettingsSheet = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                )
            } else {
                Text("OpenAI key is configured and available for diarized transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Upload Strategy")
                    .font(.subheadline.weight(.semibold))
                Picker("Upload Chunking", selection: $openAIChunkingStrategy) {
                    Text("Auto").tag("auto")
                    Text("Single Upload").tag("none")
                }
                .pickerStyle(.segmented)

                Text("Auto splits longer files before upload. Single Upload keeps the run as one file when it fits the provider limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isKnownSpeakerHintsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                TextField("Name #\(index + 1)", text: $knownSpeakerNamesInputs[index])
                                    .textFieldStyle(.roundedBorder)

                                TextField("Reference URL, data URI, or local file path", text: $knownSpeakerRefsInputs[index])
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Name #\(index + 1)", text: $knownSpeakerNamesInputs[index])
                                    .textFieldStyle(.roundedBorder)

                                TextField("Reference URL, data URI, or local file path", text: $knownSpeakerRefsInputs[index])
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    HStack {
                        Text("Optional hints help OpenAI anchor diarization to voices you already know.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Clear Hints") {
                            knownSpeakerNamesInputs = Array(repeating: "", count: 4)
                            knownSpeakerRefsInputs = Array(repeating: "", count: 4)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Known Speaker Hints")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(knownSpeakerHintCount)/4 ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasPartialKnownSpeaker {
                statusBanner(
                    "Each speaker hint row needs both a name and a reference. Incomplete rows are ignored until you finish or clear them.",
                    systemImage: "person.crop.rectangle.stack.fill",
                    tint: .orange
                )
            }
        }
    }

    private var tScriptTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            let transportItem = tScriptTransportReadinessItem
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    detailBadge(
                        transportItem.title,
                        systemImage: transportItem.systemImage,
                        tint: transportItem.tint
                    )

                    if let model = selectedTScriptModel {
                        detailBadge(
                            model.displayName,
                            systemImage: "square.stack.3d.up.fill",
                            tint: model.runtimeAvailable ? .green : .orange
                        )
                    }

                    if isTScriptModelsLoading {
                        detailBadge(
                            "Refreshing models",
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: .blue
                        )
                    }

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    detailBadge(
                        transportItem.title,
                        systemImage: transportItem.systemImage,
                        tint: transportItem.tint
                    )

                    HStack(spacing: 8) {
                        if let model = selectedTScriptModel {
                            detailBadge(
                                model.displayName,
                                systemImage: "square.stack.3d.up.fill",
                                tint: model.runtimeAvailable ? .green : .orange
                            )
                        }

                        if isTScriptModelsLoading {
                            detailBadge(
                                "Refreshing models",
                                systemImage: "arrow.triangle.2.circlepath",
                                tint: .blue
                            )
                        }
                    }
                }
            }

            if !tScriptBaseURLConfigured {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.orange)

                    Text("TScript transcription requires a server base URL in Settings before the app can discover models.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings") {
                        showSettingsSheet = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                )
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server")
                            .font(.subheadline.weight(.semibold))
                        Text(normalizedTScriptBaseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(isTScriptModelsLoading ? "Refreshing…" : "Refresh Models") {
                        refreshTScriptModels()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTScriptModelsLoading)
                }
            }

            if let warning = tScriptTransportWarningText {
                statusBanner(
                    warning,
                    systemImage: "exclamationmark.shield.fill",
                    tint: .orange
                )
            }

            if let error = tScriptModelsError, !error.isEmpty {
                statusBanner(
                    error,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.subheadline.weight(.semibold))
                Picker("TScript Model", selection: $tScriptConfiguration.selectedModelID) {
                    if let defaultID = tScriptModelsResponse?.defaultModelID,
                       let defaultModel = tScriptModelsResponse?.models[defaultID] {
                        Text("Server Default (\(defaultModel.displayName))").tag("")
                    } else {
                        Text("Server Default").tag("")
                    }
                    ForEach(tScriptModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(tScriptModels.isEmpty)

                if let model = selectedTScriptModel {
                    Text(model.notes ?? "\(model.engine) (\(model.status ?? "unknown"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if tScriptModels.isEmpty {
                    Text("Refresh models to populate the picker from the TScript server registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The server default model will be used if you leave the selection empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let model = selectedTScriptModel {
                tScriptCapabilityEditor(for: model)
            }
        }
    }

    @ViewBuilder
    private func tScriptCapabilityEditor(for model: TScriptModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.acceptsLanguageSelection {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Language")
                        .font(.subheadline.weight(.semibold))
                    DeferredCommitTextField("en", text: $tScriptConfiguration.language)
                        .textFieldStyle(.roundedBorder)
                    Text("Language is sent only when the selected model supports explicit language selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.supportsTranslation || model.supportsTimestamps {
                HStack(spacing: 16) {
                    if model.supportsTranslation {
                        Toggle("Translate", isOn: $tScriptConfiguration.translate)
                    }
                    if model.supportsTimestamps {
                        Toggle("Timestamps", isOn: $tScriptConfiguration.timestamps)
                    }
                }
            }

            if model.availableDiarizationModes.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diarization")
                        .font(.subheadline.weight(.semibold))
                    Picker("Diarization", selection: $tScriptConfiguration.diarizationMode) {
                        ForEach(model.availableDiarizationModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("The UI only exposes diarization modes the current model advertises through `/models`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if effectiveTScriptDiarizationMode != .off && model.supportsStandardDiarization {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker Hints")
                        .font(.subheadline.weight(.semibold))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            DeferredCommitTextField("Exact speaker count", text: $tScriptConfiguration.numSpeakers)
                                .textFieldStyle(.roundedBorder)
                            DeferredCommitTextField("Min speakers", text: $tScriptConfiguration.minSpeakers)
                                .textFieldStyle(.roundedBorder)
                            DeferredCommitTextField("Max speakers", text: $tScriptConfiguration.maxSpeakers)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            DeferredCommitTextField("Exact speaker count", text: $tScriptConfiguration.numSpeakers)
                                .textFieldStyle(.roundedBorder)
                            DeferredCommitTextField("Min speakers", text: $tScriptConfiguration.minSpeakers)
                                .textFieldStyle(.roundedBorder)
                            DeferredCommitTextField("Max speakers", text: $tScriptConfiguration.maxSpeakers)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("Optional pyannote hints. Leave these blank unless you want to constrain diarization to a known speaker count or range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isWhisperEngine {
                DisclosureGroup(isExpanded: $isTScriptAdvancedOptionsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Flash Attention", isOn: $tScriptConfiguration.advanced.flashAttention)
                        Toggle("Split On Word", isOn: $tScriptConfiguration.advanced.splitOnWord)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                DeferredCommitTextField("Threads", text: $tScriptConfiguration.advanced.threads)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Processors", text: $tScriptConfiguration.advanced.processors)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Beam Size", text: $tScriptConfiguration.advanced.beamSize)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Best Of", text: $tScriptConfiguration.advanced.bestOf)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                DeferredCommitTextField("Threads", text: $tScriptConfiguration.advanced.threads)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Processors", text: $tScriptConfiguration.advanced.processors)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Beam Size", text: $tScriptConfiguration.advanced.beamSize)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Best Of", text: $tScriptConfiguration.advanced.bestOf)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                DeferredCommitTextField("Max Context", text: $tScriptConfiguration.advanced.maxContext)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Max Len", text: $tScriptConfiguration.advanced.maxLen)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Word Threshold", text: $tScriptConfiguration.advanced.wordThreshold)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                DeferredCommitTextField("Max Context", text: $tScriptConfiguration.advanced.maxContext)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Max Len", text: $tScriptConfiguration.advanced.maxLen)
                                    .textFieldStyle(.roundedBorder)
                                DeferredCommitTextField("Word Threshold", text: $tScriptConfiguration.advanced.wordThreshold)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Text("These advanced options map directly to the documented whisper.cpp passthrough fields. Leave them blank to use server defaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced Whisper Options")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var transcriptManagementToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    transcriptPrimaryActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    transcriptPrimaryActions
                }
            }

            HStack(spacing: 8) {
                Button("Save Transcript (Text)") {
                    saveTranscript(as: .plainText)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.transcriptState.isEmpty)

                Button("Save Transcript (JSON)") {
                    saveTranscript(as: .json)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.transcriptState.isEmpty)
            }

            if isNameSuggestionRequestInFlight {
                Text("Contacting \(nameSuggestionProvider.displayName) for name ideas…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptPrimaryActions: some View {
        Group {
            Button(appModel.isTranscribing ? "Transcribing..." : "Re-run Transcription") {
                transcribe()
            }
            .disabled(isTranscriptionActionDisabled)
            .buttonStyle(.bordered)

            Button(isNameSuggestionRequestInFlight ? "Requesting…" : "Request Suggestions") {
                appModel.setStatusMessage("Requesting speaker name suggestions...")
                nameSuggestionRequestSignal &+= 1
            }
            .disabled(isNameSuggestionRequestInFlight || !hasTranscriptDisplayText || nameSuggestionProvider == .disabled)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("requestSuggestionsToolbarButton")

            Button("Consolidate Consecutive Speakers") {
                if appModel.consolidateConsecutiveSpeakers() {
                    transcriptViewID = UUID()
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("consolidateSpeakersButton")

            Button("Reset Speaker Names") {
                if appModel.resetSpeakerAliases() {
                    transcriptViewID = UUID()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!hasCustomSpeakerAliases)
            .accessibilityIdentifier("resetAliasesButtonToolbar")
        }
    }

    private var insightsSection: some View {
        sectionScrollContainer {
            workspaceHero(
                title: appModel.meetingNotes.isEmpty ? "Generate structured notes" : "Insights and meeting notes",
                description: "Turn the transcript into reusable notes, action items, and shareable summaries.",
                systemImage: "list.bullet.rectangle.portrait",
                tint: workflowSectionTint(.insights),
                detail: hasTranscriptDisplayText ? "Transcript ready" : nil
            )

            readinessCard(
                title: "Insights readiness",
                subtitle: "Check transcript access, OpenAI availability, and prompt state before generating notes.",
                items: insightsReadinessItems
            )

            pageCard {
                meetingNotesPanel

                HStack(spacing: 8) {
                    Button("Save Notes (Text)") {
                        saveMeetingNotes(as: .plainText)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.meetingNotes.isEmpty)

                    Button("Save Notes (JSON)") {
                        saveMeetingNotes(as: .json)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.meetingNotes.isEmpty)
                }
            }
        }
    }

    private var meetingNotesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting Notes")
                        .font(.headline)
                    Text("Generate a structured readout from the current session transcript.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appModel.isGeneratingMeetingNotes {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button("Generate Meeting Notes") {
                    Task {
                        let trimmedPrompt = customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        let promptOverride = useCustomInsightsPrompt
                            ? trimmedPrompt
                            : selectedInsightsPreset.promptTemplate
                        if useCustomInsightsPrompt && trimmedPrompt.isEmpty {
                            appModel.meetingNotesError = "Enter a custom prompt or disable the option."
                            appModel.setStatusMessage("Meeting notes failed: Custom prompt required.")
                            return
                        }
                        do {
                            try await appModel.generateMeetingNotes(promptOverride: promptOverride)
                        } catch {
                            // AppModel already surfaced the failure state.
                        }
                    }
                }
                .disabled(isMeetingNotesActionDisabled)
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes Preset")
                        .font(.subheadline.weight(.semibold))
                    Picker("Notes Preset", selection: $selectedInsightsPreset) {
                        ForEach(MeetingNotesService.Preset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(selectedInsightsPreset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $useCustomInsightsPrompt.animation()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Customize Prompt")
                            .font(.subheadline)
                        Text("Use a preset as the default, or switch this on to fully control the GPT-5 instructions. Keep the {{TRANSCRIPT}} token where the diarized text should be inserted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if useCustomInsightsPrompt {
                    TextEditor(text: $customInsightsPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .padding(10)
                        .background(Color.gray.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
                        )
                    HStack {
                        Text("Need ideas? Start from the default template and tailor it to your workflow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to template") {
                            customInsightsPrompt = selectedInsightsPreset.promptTemplate
                        }
                        .font(.caption)
                    }
                } else {
                    Text("Using the \(selectedInsightsPreset.rawValue.lowercased()) preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = appModel.meetingNotesError, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            if appModel.meetingNotes.isEmpty {
                Text("No meeting notes yet. Generate notes to see a structured summary of this meeting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(appModel.meetingNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color.gray.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(minHeight: 180)
            }
        }
    }

    private func transcribe() {
        guard appModel.audioURL != nil else { return }

        if provider == .openAI && !isOpenAIKeyConfigured {
            appModel.setStatusMessage("OpenAI API key missing. Open Settings to configure it.")
            showSettingsSheet = true
            return
        }

        if provider == .openAI && hasPartialKnownSpeaker {
            appModel.setStatusMessage("Please provide both a Name and a Sample for each known speaker, or clear the incomplete rows.")
            return
        }

        if provider == .tscript && !tScriptBaseURLConfigured {
            appModel.setStatusMessage("TScript base URL missing. Open Settings to configure it.")
            showSettingsSheet = true
            return
        }

        if provider == .tscript && tScriptRequiresHTTPOverride {
            appModel.setStatusMessage(tScriptTransportReadinessItem.detail)
            showSettingsSheet = true
            return
        }

        if provider == .tscript, let model = selectedTScriptModel, !model.runtimeAvailable {
            appModel.setStatusMessage("Selected TScript model is unavailable. Refresh models or choose another model.")
            return
        }

        Task {
            await appModel.transcribe(
                TranscriptionRunConfiguration(
                    provider: provider,
                    openAIAPIKey: openAIAPIKey,
                    openAIChunkingStrategy: openAIChunkingStrategy,
                    knownSpeakers: preparedKnownSpeakers,
                    tscript: provider == .tscript
                        ? TScriptTranscriptionRunConfiguration(
                            baseURL: tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            configuration: tScriptConfiguration
                        )
                        : nil
                )
            )
        }
    }

    private func refreshTScriptModels() {
        let baseURL = tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            tScriptModelsError = "Enter a TScript base URL in Settings before loading models."
            return
        }
        guard !isTScriptModelsLoading else { return }

        isTScriptModelsLoading = true
        tScriptModelsError = nil

        Task {
            do {
                let response = try await TScriptTranscriber().fetchModelRegistry(configuration: tScriptConfiguration)
                await MainActor.run {
                    isTScriptModelsLoading = false
                    tScriptModelsResponse = response
                    tScriptModelsError = nil
                    normalizeTScriptSelection(using: response)
                }
            } catch {
                await MainActor.run {
                    isTScriptModelsLoading = false
                    tScriptModelsResponse = nil
                    tScriptModelsError = error.localizedDescription
                }
            }
        }
    }

    private func normalizeTScriptSelection(using response: TScriptModelsResponse) {
        let configuredID = tScriptConfiguration.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableModelIDs = response.allModels.filter(\.runtimeAvailable).map(\.id)
        let fallbackID = response.defaultModelID.flatMap { response.models[$0]?.runtimeAvailable == true ? $0 : nil }
            ?? availableModelIDs.first
            ?? response.allModels.first?.id

        if !configuredID.isEmpty, response.models[configuredID] == nil {
            tScriptConfiguration.selectedModelID = fallbackID ?? ""
        }

        guard let model = selectedTScriptModel else { return }
        normalizeTScriptDiarizationSelection(for: model)
        if !model.supportsTimestamps {
            tScriptConfiguration.timestamps = false
        }
        if !model.supportsTranslation {
            tScriptConfiguration.translate = false
        }
    }

    private func normalizeTScriptDiarizationSelection(for model: TScriptModel) {
        let normalized = model.normalizedDiarizationMode(tScriptConfiguration.diarizationMode)
        if tScriptConfiguration.diarizationMode != normalized {
            tScriptConfiguration.diarizationMode = normalized
        }
    }

    private func saveAudio() {
        guard let url = appModel.audioURL else { return }
#if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.audio]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let destination = panel.url {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    appModel.setStatusMessage("Save failed: \(error.localizedDescription)")
                }
            }
        }
#endif
    }

    private func saveTranscript(as format: TranscriptExportFormat) {
        guard !appModel.transcriptState.isEmpty else { return }
#if os(macOS)
        let stateToSave = appModel.transcriptState
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format.suggestedFilename(hasSpeakerLabels: stateToSave.hasSpeakerLabels)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let destination = panel.url {
                do {
                    switch format {
                    case .json:
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(stateToSave)
                        try data.write(to: destination)
                    case .plainText:
                        let data = stateToSave.plainTextExport.data(using: .utf8) ?? Data()
                        try data.write(to: destination)
                    case .webVTT:
                        let renderer = TranscriptRenderer(transcript: stateToSave)
                        try renderer.captions(format: .webVTT).write(to: destination, atomically: true, encoding: .utf8)
                    case .srt:
                        let renderer = TranscriptRenderer(transcript: stateToSave)
                        try renderer.captions(format: .srt).write(to: destination, atomically: true, encoding: .utf8)
                    }
                } catch {
                    appModel.setStatusMessage("Save failed: \(error.localizedDescription)")
                }
            }
        }
#endif
    }

    private enum MeetingNotesExportFormat {
        case plainText
        case json

        var contentType: UTType {
            switch self {
            case .plainText:
                return .plainText
            case .json:
                return .json
            }
        }

        var fileName: String {
            switch self {
            case .plainText:
                return "notes.txt"
            case .json:
                return "notes.json"
            }
        }
    }

    private func saveMeetingNotes(as format: MeetingNotesExportFormat) {
        guard !appModel.meetingNotes.isEmpty else { return }
#if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let destination = panel.url {
                do {
                    switch format {
                    case .plainText:
                        try appModel.meetingNotes.write(to: destination, atomically: true, encoding: .utf8)
                    case .json:
                        let payload = ["notes": appModel.meetingNotes]
                        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
                        try data.write(to: destination)
                    }
                } catch {
                    appModel.setStatusMessage("Save failed: \(error.localizedDescription)")
                }
            }
        }
#endif
    }

    private func importAudioFromFileSystem() {
        guard !appModel.isImportingAudio else { return }
        guard !appModel.isRecording else {
            appModel.setStatusMessage("Stop recording before importing audio.")
            return
        }
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { await appModel.importAudioFromFileSystem(url) }
            }
        }
#else
        appModel.setStatusMessage("File import is only supported on macOS.")
#endif
    }

    private func beginURLImport(from rawString: String) {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appModel.setStatusMessage("Enter a valid audio URL.")
            return
        }
        guard let remoteURL = URL(string: trimmed),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            appModel.setStatusMessage("Unsupported audio URL. Use http or https.")
            return
        }

        showURLImportSheet = false
        importURLString = ""
        Task { await appModel.importAudioFromRemoteURL(remoteURL) }
    }

    private func toggleRecordingFromSidebar() {
        selectedSection = .capture
        if appModel.isRecording {
            Task { await appModel.stopRecording() }
        } else if appModel.hasSessionContent {
            showStartFreshRecordingPrompt = true
        } else {
            appModel.startRecording()
        }
    }
}

private struct ReadinessItem: Identifiable {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var id: String { "\(title)-\(detail)-\(systemImage)" }
}

private struct DiagnosticItem: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private struct SessionSidebarView: View {
    @EnvironmentObject private var appModel: AppModel

    @Binding var selectedSection: ContentView.WorkflowSection
    @Binding var sessionPendingDeletion: RecordingSession?

    let onToggleRecording: () -> Void
    let onImportAudio: () -> Void
    let onClearWorkspace: () -> Void

    private var captureTint: Color {
        appModel.isRecording ? .red : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions")
                    .font(.title3.bold())
                Spacer()

                Button {
                    sessionPendingDeletion = appModel.activeSession
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(appModel.activeSession == nil || appModel.hasProtectedActivity)

                Text("\(appModel.recentSessionSummaries.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.gray.opacity(0.10), in: Capsule())
            }

            Text("Each recording or import becomes its own session. Protected work keeps the current session in place until it is safe to switch.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            sessionCaptureControlPanel

            if appModel.recentSessionSummaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)

                    Text("No Sessions Yet")
                        .font(.title2.weight(.bold))

                    Text("Start a recording or import audio to create your first recoverable session.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(18)
                .background(captureTint.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                        .foregroundStyle(Color.gray.opacity(0.25))
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(appModel.recentSessionSummaries) { session in
                            Button {
                                appModel.selectSession(session.id)
                            } label: {
                                sessionCard(session)
                            }
                            .buttonStyle(.plain)
                            .disabled(!appModel.canSwitchSessions && appModel.activeSession?.id != session.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    private var sessionCaptureControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sessionCaptureButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    sessionCaptureButtons
                }
            }

            Text(selectedSection == .capture
                 ? "Start or stop capture here. Importing audio also creates a recoverable session."
                 : "Capture controls stay available here while Transcript or Insights is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(captureTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(captureTint.opacity(0.16), lineWidth: 1)
        )
        .opacity(selectedSection == .capture ? 1.0 : 0.68)
    }

    private var sessionCaptureButtons: some View {
        Group {
            Button(appModel.isRecording ? "Stop Recording" : "Start Recording", action: onToggleRecording)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

            Button("Import Audio…", action: onImportAudio)
                .disabled(appModel.isBusy)

            if appModel.activeSession != nil {
                Button("Clear Workspace", action: onClearWorkspace)
                    .buttonStyle(.bordered)
                    .disabled(appModel.hasProtectedActivity)
            }
        }
    }

    private func sessionCard(_ session: RecordingSessionSummary) -> some View {
        let isActive = session.id == appModel.activeSession?.id
        let isLocked = !appModel.canSwitchSessions && !isActive

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(stageTitle(session.stage), systemImage: stageIcon(session.stage))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stageTint(session.stage))

                Spacer()

                if isActive {
                    Text("Open")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                } else if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(session.sourceDescription)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(session.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                if session.hasAudio {
                    sessionMetaPill("Audio", systemImage: "waveform")
                }
                if session.hasTranscript {
                    sessionMetaPill("Transcript", systemImage: "text.quote")
                }
                if session.hasMeetingNotes {
                    sessionMetaPill("Notes", systemImage: "list.bullet.rectangle")
                }
                if session.lastError?.isEmpty == false {
                    sessionMetaPill("Issue", systemImage: "exclamationmark.triangle")
                }
            }

            Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.45) : Color.gray.opacity(0.18),
                    lineWidth: 1
                )
        )
        .opacity(isLocked ? 0.6 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sessionMetaPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.12), in: Capsule())
    }

    private func stageTitle(_ stage: SessionStage) -> String {
        switch stage {
        case .idle:
            return "Idle"
        case .preparingRecording:
            return "Preparing"
        case .recording:
            return "Recording"
        case .mixingDown:
            return "Mixing"
        case .importingAudio:
            return "Importing"
        case .readyToTranscribe:
            return "Ready"
        case .transcribing:
            return "Transcribing"
        case .generatingInsights:
            return "Notes"
        case .completed:
            return "Complete"
        case .failed:
            return "Attention"
        }
    }

    private func stageIcon(_ stage: SessionStage) -> String {
        switch stage {
        case .idle:
            return "circle"
        case .preparingRecording:
            return "record.circle.dotted"
        case .recording:
            return "record.circle.fill"
        case .mixingDown:
            return "slider.horizontal.3"
        case .importingAudio:
            return "square.and.arrow.down"
        case .readyToTranscribe:
            return "waveform"
        case .transcribing:
            return "text.badge.clock"
        case .generatingInsights:
            return "sparkles.rectangle.stack"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private func stageTint(_ stage: SessionStage) -> Color {
        switch stage {
        case .recording:
            return .red
        case .failed:
            return .orange
        case .preparingRecording, .mixingDown, .importingAudio, .transcribing, .generatingInsights:
            return .blue
        case .readyToTranscribe, .completed:
            return .green
        case .idle:
            return .secondary
        }
    }
}

private struct SettingsSheetView: View {
    private static let contentColumnWidth: CGFloat = 700
    private static let apiKeyFieldWidth: CGFloat = 420

    @Binding var nameSuggestionProvider: NameSuggestionProvider
    @Binding var openAIAPIKey: String
    @Binding var tScriptConfiguration: TScriptConfiguration
    var onClose: () -> Void

    private var hasOpenAIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTScriptBaseURL: Bool {
        !tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedTScriptBaseURL: String {
        let trimmed = tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private var tScriptBaseURLScheme: String? {
        guard !normalizedTScriptBaseURL.isEmpty else { return nil }
        return URL(string: normalizedTScriptBaseURL)?.scheme?.lowercased()
    }

    private var tScriptTransportWarningText: String? {
        if tScriptBaseURLScheme == "http" && !tScriptConfiguration.allowInsecureHTTP {
            return "This endpoint uses HTTP. Enable the insecure HTTP override only if you trust the server and network."
        }
        if tScriptBaseURLScheme == "http" && tScriptConfiguration.allowInsecureHTTP {
            return "Insecure HTTP override is enabled. Traffic to this TScript server is not protected by TLS."
        }
        if tScriptBaseURLScheme == "https" && tScriptConfiguration.allowInvalidTLSCertificates {
            return "Invalid TLS certificate override is enabled. The app will accept a certificate it cannot verify for this host."
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader
                apiKeySection
                tScriptServerSection
                nameSuggestionsSection
                workflowSection
            }
            .frame(maxWidth: Self.contentColumnWidth, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
    }

    private var settingsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Settings")
                .font(.title2.bold())
            Spacer()
            Button("Done") { onClose() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var apiKeySection: some View {
        settingsSectionCard(
            title: "OpenAI API Key",
            subtitle: hasOpenAIKey
                ? "Stored in Keychain and used for OpenAI transcription and notes."
                : "OpenAI features stay unavailable until you add a key."
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    apiKeyField
                        .frame(maxWidth: Self.apiKeyFieldWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    apiKeyStatusBlock
                }

                VStack(alignment: .leading, spacing: 12) {
                    apiKeyField
                    apiKeyStatusBlock
                }
            }
        }
    }

    private var apiKeyField: some View {
        HStack(spacing: 10) {
            Image(systemName: hasOpenAIKey ? "key.fill" : "key")
                .foregroundStyle(hasOpenAIKey ? .green : .secondary)

            DeferredCommitSecureField("sk-...", text: $openAIAPIKey)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hasOpenAIKey ? Color.green.opacity(0.22) : Color.gray.opacity(0.18), lineWidth: 1)
        )
    }

    private var apiKeyStatusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                hasOpenAIKey ? "Key saved" : "No key saved",
                systemImage: hasOpenAIKey ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(hasOpenAIKey ? .green : .secondary)

            if hasOpenAIKey {
                Button("Clear Key") {
                    openAIAPIKey = ""
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(minWidth: 110, alignment: .leading)
    }

    private var nameSuggestionsSection: some View {
        settingsSectionCard(
            title: "Name Suggestions",
            subtitle: "Choose how speaker names are suggested for diarized transcripts."
        ) {
            Picker("Name Suggestions Provider", selection: $nameSuggestionProvider) {
                ForEach(NameSuggestionProvider.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private var tScriptServerSection: some View {
        settingsSectionCard(
            title: "TScript Server",
            subtitle: hasTScriptBaseURL
                ? "The app will load `/models` from this server when the TScript provider is active."
                : "Add the base URL for your private TScript server to enable model discovery."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: hasTScriptBaseURL ? "server.rack" : "network.slash")
                        .foregroundStyle(hasTScriptBaseURL ? .green : .secondary)

                    DeferredCommitTextField("https://transcribe-api.localhost:1355", text: $tScriptConfiguration.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                if hasTScriptBaseURL {
                    LabeledContent("Resolved Endpoint") {
                        Text(normalizedTScriptBaseURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Allow insecure HTTP for this server", isOn: $tScriptConfiguration.allowInsecureHTTP)
                Toggle("Allow invalid TLS certificates for this server", isOn: $tScriptConfiguration.allowInvalidTLSCertificates)

                Text("HTTPS stays the default. These overrides are intended only for a private server you control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = tScriptTransportWarningText {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                    )
                }
            }
        }
    }

    private var workflowSection: some View {
        settingsSectionCard(
            title: "Workflow",
            subtitle: "Transcription provider, model selection, upload chunking, and per-run options now live in the Transcript workspace so each run can be configured in context."
        ) {
            EmptyView()
        }
    }

    private func settingsSectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct DeferredCommitTextField: View {
    let title: String
    @Binding var text: String

    @State private var draftText: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
        self._draftText = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextField(title, text: $draftText)
            .focused($isFocused)
            .onAppear {
                draftText = text
            }
            .onSubmit {
                commit()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: text) { _, newValue in
                if !isFocused && draftText != newValue {
                    draftText = newValue
                }
            }
            .onDisappear {
                commit()
            }
    }

    private func commit() {
        if text != draftText {
            text = draftText
        }
    }
}

private struct DeferredCommitSecureField: View {
    let title: String
    @Binding var text: String

    @State private var draftText: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
        self._draftText = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        SecureField(title, text: $draftText)
            .focused($isFocused)
            .onAppear {
                draftText = text
            }
            .onSubmit {
                commit()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: text) { _, newValue in
                if !isFocused && draftText != newValue {
                    draftText = newValue
                }
            }
            .onDisappear {
                commit()
            }
    }

    private func commit() {
        if text != draftText {
            text = draftText
        }
    }
}

private struct URLImportSheet: View {
    @Binding var urlString: String
    let isImporting: Bool
    let onImport: (String) -> Void
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Audio URL")) {
                    TextField("https://example.com/audio.m4a", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .focused($isFieldFocused)
                }

                if isImporting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Downloading…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import from URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport(urlString) }
                        .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }
            }
        }
        .onAppear {
            isFieldFocused = true
        }
    }
}

#if os(macOS)
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
            }
        }
    }
}
#endif
