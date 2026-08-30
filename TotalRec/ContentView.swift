import SwiftUI
import AVFoundation
import Speech
import Combine
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

    enum TranscriptWorkspaceStep: String, CaseIterable, Identifiable {
        case run = "Run"
        case transcript = "Transcript"
        case speakers = "Speakers"
        case document = "Document"

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

        var preferredPathExtension: String {
            switch self {
            case .plainText:
                return "txt"
            case .json:
                return "json"
            case .webVTT:
                return "vtt"
            case .srt:
                return "srt"
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

    enum InsightArtifactExportFormat: String, CaseIterable, Identifiable {
        case plainText
        case json

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plainText:
                return "Plain Text (.txt)"
            case .json:
                return "JSON (.json)"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText:
                return .plainText
            case .json:
                return .json
            }
        }

        var preferredPathExtension: String {
            switch self {
            case .plainText:
                return "txt"
            case .json:
                return "json"
            }
        }

        func suggestedFilename(for artifact: InsightArtifact) -> String {
            switch self {
            case .plainText:
                return "\(artifact.workflow.fileSlug).txt"
            case .json:
                return "\(artifact.workflow.fileSlug).json"
            }
        }
    }

    @EnvironmentObject private var appModel: AppModel
#if os(macOS)
    @Environment(\.openSettings) private var openSettings
#endif

    @State private var showStartFreshRecordingPrompt = false
    @State private var showImportOptionsDialog = false
    @State private var showURLImportSheet = false
    @State private var importURLString = ""
    @State private var knownSpeakerNamesInputs = Array(repeating: "", count: 4)
    @State private var knownSpeakerRefsInputs = Array(repeating: "", count: 4)
    @State private var openAIAPIKey: String = ""
    @State private var sambaNovaAPIKey: String = ""
    @State private var sambaNovaBaseURL: String = LLMProvider.sambaNova.defaultBaseURL
    @State private var tScriptConfiguration = TScriptConfiguration()
    @State private var tScriptModelsResponse: TScriptModelsResponse?
    @State private var isTScriptModelsLoading = false
    @State private var tScriptModelsError: String?
    @State private var defaultInsightProvider: LLMProvider = .openAI
    @State private var defaultInsightModelID: String = LLMProvider.openAI.defaultModelID(for: .insights)
    @State private var nameSuggestionModelID: String = LLMProvider.openAI.defaultModelID(for: .nameSuggestions)
    @State private var openAIModels: [ProviderModelDescriptor] = []
    @State private var sambaNovaModels: [ProviderModelDescriptor] = []
    @State private var openAIModelsUpdatedAt: Date?
    @State private var sambaNovaModelsUpdatedAt: Date?
    @State private var isOpenAIModelsLoading = false
    @State private var isSambaNovaModelsLoading = false
    @State private var openAIModelsError: String?
    @State private var sambaNovaModelsError: String?
    @AppStorage("openAIChunkingStrategy") private var openAIChunkingStrategy: String = "auto"
    @State private var provider: TranscriptionProvider = .appleCloud
    @State private var nameSuggestionProvider: NameSuggestionProvider = .buildDefault
    @State private var defaultInsightWorkflow: InsightWorkflow = .fallbackDefault
    @State private var selectedSection: WorkflowSection = .capture
    @State private var selectedTranscriptStep: TranscriptWorkspaceStep = .run
    @State private var customInsightsPrompt = InsightWorkflow.meetingNotes.promptTemplate
    @State private var selectedInsightWorkflow = InsightWorkflow.meetingNotes
    @State private var useCustomInsightsPrompt = false
    @State private var isKnownSpeakerHintsExpanded = false
    @State private var isTScriptAdvancedOptionsExpanded = false
    @State private var isSessionDiagnosticsExpanded = false
    @State private var sessionPendingDeletion: RecordingSessionSummary?
    @State private var pendingTranscriptNavigationAfterTranscription = false
    @StateObject private var sessionAudioPlayer = SessionAudioPlaybackController()

    private let nameSuggestionService = NameSuggestionService()
    private let llmModelCatalogService = LLMModelCatalogService()

    init() {
        let config = AIConfigManager.shared.configuration
        _provider = State(initialValue: TranscriptionProvider.fromStoredValue(config.defaultProvider))
        _openAIAPIKey = State(initialValue: AIConfigManager.shared.openAIKey() ?? "")
        _sambaNovaAPIKey = State(initialValue: AIConfigManager.shared.sambaNovaKey() ?? "")
        _sambaNovaBaseURL = State(initialValue: AIConfigManager.shared.baseURL(for: .sambaNova))
        _tScriptConfiguration = State(initialValue: config.tscript)
        _defaultInsightWorkflow = State(initialValue: config.normalizedInsightWorkflow)
        _defaultInsightProvider = State(initialValue: config.normalizedInsightProvider)
        _defaultInsightModelID = State(initialValue: config.defaultInsightModelID)
        _nameSuggestionModelID = State(initialValue: config.nameSuggestionModelID)
        _openAIModels = State(initialValue: config.openAI.cachedModels)
        _sambaNovaModels = State(initialValue: config.sambaNova.cachedModels)
        _openAIModelsUpdatedAt = State(initialValue: config.openAI.modelsUpdatedAt)
        _sambaNovaModelsUpdatedAt = State(initialValue: config.sambaNova.modelsUpdatedAt)
        _selectedInsightWorkflow = State(initialValue: config.normalizedInsightWorkflow)
        _customInsightsPrompt = State(initialValue: config.normalizedInsightWorkflow.promptTemplate)
        if let storedSuggestionProvider = NameSuggestionProvider(rawValue: config.nameSuggestionProvider.lowercased()),
           NameSuggestionProvider.allCases.contains(storedSuggestionProvider) {
            _nameSuggestionProvider = State(initialValue: storedSuggestionProvider)
        } else {
            _nameSuggestionProvider = State(initialValue: .buildDefault)
        }
    }

    private func openAppSettings() {
#if os(macOS)
        openSettings()
#endif
    }

    private func syncPersistedAIConfiguration() {
        let config = AIConfigManager.shared.configuration
        let previousTScriptBaseURL = tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTScriptBaseURL = config.tscript.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        openAIAPIKey = AIConfigManager.shared.openAIKey() ?? ""
        sambaNovaAPIKey = AIConfigManager.shared.sambaNovaKey() ?? ""
        sambaNovaBaseURL = AIConfigManager.shared.baseURL(for: .sambaNova)
        tScriptConfiguration = config.tscript
        openAIModels = config.openAI.cachedModels
        sambaNovaModels = config.sambaNova.cachedModels
        openAIModelsUpdatedAt = config.openAI.modelsUpdatedAt
        sambaNovaModelsUpdatedAt = config.sambaNova.modelsUpdatedAt
        defaultInsightWorkflow = config.normalizedInsightWorkflow
        defaultInsightProvider = config.normalizedInsightProvider
        defaultInsightModelID = config.defaultInsightModelID
        nameSuggestionModelID = config.nameSuggestionModelID
        nameSuggestionProvider = config.normalizedNameSuggestionProvider

        if previousTScriptBaseURL != nextTScriptBaseURL {
            tScriptModelsResponse = nil
            tScriptModelsError = nil
        }

        if appModel.activeSession == nil {
            syncInsightEditorState(from: nil)
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

    private var isSambaNovaKeyConfigured: Bool {
        !sambaNovaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedInsightModelID: String {
        let configured = defaultInsightModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return AIConfigManager.shared.resolvedModelID(for: .insights, provider: defaultInsightProvider)
    }

    private var resolvedNameSuggestionModelID: String {
        let configured = nameSuggestionModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        if let llmProvider = nameSuggestionProvider.llmProvider {
            return AIConfigManager.shared.resolvedModelID(for: .nameSuggestions, provider: llmProvider)
        }
        return ""
    }

    private func isAPIKeyConfigured(for provider: LLMProvider) -> Bool {
        switch provider {
        case .openAI:
            return isOpenAIKeyConfigured
        case .sambaNova:
            return isSambaNovaKeyConfigured
        }
    }

    private func llmModels(for provider: LLMProvider) -> [ProviderModelDescriptor] {
        switch provider {
        case .openAI:
            return openAIModels
        case .sambaNova:
            return sambaNovaModels
        }
    }

    private func availableModels(for provider: LLMProvider, feature: LLMFeature) -> [ProviderModelDescriptor] {
        llmModels(for: provider).filter { $0.supports(feature: feature) }
    }

    private func displayName(for modelID: String, provider: LLMProvider) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return provider.defaultModelID(for: .insights) }
        return llmModels(for: provider).first(where: { $0.id == trimmed })?.displayName ?? trimmed
    }

    private var insightProviderSummary: String {
        "\(defaultInsightProvider.displayName) • \(displayName(for: resolvedInsightModelID, provider: defaultInsightProvider))"
    }

    private var nameSuggestionProviderSummary: String {
        guard let llmProvider = nameSuggestionProvider.llmProvider else {
            return nameSuggestionProvider.displayName
        }
        return "\(llmProvider.displayName) • \(displayName(for: resolvedNameSuggestionModelID, provider: llmProvider))"
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
                tint: TotalRecGlass.warningAmber
            )
        }
        if tScriptRequiresHTTPOverride {
            return ReadinessItem(
                title: "Secure connection required",
                detail: "This TScript endpoint uses HTTP. Enable the insecure HTTP override in Settings only if you trust this server and network.",
                systemImage: "lock.trianglebadge.exclamationmark",
                tint: TotalRecGlass.warningAmber
            )
        }
        if tScriptUsesHTTPOverride {
            return ReadinessItem(
                title: "HTTP override enabled",
                detail: "TScript is using plain HTTP because you explicitly allowed it for this private server.",
                systemImage: "exclamationmark.shield.fill",
                tint: TotalRecGlass.warningAmber
            )
        }
        if tScriptConfiguration.allowInvalidTLSCertificates {
            return ReadinessItem(
                title: "TLS override enabled",
                detail: "The app will accept an invalid TLS certificate for this TScript host. Use this only for a server you control.",
                systemImage: "checkmark.shield.fill",
                tint: TotalRecGlass.warningAmber
            )
        }
        return ReadinessItem(
            title: "Secure connection ready",
            detail: "TScript is configured to use HTTPS for model discovery and transcription.",
            systemImage: "lock.shield.fill",
            tint: TotalRecGlass.successGreen
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

    private var availableTranscriptSteps: [TranscriptWorkspaceStep] {
        TranscriptWorkspaceStep.allCases.filter { step in
            switch step {
            case .run:
                return true
            case .transcript:
                return appModel.transcriptState.hasDisplayText
            case .speakers:
                return appModel.transcriptState.hasSpeakerLabels
            case .document:
                return appModel.transcriptState.hasDisplayText
            }
        }
    }

    private func isTranscriptStepAvailable(_ step: TranscriptWorkspaceStep) -> Bool {
        availableTranscriptSteps.contains(step)
    }

    private var defaultTranscriptStep: TranscriptWorkspaceStep {
        defaultTranscriptStep(for: appModel.transcriptState)
    }

    private var hasTranscriptDisplayText: Bool {
        appModel.transcriptState.hasDisplayText
    }

    private var captureTranscriptPreviewText: String {
        appModel.transcriptState.previewText(maxSegments: 8, maxCharacters: 900)
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
            captureAudioReadinessItem,
            screenCaptureReadinessItem,
            microphoneReadinessItem,
            ReadinessItem(
                title: "Session safety",
                detail: appModel.hasProtectedActivity
                    ? "This session is locked while recording or processing is active."
                    : "Session switching and exports are safe right now.",
                systemImage: appModel.hasProtectedActivity ? "lock.shield.fill" : "checkmark.shield.fill",
                tint: appModel.hasProtectedActivity ? TotalRecGlass.captureBlue : TotalRecGlass.successGreen
            )
        ]
    }

    private var captureAudioReadinessItem: ReadinessItem {
        if appModel.activeSession?.stage == .failed, appModel.audioURL == nil {
            switch appModel.rawCaptureFileState {
            case .candidate:
                return ReadinessItem(
                    title: "Raw capture needs recovery",
                    detail: "The recording did not finish cleanly. Retry audio recovery from Session Details.",
                    systemImage: "arrow.triangle.2.circlepath.circle.fill",
                    tint: TotalRecGlass.warningAmber
                )
            case .empty:
                return ReadinessItem(
                    title: "Recording is empty",
                    detail: "No audio was written to the raw capture. Check recording permissions before trying again.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: TotalRecGlass.warningAmber
                )
            case .missing:
                return ReadinessItem(
                    title: "Recording is unavailable",
                    detail: "The expected raw capture file is missing. Reveal the session folder for details.",
                    systemImage: "waveform.slash",
                    tint: TotalRecGlass.warningAmber
                )
            }
        }

        return ReadinessItem(
            title: appModel.audioURL == nil ? "Session audio pending" : "Session audio ready",
            detail: appModel.isRecording
                ? "Recording is active. Stop when you want to prepare the session audio for transcription."
                : (appModel.audioURL == nil
                    ? "Start a protected recording or import audio into this session."
                    : "Audio has been prepared\(formattedDurationSuffix) and is ready for transcription."),
            systemImage: appModel.isRecording ? "record.circle.fill" : (appModel.audioURL == nil ? "waveform.badge.plus" : "checkmark.circle.fill"),
            tint: appModel.isRecording ? TotalRecGlass.recordingRed : (appModel.audioURL == nil ? TotalRecGlass.captureBlue : TotalRecGlass.successGreen)
        )
    }

    private var rawCaptureDisplayText: String {
        if appModel.isRecording {
            return "Recording in progress"
        }
        if appModel.activeSession?.stage == .mixingDown {
            return "Finalizing capture"
        }
        return appModel.rawCaptureFileState.displayText
    }

    private var rawCaptureNeedsAttention: Bool {
        appModel.activeSession?.stage == .failed && !appModel.rawCaptureFileState.canAttemptRecovery
    }

    private var transcriptionReadinessItems: [ReadinessItem] {
        [
            ReadinessItem(
                title: appModel.audioURL == nil ? "Audio required" : "Audio ready",
                detail: appModel.audioURL == nil
                    ? "Capture or import audio before starting transcription."
                    : "The current session audio is available\(formattedDurationSuffix).",
                systemImage: appModel.audioURL == nil ? "waveform.slash" : "waveform.badge.checkmark",
                tint: appModel.audioURL == nil ? TotalRecGlass.warningAmber : TotalRecGlass.successGreen
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
        let artifactCount = appModel.insightArtifactContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : appModel.insightArtifactContent.count
        let providerReady = isAPIKeyConfigured(for: defaultInsightProvider)
        let insightModelName = displayName(for: resolvedInsightModelID, provider: defaultInsightProvider)

        return [
            ReadinessItem(
                title: hasTranscriptDisplayText ? "Transcript ready" : "Transcript required",
                detail: hasTranscriptDisplayText
                    ? "The current session transcript is available for artifact generation."
                    : "Generate a transcript before creating an insight artifact.",
                systemImage: hasTranscriptDisplayText ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: hasTranscriptDisplayText ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
            ),
            ReadinessItem(
                title: providerReady ? "Provider ready" : "Provider setup required",
                detail: providerReady
                    ? "\(defaultInsightProvider.displayName) is configured to use \(insightModelName) for artifact generation."
                    : "Add a \(defaultInsightProvider.displayName) API key in Settings before generating insights.",
                systemImage: providerReady ? "key.fill" : "exclamationmark.triangle.fill",
                tint: providerReady ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
            ),
            ReadinessItem(
                title: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty ? "Custom prompt required" : "Custom prompt ready")
                    : "Workflow ready",
                detail: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty
                        ? "Enter a custom prompt or switch back to the selected workflow."
                        : "The custom prompt will override the \(selectedInsightWorkflow.displayName.lowercased()) workflow on the next run.")
                    : "\(selectedInsightWorkflow.displayName) is selected for the next artifact run.",
                systemImage: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty ? "text.badge.xmark" : "slider.horizontal.below.rectangle")
                    : "sparkles.rectangle.stack",
                tint: useCustomInsightsPrompt
                    ? (trimmedPrompt.isEmpty ? TotalRecGlass.warningAmber : TotalRecGlass.transcriptViolet)
                    : TotalRecGlass.successGreen
            ),
            ReadinessItem(
                title: appModel.isGeneratingInsightArtifact ? "Artifact in progress" : (artifactCount == 0 ? "Artifact pending" : "Artifact saved"),
                detail: appModel.isGeneratingInsightArtifact
                    ? "A streaming insight run is currently in progress for this session."
                    : (artifactCount == 0
                        ? "Generate an artifact when you want a structured transcript-derived output."
                        : "\(artifactCount) characters are already saved in this session."),
                systemImage: appModel.isGeneratingInsightArtifact ? "hourglass" : (artifactCount == 0 ? "list.bullet.rectangle" : "checkmark.rectangle.stack"),
                tint: appModel.isGeneratingInsightArtifact ? TotalRecGlass.captureBlue : (artifactCount == 0 ? TotalRecGlass.neutralTint : TotalRecGlass.successGreen)
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
                tint: isOpenAIKeyConfigured ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
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
                tint = TotalRecGlass.captureBlue
            } else if let error = tScriptModelsError, !error.isEmpty {
                title = "Model registry needs attention"
                detail = error
                icon = "exclamationmark.triangle.fill"
                tint = TotalRecGlass.warningAmber
            } else if let model = selectedTScriptModel {
                title = model.runtimeAvailable ? "Model ready" : "Model unavailable"
                detail = model.runtimeAvailable
                    ? "\(model.displayName) is available on the current TScript server."
                    : "\(model.displayName) is currently unavailable on the current TScript server."
                icon = model.runtimeAvailable ? "server.rack" : "server.rack"
                tint = model.runtimeAvailable ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
            } else {
                title = "Model registry pending"
                detail = "Refresh models to inspect server capabilities and choose a specific TScript model."
                icon = "square.stack.3d.up.slash"
                tint = TotalRecGlass.neutralTint
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
                tint: hasPartialKnownSpeaker ? TotalRecGlass.warningAmber : TotalRecGlass.transcriptViolet
            )
        case .tscript:
            let selectedModelName = selectedTScriptModel?.displayName ?? "Server default"
            let diarization = effectiveTScriptDiarizationMode == .off
                ? "Diarization off"
                : "Diarization: \(effectiveTScriptDiarizationMode.displayName)"
            let reviewMode = selectedTScriptModel?.supportsTimestamps == true
                ? "Timed review available"
                : "Document review only"
            return ReadinessItem(
                title: selectedTScriptModel?.supportsTimestamps == true || availableTScriptDiarizationModes.count > 1 ? "Model options" : "Model selection",
                detail: "\(selectedModelName) selected. \(reviewMode). \(diarization).",
                systemImage: "slider.horizontal.3",
                tint: TotalRecGlass.transcriptViolet
            )
        case .appleOnDevice, .appleCloud:
            return ReadinessItem(
                title: appModel.isTranscribing ? "Transcription in progress" : "Preview behavior",
                detail: appModel.isTranscribing
                    ? "Partial text appears below while Apple transcription runs."
                    : "Apple transcription can stream partial text into the live preview area while it runs.",
                systemImage: appModel.isTranscribing ? "text.badge.clock" : "text.line.first.and.arrowtriangle.forward",
                tint: appModel.isTranscribing ? TotalRecGlass.captureBlue : TotalRecGlass.neutralTint
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
            tint: granted ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
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
                tint: TotalRecGlass.successGreen
            )
        case .notDetermined:
            return ReadinessItem(
                title: "Microphone permission pending",
                detail: "macOS will ask for mic access the first time you start recording.",
                systemImage: "mic.badge.plus",
                tint: TotalRecGlass.captureBlue
            )
        case .denied, .restricted:
            return ReadinessItem(
                title: "Microphone access blocked",
                detail: "Grant Microphone access in System Settings to capture your voice alongside system audio.",
                systemImage: "mic.slash.fill",
                tint: TotalRecGlass.warningAmber
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
                tint: TotalRecGlass.successGreen
            )
        case .notDetermined:
            return ReadinessItem(
                title: "Speech permission pending",
                detail: "The system will request speech-recognition permission the first time Apple transcription runs.",
                systemImage: "waveform.badge.plus",
                tint: TotalRecGlass.captureBlue
            )
        case .denied, .restricted:
            return ReadinessItem(
                title: "Speech access blocked",
                detail: "Grant Speech Recognition access in System Settings before using the Apple providers.",
                systemImage: "waveform.slash",
                tint: TotalRecGlass.warningAmber
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
            if activeSession.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                items.append(DiagnosticItem(label: "Session title", value: activeSession.displayTitle))
            }
            items.append(DiagnosticItem(label: "Source", value: activeSession.sourceDescription))
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

            if let insightArtifact = appModel.insightArtifact, insightArtifact.hasContent {
                items.append(
                    DiagnosticItem(
                        label: "Insight artifact",
                        value: "\(insightArtifact.workflow.displayName), \(insightArtifact.content.count) characters saved"
                    )
                )
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
            if speakerCount == 0 {
                return "\(segmentCount) clip\(segmentCount == 1 ? "" : "s"), no speaker labels"
            }
            return "\(speakerCount) speaker\(speakerCount == 1 ? "" : "s"), \(segmentCount) segment\(segmentCount == 1 ? "" : "s")"
        }
        let lineCount = appModel.transcriptState.rawText.split(whereSeparator: \.isNewline).count
        return "\(lineCount) transcript line\(lineCount == 1 ? "" : "s")"
    }

    private var hasInvalidCustomInsightsPrompt: Bool {
        useCustomInsightsPrompt && customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isInsightActionDisabled: Bool {
        appModel.isGeneratingInsightArtifact ||
        !hasTranscriptDisplayText ||
        appModel.isTranscribing ||
        !isAPIKeyConfigured(for: defaultInsightProvider) ||
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
        NavigationSplitView {
            sessionSidebarPane
        } detail: {
            mainWorkspacePane
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sessionSidebarPane: some View {
        SessionSidebarView(
            sessionPendingDeletion: $sessionPendingDeletion,
            onToggleRecording: toggleRecording,
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
        .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 340)
    }

    private var mainWorkspacePane: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                TotalRecAmbientBackground(
                    accent: ambientAccentTint,
                    secondaryAccent: ambientSecondaryTint
                )
            )
    }

    private var contentWithChangeHandlers: some View {
        splitWorkspace
            .onAppear {
                normalizeSelectedTranscriptStep(preferred: defaultTranscriptStep)
                syncInsightEditorState(from: appModel.activeSession?.insightSettings)
                syncSessionAudioPlayer()
            }
            .onChange(of: appModel.transcriptState) { oldValue, newValue in
                if pendingTranscriptNavigationAfterTranscription, oldValue != newValue {
                    pendingTranscriptNavigationAfterTranscription = false
                    selectedSection = .transcript
                    normalizeSelectedTranscriptStep(preferred: defaultTranscriptStep(for: newValue))
                } else {
                    normalizeSelectedTranscriptStep()
                }
            }
            .onChange(of: appModel.isTranscribing) { oldValue, newValue in
                if newValue {
                    normalizeSelectedTranscriptStep(preferred: .run)
                } else if oldValue {
                    pendingTranscriptNavigationAfterTranscription = false
                }
            }
            .onChange(of: appModel.activeSession?.id) { _, _ in
                pendingTranscriptNavigationAfterTranscription = false
                normalizeSelectedTranscriptStep(preferred: defaultTranscriptStep)
                syncInsightEditorState(from: appModel.activeSession?.insightSettings)
                syncSessionAudioPlayer()
            }
            .onChange(of: appModel.audioURL) { _, _ in
                syncSessionAudioPlayer()
            }
            .onChange(of: appModel.mixedAudioDuration) { _, _ in
                syncSessionAudioPlayer()
            }
            .onChange(of: selectedSection) { _, newSection in
                if newSection == .transcript {
                    normalizeSelectedTranscriptStep()
                } else if newSection == .insights {
                    sessionAudioPlayer.pause()
                }
            }
            .onChange(of: selectedTranscriptStep) { _, newStep in
                if newStep != .run {
                    sessionAudioPlayer.pause()
                }
            }
            .onChange(of: appModel.insightArtifactContent) { oldValue, newValue in
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
            Button {
                saveAudio()
            } label: {
                Label("Save Audio…", systemImage: "square.and.arrow.down")
            }
            Button(action: saveTranscript) {
                Label("Save Transcript…", systemImage: "square.and.arrow.down")
            }
                .disabled(appModel.transcriptState.isEmpty)
            Button("Start Fresh Recording", role: .destructive) {
                appModel.startRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing session remains on disk, but the main window will switch to a new recording session.")
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
            Button("Delete \(session.displayTitle)", role: .destructive) {
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
            Text("This removes the session and its saved audio, transcript, and insight artifact from disk.")
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
                    appModel.showNotice("Failed to save default provider: \(error.localizedDescription)", style: .error)
                }
            }
            .onChange(of: tScriptConfiguration) { oldValue, newValue in
                handleTScriptConfigurationChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: tScriptConfiguration.selectedModelID) { _, _ in
                guard let model = selectedTScriptModel else { return }
                normalizeTScriptDiarizationSelection(for: model)
                if !model.supportsTranslation {
                    tScriptConfiguration.translate = false
                }
            }
            .onChange(of: useCustomInsightsPrompt) { _, newValue in
                if newValue && customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    customInsightsPrompt = selectedInsightWorkflow.promptTemplate
                }
                persistInsightEditorState()
            }
            .onChange(of: selectedInsightWorkflow) { _, newWorkflow in
                if !useCustomInsightsPrompt {
                    customInsightsPrompt = newWorkflow.promptTemplate
                }
                persistInsightEditorState()
            }
            .onChange(of: customInsightsPrompt) { _, _ in
                persistInsightEditorState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .totalRecAIConfigurationDidChange)) { _ in
                syncPersistedAIConfiguration()
            }
    }

    private var presentedContent: some View {
        contentWithPreferences
            .toolbar {
                ToolbarItem(placement: .principal) {
                    workflowSectionPicker
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openAppSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                }
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
            if let notice = appModel.transientNotice {
                TransientNoticeBanner(
                    notice: notice,
                    onDismiss: appModel.dismissTransientNotice
                )
                .id(notice.id)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let recoveryNotice = appModel.recoveryNotice {
                statusBanner(
                    recoveryNotice,
                    systemImage: "arrow.triangle.2.circlepath.circle.fill",
                    tint: TotalRecGlass.warningAmber,
                    dismissAction: {
                        appModel.dismissRecoveryNotice()
                    }
                )
            }

            if let currentLiveActivityStage {
                activityBanner(for: currentLiveActivityStage)
            }
            currentSectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private var currentLiveActivityStage: SessionStage? {
        guard let stage = appModel.activeSession?.stage, stage.totalRecShowsLiveActivity else { return nil }
        return stage
    }

    private func activityBanner(for stage: SessionStage) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TotalRecGlass.tonedTint(stage.totalRecStatusTint, usage: .secondarySurface).opacity(0.16))

                TotalRecActivitySymbol(
                    systemImage: stage.totalRecMenuBarIconName,
                    tint: stage.totalRecStatusTint,
                    motion: stage.totalRecActivityMotion,
                    size: 20,
                    weight: .bold
                )
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(stage.totalRecProgressHeadline)
                    .font(.headline)

                Text(appModel.statusText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(activitySupportText(for: stage))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    activityMetaPill("Session locked", systemImage: "lock.fill", tint: TotalRecGlass.recordingRed)

                    if stage == .recording, let elapsed = appModel.recordingElapsedText {
                        activityMetaPill(elapsed, systemImage: "timer", tint: TotalRecGlass.recordingRed)
                    }

                    if stage == .transcribing, !appModel.processingPreviewText.isEmpty {
                        activityMetaPill("Live preview", systemImage: "text.line.first.and.arrowtriangle.forward", tint: TotalRecGlass.successGreen)
                    }

                    if stage == .generatingInsights {
                        insightStopButton
                    }
                }

                VStack(alignment: .trailing, spacing: 8) {
                    activityMetaPill("Session locked", systemImage: "lock.fill", tint: TotalRecGlass.recordingRed)

                    if stage == .recording, let elapsed = appModel.recordingElapsedText {
                        activityMetaPill(elapsed, systemImage: "timer", tint: TotalRecGlass.recordingRed)
                    }

                    if stage == .transcribing, !appModel.processingPreviewText.isEmpty {
                        activityMetaPill("Live preview", systemImage: "text.line.first.and.arrowtriangle.forward", tint: TotalRecGlass.successGreen)
                    }

                    if stage == .generatingInsights {
                        insightStopButton
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticRoundedRect(cornerRadius: 16, tint: stage.totalRecStatusTint)
    }

    private func activitySupportText(for stage: SessionStage) -> String {
        if stage == .generatingInsights, appModel.isStoppingInsightArtifact {
            return "Stopping the current insight run. The session will unlock as soon as the stream cancels."
        }
        if stage == .transcribing, !appModel.processingPreviewText.isEmpty {
            return "Partial text is updating live below while the transcript is assembled. Session switching stays locked until the run completes."
        }
        return stage.totalRecProgressSupportText
    }

    private func activityMetaPill(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .totalRecStaticPill(tint: tint)
    }

    private var insightStopButton: some View {
        Button {
            appModel.stopInsightArtifactGeneration()
        } label: {
            Label(
                appModel.isStoppingInsightArtifact ? "Stopping…" : "Stop",
                systemImage: appModel.isStoppingInsightArtifact ? "hourglass" : "stop.fill"
            )
        }
        .disabled(appModel.isStoppingInsightArtifact)
        .totalRecGlassButton(tint: TotalRecGlass.recordingRed)
    }

    private var workflowSectionPicker: some View {
        Picker("Workflow", selection: $selectedSection) {
            ForEach(WorkflowSection.allCases) { section in
                Text(section.rawValue)
                    .tag(section)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 290)
    }

    private var transcriptStepPicker: some View {
        Picker("Transcript Step", selection: $selectedTranscriptStep) {
            ForEach(TranscriptWorkspaceStep.allCases) { step in
                Text(step.rawValue)
                    .tag(step)
                    .disabled(!isTranscriptStepAvailable(step))
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
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

    private func transcriptStepIcon(_ step: TranscriptWorkspaceStep) -> String {
        switch step {
        case .run:
            return "slider.horizontal.3"
        case .transcript:
            return "text.cursor"
        case .speakers:
            return "person.2"
        case .document:
            return "doc.text"
        }
    }

    private func workflowSectionDescription(_ section: WorkflowSection) -> String {
        switch section {
        case .capture:
            return "Record system audio or import a file into a recoverable session."
        case .transcript:
            return "Run transcription, correct wording, and clean speaker assignments."
        case .insights:
            return "Generate notes and structured summaries from the session transcript."
        }
    }

    private func workflowSectionTint(_ section: WorkflowSection) -> Color {
        switch section {
        case .capture:
            return appModel.isRecording ? TotalRecGlass.recordingRed : TotalRecGlass.captureBlue
        case .transcript:
            return TotalRecGlass.transcriptViolet
        case .insights:
            return TotalRecGlass.insightsGreen
        }
    }

    private var providerAccentTint: Color {
        switch provider {
        case .openAI:
            return isOpenAIKeyConfigured ? TotalRecGlass.warningAmber : TotalRecGlass.recordingRed
        case .tscript:
            return selectedTScriptModel == nil ? TotalRecGlass.neutralTint : TotalRecGlass.transcriptViolet
        case .appleOnDevice:
            return Color(red: 0.28, green: 0.58, blue: 0.62)
        case .appleCloud:
            return Color(red: 0.30, green: 0.56, blue: 0.78)
        }
    }

    private var ambientAccentTint: Color {
        if appModel.isRecording {
            return TotalRecGlass.recordingRed
        }

        switch provider {
        case .openAI:
            return isOpenAIKeyConfigured ? TotalRecGlass.warningAmber : TotalRecGlass.captureBlue
        case .tscript:
            return selectedTScriptModel == nil ? TotalRecGlass.neutralTint : TotalRecGlass.transcriptViolet
        case .appleOnDevice:
            return Color(red: 0.28, green: 0.58, blue: 0.62)
        case .appleCloud:
            return Color(red: 0.30, green: 0.56, blue: 0.78)
        }
    }

    private var ambientSecondaryTint: Color {
        if let stage = appModel.activeSession?.stage, stage.totalRecShowsLiveActivity {
            return stage.totalRecStatusTint
        }
        return TotalRecGlass.neutralTint
    }

    private func sessionStageTitle(_ stage: SessionStage) -> String {
        stage.totalRecStatusLabel
    }

    private func sessionStageIcon(_ stage: SessionStage) -> String {
        stage.totalRecStatusIcon
    }

    private func sessionStageTint(_ stage: SessionStage) -> Color {
        stage.totalRecStatusTint
    }

    private func detailBadge(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(TotalRecGlass.accentForeground(tint))
            Text(title)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .totalRecGlassPill(tint: tint)
    }

    private func statusBanner(
        _ message: String,
        systemImage: String,
        tint: Color,
        dismissAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(TotalRecGlass.accentForeground(tint))
                .padding(.top, 2)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)

            Spacer()

            if let dismissAction {
                Button("Dismiss", action: dismissAction)
                    .totalRecGlassButton()
                    .font(.caption)
            }
        }
        .padding(12)
        .totalRecStaticRoundedRect(cornerRadius: 12, tint: tint)
    }

    private func pageCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticPanel(cornerRadius: 18)
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

    private func readinessSummary(
        title: String,
        subtitle: String,
        items: [ReadinessItem]
    ) -> some View {
        pageCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text("\(items.count) checks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(items) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .totalRecStaticPill(tint: item.tint)
                            .accessibilityLabel("\(item.title). \(item.detail)")
                    }
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            readinessDetailRow(item)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Review readiness details")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func readinessDetailRow(_ item: ReadinessItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.systemImage)
                .foregroundStyle(TotalRecGlass.accentForeground(item.tint))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionDiagnosticsCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Session Details")
                    .font(.headline)

                if let error = appModel.activeSession?.lastError, !error.isEmpty {
                    statusBanner(
                        error,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: TotalRecGlass.warningAmber
                    )

                    HStack(spacing: 10) {
                        if appModel.canRetryRecordingFinalization {
                            Button {
                                Task {
                                    await appModel.retryRecordingFinalization()
                                }
                            } label: {
                                Label("Retry Audio Recovery", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderedProminent)
                        }

#if os(macOS)
                        if appModel.activeSessionDirectoryURL != nil {
                            Button(action: revealActiveSessionFolder) {
                                Label("Reveal Session Folder", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
#endif
                    }
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
        detail: String? = nil,
        detailSystemImage: String = "sparkles",
        detailTint: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label {
                    Text(title)
                        .font(.title3.bold())
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }

                Spacer(minLength: 12)

                if let detail {
                    detailBadge(detail, systemImage: detailSystemImage, tint: detailTint ?? tint)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captureSection: some View {
        sectionScrollContainer {
            workspaceHero(
                title: appModel.isRecording ? "Recording" : "Capture",
                description: "Record system audio or import a file into the current session.",
                systemImage: appModel.isRecording ? "record.circle.fill" : "waveform.circle.fill",
                tint: workflowSectionTint(.capture),
                detail: appModel.audioURL == nil ? nil : "Audio ready\(formattedDurationSuffix)"
            )

            capturePrimaryActionsCard

            readinessSummary(
                title: "Capture readiness",
                subtitle: "Check the essentials, then record or import.",
                items: captureReadinessItems
            )

            sessionAudioPlayerCard

            if appModel.isRecording || appModel.tempMOVURL != nil || appModel.audioURL != nil {
                pageCard {
                    Text("Session Files")
                        .font(.headline)

                    if appModel.isRecording {
                        statusBanner(
                            "Recording continues even if you close the main window. Use the explicit stop action here or from the menu bar.",
                            systemImage: "shield.lefthalf.filled",
                            tint: TotalRecGlass.captureBlue
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if let mov = appModel.tempMOVURL {
                            LabeledContent("Raw capture") {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(rawCaptureDisplayText)
                                        .foregroundStyle(rawCaptureNeedsAttention ? TotalRecGlass.accentForeground(TotalRecGlass.warningAmber) : Color.secondary)
                                    Text(mov.lastPathComponent)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
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
            }

            if appModel.audioURL != nil || appModel.transcriptState.hasDisplayText {
                captureExportsCard
            }

            sessionDiagnosticsCard

            if hasTranscriptDisplayText {
                pageCard {
                    Text("Transcript Preview")
                        .font(.headline)

                    ScrollView {
                        Text(captureTranscriptPreviewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                            .totalRecReadableInset(cornerRadius: 14)
                    }
                    .frame(minHeight: 140, maxHeight: 240)
                }
            } else {
                ContentUnavailableView(
                    "No Transcript Yet",
                    systemImage: "waveform",
                    description: Text("Capture or import audio, then run transcription when the session is ready.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }

    private var capturePrimaryActionsCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Capture Audio")
                    .font(.headline)

                Text(capturePrimaryActionDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    capturePrimaryButtons
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 10) {
                    capturePrimaryButtons
                }
            }
        }
    }

    private var capturePrimaryActionDescription: String {
        if appModel.isRecording {
            return "Recording is protected in the current session. Stop when you are ready to prepare the audio."
        }
        if appModel.audioURL != nil {
            return "This session already has audio. Import a replacement or start a fresh recording session."
        }
        return "Start a protected system-audio recording or bring in an existing audio file."
    }

    private var capturePrimaryButtons: some View {
        Group {
            Button(action: toggleRecording) {
                Label(
                    appModel.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: appModel.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(appModel.isRecording ? TotalRecGlass.recordingRed : TotalRecGlass.captureBlue)
            .disabled(appModel.isBusy && !appModel.isRecording)
            .keyboardShortcut("r", modifiers: [.command])

            Button {
                showImportOptionsDialog = true
            } label: {
                Label("Import Audio…", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.bordered)
            .disabled(appModel.isBusy)

            if appModel.activeSession != nil {
                Button {
                    appModel.showNewSessionWorkspace()
                } label: {
                    Label("Start Fresh", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(appModel.hasProtectedActivity)
            }
        }
    }

    private var captureExportsCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export")
                    .font(.headline)
                Text("Save completed session artifacts or copy the transcript for use elsewhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            captureExportLayout
        }
    }

    private var captureExportLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                captureExportButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                captureExportButtons
            }
        }
    }

    private var captureExportButtons: some View {
        Group {
            if appModel.audioURL != nil {
                Button(action: saveAudio) {
                    Label("Save Audio…", systemImage: "square.and.arrow.down")
                }
                .totalRecGlassButton()
            }

            if appModel.transcriptState.hasDisplayText {
                Button {
                    copyTranscriptAsMarkdown()
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .totalRecGlassButton()

                Button(action: saveTranscript) {
                    Label("Save Transcript…", systemImage: "square.and.arrow.down")
                }
                .totalRecGlassButton()
            }
        }
    }

    private var transcriptSection: some View {
        sectionScrollContainer {
            transcriptSectionOverview
            transcriptStepNavigationBar
            transcriptStepContent
        }
    }

    private var transcriptSectionOverview: some View {
        workspaceHero(
            title: "Transcript",
            description: transcriptStepDescription(for: selectedTranscriptStep),
            systemImage: "text.quote",
            tint: workflowSectionTint(.transcript),
            detail: appModel.transcriptState.workspaceSummary
                ?? (appModel.audioURL == nil ? nil : "Audio ready\(formattedDurationSuffix)")
        )
    }

    private var transcriptStepNavigationBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript Views")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            transcriptStepPicker
                .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticRoundedRect(cornerRadius: 16)
    }

    @ViewBuilder
    private var transcriptStepContent: some View {
        transcriptStepView(for: selectedTranscriptStep)
    }

    @ViewBuilder
    private func transcriptStepView(for step: TranscriptWorkspaceStep) -> some View {
        switch step {
        case .run:
            transcriptRunStepContent
        case .transcript:
            transcriptTranscriptStepContent
        case .speakers:
            transcriptSpeakersStepContent
        case .document:
            transcriptDocumentStepContent
        }
    }

    private var transcriptRunStepContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionAudioPlayerCard
            transcriptionSetupCard
            transcriptRunActionCard
            readinessSummary(
                title: "Transcription readiness",
                subtitle: "Provider setup, audio availability, and hint quality.",
                items: transcriptionReadinessItems
            )
            sessionDiagnosticsCard
        }
    }

    private var sessionAudioPlayerCard: some View {
        pageCard {
            SessionAudioPlayerView(controller: sessionAudioPlayer)
        }
    }

    private func syncSessionAudioPlayer() {
        sessionAudioPlayer.updateSession(
            audioURL: appModel.audioURL,
            duration: appModel.mixedAudioDuration
        )
    }

    private var transcriptRunActionCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(hasTranscriptDisplayText ? "Run Again" : "Run Transcription")
                    .font(.headline)

                if appModel.audioURL == nil {
                    Text("Capture or import audio first.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        transcribe()
                    } label: {
                        if appModel.isTranscribing {
                            HStack(spacing: 8) {
                                TotalRecActivitySymbol(
                                    systemImage: SessionStage.transcribing.totalRecMenuBarIconName,
                                    tint: SessionStage.transcribing.totalRecStatusTint,
                                    motion: SessionStage.transcribing.totalRecActivityMotion,
                                    size: 12,
                                    weight: .bold
                                )
                                Text("Transcribing…")
                            }
                        } else {
                            Text(hasTranscriptDisplayText ? "Re-run Transcription" : "Transcribe Audio")
                        }
                    }
                    .disabled(isTranscriptionActionDisabled)
                    .totalRecGlassButton(prominent: true)
                }

                if hasTranscriptDisplayText {
                    Text("Running again replaces the current transcript for this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !appModel.processingPreviewText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Preview")
                            .font(.headline)
                        Text(appModel.processingPreviewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .totalRecReadableInset(cornerRadius: 14)
                    }
                }
            }
        }
    }

    private var transcriptTranscriptStepContent: some View {
        pageCard {
            if appModel.transcriptState.hasDisplayText {
                TranscriptEditorView(
                    transcript: transcriptBinding,
                    audioURL: appModel.audioURL,
                    audioDuration: appModel.mixedAudioDuration
                )
            } else {
                transcriptStepUnavailableView(
                    title: "Transcript editing unavailable",
                    message: "Run transcription first to populate transcript text before editing wording or applying replacements."
                )
            }
        }
    }

    private var transcriptSpeakersStepContent: some View {
        pageCard {
            if appModel.transcriptState.hasSpeakerLabels {
                TranscriptSpeakersView(
                    transcript: transcriptBinding,
                    audioURL: appModel.audioURL,
                    audioDuration: appModel.mixedAudioDuration,
                    suggestionService: nameSuggestionService,
                    areSuggestionsEnabled: BuildFeatures.nameSuggestionsEnabled && nameSuggestionProvider != .disabled,
                    suggestionProviderName: nameSuggestionProviderSummary,
                    onStatusMessage: { message in
                        appModel.showNotice(message)
                    }
                )
            } else {
                transcriptStepUnavailableView(
                    title: "Speaker tools unavailable",
                    message: "This transcript does not include speaker labels. Run a diarized provider to enable speaker cleanup."
                )
            }
        }
    }

    private var transcriptDocumentStepContent: some View {
        pageCard {
            if appModel.transcriptState.hasDisplayText {
                TranscriptDocumentView(
                    transcript: appModel.transcriptState,
                    onCopyMarkdown: copyTranscriptAsMarkdown,
                    onSaveTranscript: saveTranscript
                )
            } else {
                transcriptStepUnavailableView(
                    title: "Transcript document unavailable",
                    message: "Run transcription first to populate the transcript document and export tools."
                )
            }
        }
    }

    private func transcriptStepUnavailableView(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptionSetupCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Transcription Setup")
                        .font(.headline)

                        Spacer()

                        if provider == .openAI || provider == .tscript {
                            Button(provider == .openAI ? "Manage API Key" : "Manage Server") {
                                openAppSettings()
                            }
                            .totalRecGlassButton()
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
                         ? "On-device transcription stays local when available."
                         : "Apple Cloud transcription uses Apple's speech service when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var openAITranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                TotalRecGlassCluster(spacing: 14) {
                    HStack(spacing: 8) {
                        detailBadge(
                            isOpenAIKeyConfigured ? "API key ready" : "API key required",
                            systemImage: isOpenAIKeyConfigured ? "key.fill" : "exclamationmark.triangle.fill",
                            tint: isOpenAIKeyConfigured ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
                        )

                        detailBadge(
                            openAIChunkingDisplayName,
                            systemImage: openAIChunkingStrategy == "none" ? "arrow.up.doc" : "square.split.2x2",
                            tint: TotalRecGlass.captureBlue
                        )

                        detailBadge(
                            knownSpeakerHintCount == 0 ? "No speaker hints" : "\(knownSpeakerHintCount) speaker hints",
                            systemImage: "person.2.fill",
                            tint: knownSpeakerHintCount == 0 ? TotalRecGlass.neutralTint : TotalRecGlass.transcriptViolet
                        )

                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    detailBadge(
                        isOpenAIKeyConfigured ? "API key ready" : "API key required",
                        systemImage: isOpenAIKeyConfigured ? "key.fill" : "exclamationmark.triangle.fill",
                        tint: isOpenAIKeyConfigured ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
                    )

                    HStack(spacing: 8) {
                        detailBadge(
                            openAIChunkingDisplayName,
                            systemImage: openAIChunkingStrategy == "none" ? "arrow.up.doc" : "square.split.2x2",
                            tint: TotalRecGlass.captureBlue
                        )

                        detailBadge(
                            knownSpeakerHintCount == 0 ? "No speaker hints" : "\(knownSpeakerHintCount) speaker hints",
                            systemImage: "person.2.fill",
                            tint: knownSpeakerHintCount == 0 ? TotalRecGlass.neutralTint : TotalRecGlass.transcriptViolet
                        )
                    }
                }
            }

            if !isOpenAIKeyConfigured {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))

                    Text("OpenAI transcription requires an API key stored in Keychain. Use Settings to add or replace it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .totalRecGlassButton()
                }
                .padding(12)
                .totalRecGlassRoundedRect(cornerRadius: 12, tint: TotalRecGlass.warningAmber)
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
                        .totalRecGlassButton()
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
                    tint: TotalRecGlass.warningAmber
                )
            }
        }
    }

    private var tScriptTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            let transportItem = tScriptTransportReadinessItem
            ViewThatFits(in: .horizontal) {
                TotalRecGlassCluster(spacing: 14) {
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
                                tint: model.runtimeAvailable ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
                            )
                        }

                        if isTScriptModelsLoading {
                            detailBadge(
                                "Refreshing models",
                                systemImage: "arrow.triangle.2.circlepath",
                                tint: TotalRecGlass.captureBlue
                            )
                        }

                        Spacer(minLength: 0)
                    }
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
                                tint: model.runtimeAvailable ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
                            )
                        }

                        if isTScriptModelsLoading {
                            detailBadge(
                                "Refreshing models",
                                systemImage: "arrow.triangle.2.circlepath",
                                tint: TotalRecGlass.captureBlue
                            )
                        }
                    }
                }
            }

            if !tScriptBaseURLConfigured {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))

                    Text("TScript transcription requires a server base URL in Settings before the app can discover models.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .totalRecGlassButton()
                }
                .padding(12)
                .totalRecGlassRoundedRect(cornerRadius: 12, tint: TotalRecGlass.warningAmber)
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
                    .totalRecGlassButton()
                    .disabled(isTScriptModelsLoading)
                }
            }

            if let warning = tScriptTransportWarningText {
                statusBanner(
                    warning,
                    systemImage: "exclamationmark.shield.fill",
                    tint: TotalRecGlass.warningAmber
                )
            }

            if let error = tScriptModelsError, !error.isEmpty {
                statusBanner(
                    error,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: TotalRecGlass.warningAmber
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
                VStack(alignment: .leading, spacing: 8) {
                    if model.supportsTranslation {
                        Toggle("Translate", isOn: $tScriptConfiguration.translate)
                    }
                    if model.supportsTimestamps {
                        Text("Timestamps are requested automatically for models that support timed output so playback stays available in Transcript and Speakers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private func defaultTranscriptStep(for transcript: TranscriptState) -> TranscriptWorkspaceStep {
        if transcript.hasDisplayText {
            return .transcript
        }
        return .run
    }

    private func normalizeSelectedTranscriptStep(preferred: TranscriptWorkspaceStep? = nil) {
        let candidate = preferred ?? selectedTranscriptStep
        if availableTranscriptSteps.contains(candidate) {
            selectedTranscriptStep = candidate
        } else {
            selectedTranscriptStep = defaultTranscriptStep
        }
    }

    private func transcriptStepDescription(for step: TranscriptWorkspaceStep) -> String {
        switch step {
        case .run:
            return "Configure the provider, model, and per-run options before you transcribe or re-run this session."
        case .transcript:
            return "Correct wording, apply literal replacements, and play timed clips when they are available."
        case .speakers:
            return "Focus on aliases, filtered speaker playback, reassignment, and explicit consolidation."
        case .document:
            return "Read the final transcript as a document and export the current state once cleanup is complete."
        }
    }

    private var insightsSection: some View {
        sectionScrollContainer {
            workspaceHero(
                title: "Insights",
                description: "Turn the transcript into reusable summaries, decision logs, action lists, and other workflow-specific outputs.",
                systemImage: "list.bullet.rectangle.portrait",
                tint: workflowSectionTint(.insights),
                detail: hasTranscriptDisplayText ? "Transcript ready" : "Transcript required",
                detailSystemImage: hasTranscriptDisplayText ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                detailTint: hasTranscriptDisplayText ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
            )

            readinessSummary(
                title: "Insights readiness",
                subtitle: "Transcript, provider setup, and current artifact state.",
                items: insightsReadinessItems
            )

            insightsPanel
        }
    }

    private var insightsPanel: some View {
        TranscriptSurfacePanel(
            title: "Insight Workflow",
            subtitle: "Generate a transcript-derived artifact for the current session."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        insightActionButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        insightActionButtons
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        detailBadge(
                            defaultInsightProvider.displayName,
                            systemImage: "cpu",
                            tint: workflowSectionTint(.insights)
                        )

                        detailBadge(
                            displayName(for: resolvedInsightModelID, provider: defaultInsightProvider),
                            systemImage: "square.stack.3d.up",
                            tint: TotalRecGlass.transcriptViolet
                        )

                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        detailBadge(
                            defaultInsightProvider.displayName,
                            systemImage: "cpu",
                            tint: workflowSectionTint(.insights)
                        )

                        detailBadge(
                            displayName(for: resolvedInsightModelID, provider: defaultInsightProvider),
                            systemImage: "square.stack.3d.up",
                            tint: TotalRecGlass.transcriptViolet
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Workflow")
                                .font(.subheadline.weight(.semibold))
                            Picker("Workflow", selection: $selectedInsightWorkflow) {
                                ForEach(InsightWorkflow.allCases) { workflow in
                                    Text(workflow.displayName).tag(workflow)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(selectedInsightWorkflow.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle(isOn: $useCustomInsightsPrompt.animation()) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Customize Prompt")
                                    .font(.subheadline)
                                Text("Switch this on to override the workflow template. Keep the {{TRANSCRIPT}} token where transcript text should be inserted.")
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
                                .totalRecReadableInset(cornerRadius: 14)

                            HStack {
                                Text("Start from the template, then tailor it to your workflow.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset to template") {
                                    customInsightsPrompt = selectedInsightWorkflow.promptTemplate
                                }
                                .font(.caption)
                            }
                        } else {
                            Text("Using the \(selectedInsightWorkflow.displayName.lowercased()) workflow template.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = appModel.insightRunError, !error.isEmpty {
                        Text(error)
                            .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.recordingRed))
                            .font(.footnote)
                    }

                    if appModel.isGeneratingInsightArtifact || !appModel.insightStreamingText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Label("Live Output", systemImage: "text.append")
                                    .font(.subheadline.weight(.semibold))
                                if appModel.isGeneratingInsightArtifact {
                                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                                        if let elapsed = appModel.insightRunElapsedText {
                                            Text(elapsed)
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } else if appModel.insightArtifact != nil {
                                    Text("Unsaved partial output")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))
                                }
                            }

                            artifactPreview(
                                title: appModel.isGeneratingInsightArtifact ? "Streaming artifact" : "Partial run output",
                                subtitle: appModel.isGeneratingInsightArtifact
                                    ? "The new artifact is streaming now. The saved artifact stays unchanged until this run completes."
                                    : "This output was not saved because the last run did not complete.",
                                content: appModel.insightStreamingText
                            )
                        }
                    }

                    if appModel.isGeneratingInsightArtifact, let insightArtifact = appModel.insightArtifact {
                        artifactPreview(
                            title: "Last saved artifact",
                            subtitle: "\(insightArtifact.workflow.displayName) from \(insightArtifact.generatedAt.formatted(date: .abbreviated, time: .shortened))",
                            content: insightArtifact.content
                        )
                    } else if let insightArtifact = appModel.insightArtifact {
                        artifactPreview(
                            title: insightArtifact.title,
                            subtitle: artifactMetadataSummary(for: insightArtifact),
                            content: insightArtifact.content
                        )
                    } else if appModel.insightStreamingText.isEmpty {
                        Text("No insight artifact yet. Generate one to see a workflow-specific summary of this transcript.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var insightActionButtons: some View {
        Group {
            if appModel.isGeneratingInsightArtifact {
                Button {
                    appModel.stopInsightArtifactGeneration()
                } label: {
                    Label(
                        appModel.isStoppingInsightArtifact ? "Stopping…" : "Stop",
                        systemImage: appModel.isStoppingInsightArtifact ? "hourglass" : "stop.fill"
                    )
                }
                .disabled(appModel.isStoppingInsightArtifact)
                .totalRecGlassButton(tint: TotalRecGlass.recordingRed)
            } else {
                Button("Generate Artifact") {
                    runInsightsGeneration()
                }
                .disabled(isInsightActionDisabled)
                .totalRecGlassButton(prominent: true)
            }

            Button {
                copyInsightArtifactToClipboard()
            } label: {
                Label("Copy Artifact", systemImage: "doc.on.doc")
            }
            .totalRecGlassButton()
            .disabled(appModel.insightArtifact == nil)

            Button {
                saveInsightArtifact()
            } label: {
                Label("Save Artifact…", systemImage: "square.and.arrow.down")
            }
            .totalRecGlassButton()
            .disabled(appModel.insightArtifact == nil)
        }
    }

    private func artifactPreview(title: String, subtitle: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .totalRecReadableInset(cornerRadius: 14)
            }
            .frame(minHeight: 180)
        }
    }

    private func artifactMetadataSummary(for artifact: InsightArtifact) -> String {
        "\(artifact.workflow.displayName) • \(artifact.generatedAt.formatted(date: .abbreviated, time: .shortened)) • \(artifact.provider.displayName) • \(artifact.modelID)"
    }

    private func runInsightsGeneration() {
        let trimmedPrompt = customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if useCustomInsightsPrompt && trimmedPrompt.isEmpty {
            appModel.insightRunError = "Enter a custom prompt or disable the custom prompt override."
            appModel.showNotice("Insight generation failed: Custom prompt required.", style: .warning)
            return
        }

        if !isAPIKeyConfigured(for: defaultInsightProvider) {
            appModel.insightRunError = "\(defaultInsightProvider.displayName) API key missing."
            appModel.showNotice("Insight generation failed: \(defaultInsightProvider.displayName) API key missing.", style: .warning)
            openAppSettings()
            return
        }

        persistInsightEditorState()

        appModel.startInsightArtifactGeneration()
    }

    private func syncInsightEditorState(from settings: InsightSettings?) {
        let resolved = settings ?? InsightSettings(selectedWorkflow: defaultInsightWorkflow)
        selectedInsightWorkflow = resolved.selectedWorkflow
        useCustomInsightsPrompt = resolved.useCustomPrompt
        customInsightsPrompt = resolved.customPrompt
    }

    private func persistInsightEditorState() {
        guard appModel.activeSession != nil else { return }
        appModel.updateInsightSettings(
            InsightSettings(
                selectedWorkflow: selectedInsightWorkflow,
                useCustomPrompt: useCustomInsightsPrompt,
                customPrompt: customInsightsPrompt
            )
        )
    }

    private func transcribe() {
        guard appModel.audioURL != nil else { return }

        if provider == .openAI && !isOpenAIKeyConfigured {
            appModel.showNotice("OpenAI API key missing. Open Settings to configure it.", style: .warning)
            openAppSettings()
            return
        }

        if provider == .openAI && hasPartialKnownSpeaker {
            appModel.showNotice("Please provide both a Name and a Sample for each known speaker, or clear the incomplete rows.", style: .warning)
            return
        }

        if provider == .tscript && !tScriptBaseURLConfigured {
            appModel.showNotice("TScript base URL missing. Open Settings to configure it.", style: .warning)
            openAppSettings()
            return
        }

        if provider == .tscript && tScriptRequiresHTTPOverride {
            appModel.showNotice(tScriptTransportReadinessItem.detail, style: .warning)
            openAppSettings()
            return
        }

        if provider == .tscript, let model = selectedTScriptModel, !model.runtimeAvailable {
            appModel.showNotice("Selected TScript model is unavailable. Refresh models or choose another model.", style: .warning)
            return
        }

        pendingTranscriptNavigationAfterTranscription = true
        normalizeSelectedTranscriptStep(preferred: .run)

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
                            configuration: effectiveTScriptConfigurationForRun()
                        )
                        : nil
                )
            )
        }
    }

    private func effectiveTScriptConfigurationForRun() -> TScriptConfiguration {
        guard let model = selectedTScriptModel else {
            return tScriptConfiguration
        }

        var configuration = tScriptConfiguration
        configuration.diarizationMode = model.normalizedDiarizationMode(configuration.diarizationMode)
        if !model.supportsTranslation {
            configuration.translate = false
        }
        return configuration
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

    private func handleTScriptConfigurationChange(oldValue: TScriptConfiguration, newValue: TScriptConfiguration) {
        do {
            try AIConfigManager.shared.updateTScriptConfiguration(newValue)
        } catch {
            appModel.showNotice("Failed to save TScript settings: \(error.localizedDescription)", style: .error)
        }

        let oldBaseURL = oldValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBaseURL = newValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldBaseURL != newBaseURL {
            tScriptModelsResponse = nil
            tScriptModelsError = nil
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
                    appModel.showNotice("Save failed: \(error.localizedDescription)", style: .error)
                }
            }
        }
#endif
    }

    private func saveTranscript() {
        guard !appModel.transcriptState.isEmpty else { return }
#if os(macOS)
        let stateToSave = appModel.transcriptState
        let availableFormats = transcriptExportFormats(for: stateToSave)
        let panel = NSSavePanel()
        let coordinator = TranscriptSavePanelCoordinator(
            panel: panel,
            formats: availableFormats,
            hasSpeakerLabels: stateToSave.hasSpeakerLabels
        )
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Transcript"
        panel.prompt = "Save"
        panel.showsTagField = false
        panel.allowedContentTypes = availableFormats.map(\.contentType)
        panel.delegate = coordinator
        if #available(macOS 15.0, *) {
            panel.showsContentTypes = availableFormats.count > 1
            panel.currentContentType = availableFormats[0].contentType
        }
        panel.nameFieldStringValue = availableFormats[0].suggestedFilename(hasSpeakerLabels: stateToSave.hasSpeakerLabels)
        panel.begin { response in
            if response == .OK, let destination = panel.url {
                do {
                    try writeTranscript(stateToSave, to: destination, format: coordinator.selectedFormat)
                } catch {
                    appModel.showNotice("Save failed: \(error.localizedDescription)", style: .error)
                }
            }
        }
#endif
    }

    private func revealActiveSessionFolder() {
#if os(macOS)
        guard let directoryURL = appModel.activeSessionDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
#endif
    }

    private func copyTranscriptAsMarkdown() {
        guard appModel.transcriptState.hasDisplayText else { return }
        let markdown = TranscriptRenderer(transcript: appModel.transcriptState).markdown()
        copyStringToClipboard(markdown, successMessage: "Transcript copied to clipboard.")
    }

    private func copyInsightArtifactToClipboard() {
        guard let artifact = appModel.insightArtifact, artifact.hasContent else { return }
        copyStringToClipboard(artifact.content, successMessage: "Artifact copied to clipboard.")
    }

    private func copyStringToClipboard(_ string: String, successMessage: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        appModel.showNotice(successMessage, style: .success)
#endif
    }

    private func transcriptExportFormats(for transcript: TranscriptState) -> [TranscriptExportFormat] {
        var formats: [TranscriptExportFormat] = [.plainText, .json]
        if transcript.hasTimedSegments {
            formats.append(contentsOf: [.webVTT, .srt])
        }
        return formats
    }

    private func writeTranscript(_ transcript: TranscriptState, to destination: URL, format: TranscriptExportFormat) throws {
        let renderer = TranscriptRenderer(transcript: transcript)
        switch format {
        case .json:
            let data = try renderer.json()
            try data.write(to: destination)
        case .plainText:
            let data = transcript.plainTextExport.data(using: .utf8) ?? Data()
            try data.write(to: destination)
        case .webVTT:
            try renderer.captions(format: .webVTT).write(to: destination, atomically: true, encoding: .utf8)
        case .srt:
            try renderer.captions(format: .srt).write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private func saveInsightArtifact() {
        guard let artifact = appModel.insightArtifact, artifact.hasContent else { return }
#if os(macOS)
        let availableFormats = InsightArtifactExportFormat.allCases
        let panel = NSSavePanel()
        let coordinator = InsightArtifactSavePanelCoordinator(
            panel: panel,
            formats: availableFormats,
            artifact: artifact
        )
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Artifact"
        panel.prompt = "Save"
        panel.showsTagField = false
        panel.allowedContentTypes = availableFormats.map(\.contentType)
        panel.delegate = coordinator
        if #available(macOS 15.0, *) {
            panel.showsContentTypes = availableFormats.count > 1
            panel.currentContentType = availableFormats[0].contentType
        }
        panel.nameFieldStringValue = availableFormats[0].suggestedFilename(for: artifact)
        panel.begin { response in
            if response == .OK, let destination = panel.url {
                do {
                    try writeInsightArtifact(artifact, to: destination, format: coordinator.selectedFormat)
                } catch {
                    appModel.showNotice("Save failed: \(error.localizedDescription)", style: .error)
                }
            }
        }
#endif
    }

    private func writeInsightArtifact(
        _ artifact: InsightArtifact,
        to destination: URL,
        format: InsightArtifactExportFormat
    ) throws {
        switch format {
        case .plainText:
            try artifact.content.write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(artifact)
            try data.write(to: destination)
        }
    }

    private func importAudioFromFileSystem() {
        guard !appModel.isImportingAudio else { return }
        guard !appModel.isRecording else {
            appModel.showNotice("Stop recording before importing audio.", style: .warning)
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
        appModel.showNotice("File import is only supported on macOS.", style: .warning)
#endif
    }

    private func beginURLImport(from rawString: String) {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appModel.showNotice("Enter a valid audio URL.", style: .warning)
            return
        }
        guard let remoteURL = URL(string: trimmed),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            appModel.showNotice("Unsupported audio URL. Use http or https.", style: .warning)
            return
        }

        showURLImportSheet = false
        importURLString = ""
        Task { await appModel.importAudioFromRemoteURL(remoteURL) }
    }

    private func toggleRecording() {
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

    @Binding var sessionPendingDeletion: RecordingSessionSummary?

    @State private var sessionPendingRename: RecordingSessionSummary?
    @State private var sessionTitleDraft = ""

    let onToggleRecording: () -> Void
    let onImportAudio: () -> Void
    let onClearWorkspace: () -> Void

    private var selectedSessionID: Binding<UUID?> {
        Binding(
            get: { appModel.activeSession?.id },
            set: { newValue in
                guard let newValue else { return }
                appModel.selectSession(newValue)
            }
        )
    }

    private var renameSessionDialogBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingRename != nil },
            set: { newValue in
                if !newValue {
                    sessionPendingRename = nil
                }
            }
        )
    }

    var body: some View {
        List(selection: selectedSessionID) {
            Section {
                SidebarCaptureControls(
                    isRecording: appModel.isRecording,
                    isBusy: appModel.isBusy,
                    hasActiveSession: appModel.activeSession != nil,
                    hasProtectedActivity: appModel.hasProtectedActivity,
                    onToggleRecording: onToggleRecording,
                    onImportAudio: onImportAudio,
                    onClearWorkspace: onClearWorkspace
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
            } header: {
                Text("Capture")
            } footer: {
                Text("Recording and import actions create or update a recoverable session.")
            }

            Section {
                if appModel.recentSessionSummaries.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Yet",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Start a recording or import audio to create your first recoverable session.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(appModel.recentSessionSummaries) { session in
                        SessionSidebarRow(
                            session: session,
                            isLocked: !appModel.canSwitchSessions && appModel.activeSession?.id != session.id
                        )
                        .tag(Optional(session.id))
                        .contextMenu {
                            Button {
                                sessionTitleDraft = session.displayTitle
                                sessionPendingRename = session
                            } label: {
                                Label("Rename Session…", systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                sessionPendingDeletion = session
                            } label: {
                                Label("Delete Session", systemImage: "trash")
                            }
                            .disabled(appModel.hasProtectedActivity)
                        }
                        .disabled(!appModel.canSwitchSessions && appModel.activeSession?.id != session.id)
                    }
                }
            } header: {
                Text("Sessions")
            }
        }
        .listStyle(.sidebar)
        .alert(
            "Rename Session",
            isPresented: renameSessionDialogBinding,
            presenting: sessionPendingRename
        ) { session in
            TextField("Session title", text: $sessionTitleDraft)

            Button("Save") {
                if appModel.renameSession(session.id, to: sessionTitleDraft) {
                    sessionPendingRename = nil
                }
            }
            .keyboardShortcut(.defaultAction)

            Button("Cancel", role: .cancel) {
                sessionPendingRename = nil
            }
        } message: { session in
            Text("The original source remains available in Session Details. Current source: \(session.sourceDescription)")
        }
    }
}

private struct SidebarCaptureControls: View {
    let isRecording: Bool
    let isBusy: Bool
    let hasActiveSession: Bool
    let hasProtectedActivity: Bool
    let onToggleRecording: () -> Void
    let onImportAudio: () -> Void
    let onClearWorkspace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(isRecording ? "Stop Recording" : "Start Recording", action: onToggleRecording)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: [.command])

            Button("Import Audio…", action: onImportAudio)
                .buttonStyle(.bordered)
                .disabled(isBusy)

            if hasActiveSession {
                Button("Start Fresh", action: onClearWorkspace)
                    .buttonStyle(.bordered)
                    .disabled(hasProtectedActivity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionSidebarRow: View {
    let session: RecordingSessionSummary
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .help(session.displayTitle)

                Spacer(minLength: 8)

                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(session.stage.totalRecStatusLabel, systemImage: session.stage.totalRecStatusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.stage.totalRecStatusTint)

                if isLocked {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Label(artifactSummary, systemImage: artifactSystemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var artifactSummary: String {
        var artifacts: [String] = []
        if session.hasAudio { artifacts.append("Audio") }
        if session.hasTranscript { artifacts.append("Text") }
        if session.hasInsightArtifact { artifacts.append("Insights") }
        if session.lastError?.isEmpty == false { artifacts.append("Issue") }
        return artifacts.isEmpty ? "No artifacts" : artifacts.joined(separator: " · ")
    }

    private var artifactSystemImage: String {
        if session.lastError?.isEmpty == false { return "exclamationmark.triangle" }
        if session.hasInsightArtifact { return "list.bullet.rectangle" }
        if session.hasTranscript { return "text.quote" }
        if session.hasAudio { return "waveform" }
        return "circle.dashed"
    }
}

struct DeferredCommitTextField: View {
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

struct DeferredCommitSecureField: View {
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

    private var trimmedURLString: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import from URL")
                    .font(.title2.bold())
                Text("Paste a direct audio file URL to download it into a new recoverable session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Audio URL")
                    .font(.subheadline.weight(.semibold))

                TextField(
                    "",
                    text: $urlString,
                    prompt: Text("https://example.com/audio.m4a").foregroundStyle(.secondary)
                )
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .focused($isFieldFocused)
            }

            if isImporting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Downloading audio…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .totalRecStaticRoundedRect(cornerRadius: 12, tint: TotalRecGlass.captureBlue)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .totalRecGlassButton()

                Button("Import") {
                    onImport(urlString)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedURLString.isEmpty || isImporting)
                .totalRecGlassButton(prominent: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            TotalRecAmbientBackground(
                accent: TotalRecGlass.captureBlue,
                secondaryAccent: TotalRecGlass.transcriptViolet
            )
        )
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

private final class TranscriptSavePanelCoordinator: NSObject, NSOpenSavePanelDelegate {
    private let panel: NSSavePanel
    private let formats: [ContentView.TranscriptExportFormat]
    private let hasSpeakerLabels: Bool

    private(set) var selectedFormat: ContentView.TranscriptExportFormat

    init(
        panel: NSSavePanel,
        formats: [ContentView.TranscriptExportFormat],
        hasSpeakerLabels: Bool
    ) {
        precondition(!formats.isEmpty, "Transcript save panel requires at least one export format.")

        self.panel = panel
        self.formats = formats
        self.hasSpeakerLabels = hasSpeakerLabels
        self.selectedFormat = formats[0]

        super.init()
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, displayNameFor type: UTType) -> String? {
        format(for: type)?.displayName
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, didSelect type: UTType?) {
        guard let format = format(for: type) else { return }
        selectedFormat = format
        panel.nameFieldStringValue = suggestedFilename(for: format, preserveCurrentBaseName: true)
    }

    private func format(for contentType: UTType?) -> ContentView.TranscriptExportFormat? {
        guard let contentType else { return nil }
        return formats.first(where: { $0.contentType == contentType })
    }

    private func suggestedFilename(
        for format: ContentView.TranscriptExportFormat,
        preserveCurrentBaseName: Bool
    ) -> String {
        guard preserveCurrentBaseName else {
            return format.suggestedFilename(hasSpeakerLabels: hasSpeakerLabels)
        }

        let currentName = panel.nameFieldStringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentName.isEmpty else {
            return format.suggestedFilename(hasSpeakerLabels: hasSpeakerLabels)
        }

        let baseName = URL(fileURLWithPath: currentName).deletingPathExtension().lastPathComponent
        guard !baseName.isEmpty else {
            return format.suggestedFilename(hasSpeakerLabels: hasSpeakerLabels)
        }
        return "\(baseName).\(format.preferredPathExtension)"
    }
}

private final class InsightArtifactSavePanelCoordinator: NSObject, NSOpenSavePanelDelegate {
    private let panel: NSSavePanel
    private let formats: [ContentView.InsightArtifactExportFormat]
    private let artifact: InsightArtifact

    private(set) var selectedFormat: ContentView.InsightArtifactExportFormat

    init(
        panel: NSSavePanel,
        formats: [ContentView.InsightArtifactExportFormat],
        artifact: InsightArtifact
    ) {
        precondition(!formats.isEmpty, "Insight artifact save panel requires at least one export format.")

        self.panel = panel
        self.formats = formats
        self.artifact = artifact
        self.selectedFormat = formats[0]

        super.init()
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, displayNameFor type: UTType) -> String? {
        format(for: type)?.displayName
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, didSelect type: UTType?) {
        guard let format = format(for: type) else { return }
        selectedFormat = format
        panel.nameFieldStringValue = suggestedFilename(for: format, preserveCurrentBaseName: true)
    }

    private func format(for contentType: UTType?) -> ContentView.InsightArtifactExportFormat? {
        guard let contentType else { return nil }
        return formats.first(where: { $0.contentType == contentType })
    }

    private func suggestedFilename(
        for format: ContentView.InsightArtifactExportFormat,
        preserveCurrentBaseName: Bool
    ) -> String {
        guard preserveCurrentBaseName else {
            return format.suggestedFilename(for: artifact)
        }

        let currentName = panel.nameFieldStringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentName.isEmpty else {
            return format.suggestedFilename(for: artifact)
        }

        let baseName = URL(fileURLWithPath: currentName).deletingPathExtension().lastPathComponent
        guard !baseName.isEmpty else {
            return format.suggestedFilename(for: artifact)
        }
        return "\(baseName).\(format.preferredPathExtension)"
    }
}
#endif
