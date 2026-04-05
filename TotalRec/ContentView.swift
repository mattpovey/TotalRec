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

    @State private var showStartFreshRecordingPrompt = false
    @State private var showImportOptionsDialog = false
    @State private var showURLImportSheet = false
    @State private var importURLString = ""
    @State private var knownSpeakerNamesInputs = Array(repeating: "", count: 4)
    @State private var knownSpeakerRefsInputs = Array(repeating: "", count: 4)
    @State private var showSettingsSheet = false
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
    @State private var loadedTranscriptSteps: Set<TranscriptWorkspaceStep> = [.run]
    @State private var customInsightsPrompt = InsightWorkflow.meetingNotes.promptTemplate
    @State private var selectedInsightWorkflow = InsightWorkflow.meetingNotes
    @State private var useCustomInsightsPrompt = false
    @State private var isKnownSpeakerHintsExpanded = false
    @State private var isTScriptAdvancedOptionsExpanded = false
    @State private var isSessionDiagnosticsExpanded = false
    @State private var sessionPendingDeletion: RecordingSession?
    @State private var pendingTranscriptNavigationAfterTranscription = false

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
            ReadinessItem(
                title: appModel.audioURL == nil ? "Session audio pending" : "Session audio ready",
                detail: appModel.isRecording
                    ? "Recording is active. Stop when you want to prepare the session audio for transcription."
                    : (appModel.audioURL == nil
                        ? "Start a protected recording or import audio into this session."
                        : "Audio has been prepared\(formattedDurationSuffix) and is ready for transcription."),
                systemImage: appModel.isRecording ? "record.circle.fill" : (appModel.audioURL == nil ? "waveform.badge.plus" : "checkmark.circle.fill"),
                tint: appModel.isRecording ? TotalRecGlass.recordingRed : (appModel.audioURL == nil ? TotalRecGlass.captureBlue : TotalRecGlass.successGreen)
            ),
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
            .background(
                TotalRecAmbientBackground(
                    accent: ambientAccentTint,
                    secondaryAccent: ambientSecondaryTint
                )
            )
            .onAppear {
                normalizeSelectedTranscriptStep(preferred: defaultTranscriptStep)
                loadedTranscriptSteps.insert(selectedTranscriptStep)
                syncInsightEditorState(from: appModel.activeSession?.insightSettings)
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
            }
            .onChange(of: selectedSection) { _, newSection in
                if newSection == .transcript {
                    normalizeSelectedTranscriptStep()
                }
            }
            .onChange(of: selectedTranscriptStep) { _, newStep in
                loadedTranscriptSteps.insert(newStep)
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
                    appModel.setStatusMessage("Failed to save default provider: \(error.localizedDescription)")
                }
            }
            .onChange(of: nameSuggestionProvider) { _, newProvider in
                do {
                    try AIConfigManager.shared.setNameSuggestionProvider(newProvider.rawValue)
                    nameSuggestionModelID = AIConfigManager.shared.configuration.nameSuggestionModelID
                } catch {
                    appModel.setStatusMessage("Failed to save name suggestion provider: \(error.localizedDescription)")
                }
            }
            .onChange(of: defaultInsightWorkflow) { _, newWorkflow in
                do {
                    try AIConfigManager.shared.setDefaultInsightWorkflow(newWorkflow)
                } catch {
                    appModel.setStatusMessage("Failed to save default insight workflow: \(error.localizedDescription)")
                }
            }
            .onChange(of: defaultInsightProvider) { _, newProvider in
                do {
                    try AIConfigManager.shared.setDefaultInsightProvider(newProvider)
                    defaultInsightModelID = AIConfigManager.shared.configuration.defaultInsightModelID
                } catch {
                    appModel.setStatusMessage("Failed to save default insight provider: \(error.localizedDescription)")
                }
            }
            .onChange(of: defaultInsightModelID) { _, newModelID in
                do {
                    try AIConfigManager.shared.setDefaultInsightModelID(newModelID)
                } catch {
                    appModel.setStatusMessage("Failed to save default insight model: \(error.localizedDescription)")
                }
            }
            .onChange(of: nameSuggestionModelID) { _, newModelID in
                do {
                    try AIConfigManager.shared.setNameSuggestionModelID(newModelID)
                } catch {
                    appModel.setStatusMessage("Failed to save name suggestion model: \(error.localizedDescription)")
                }
            }
            .onChange(of: openAIAPIKey) { _, newKey in
                do {
                    try AIConfigManager.shared.updateOpenAIKey(newKey.isEmpty ? nil : newKey)
                } catch {
                    appModel.setStatusMessage("Failed to save OpenAI key: \(error.localizedDescription)")
                }
            }
            .onChange(of: sambaNovaAPIKey) { _, newKey in
                do {
                    try AIConfigManager.shared.updateSambaNovaKey(newKey.isEmpty ? nil : newKey)
                } catch {
                    appModel.setStatusMessage("Failed to save SambaNova key: \(error.localizedDescription)")
                }
            }
            .onChange(of: sambaNovaBaseURL) { oldValue, newValue in
                do {
                    try AIConfigManager.shared.setBaseURL(newValue, for: .sambaNova)
                    if oldValue.trimmingCharacters(in: .whitespacesAndNewlines) != newValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                        sambaNovaModels = []
                        sambaNovaModelsUpdatedAt = nil
                        sambaNovaModelsError = nil
                        try AIConfigManager.shared.updateCachedModels([], for: .sambaNova)
                        nameSuggestionModelID = AIConfigManager.shared.configuration.nameSuggestionModelID
                        defaultInsightModelID = AIConfigManager.shared.configuration.defaultInsightModelID
                    }
                } catch {
                    appModel.setStatusMessage("Failed to save SambaNova base URL: \(error.localizedDescription)")
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
                    defaultInsightWorkflow: $defaultInsightWorkflow,
                    defaultInsightProvider: $defaultInsightProvider,
                    defaultInsightModelID: $defaultInsightModelID,
                    nameSuggestionModelID: $nameSuggestionModelID,
                    openAIAPIKey: $openAIAPIKey,
                    sambaNovaAPIKey: $sambaNovaAPIKey,
                    sambaNovaBaseURL: $sambaNovaBaseURL,
                    openAIModels: openAIModels,
                    sambaNovaModels: sambaNovaModels,
                    openAIModelsUpdatedAt: openAIModelsUpdatedAt,
                    sambaNovaModelsUpdatedAt: sambaNovaModelsUpdatedAt,
                    isOpenAIModelsLoading: isOpenAIModelsLoading,
                    isSambaNovaModelsLoading: isSambaNovaModelsLoading,
                    openAIModelsError: openAIModelsError,
                    sambaNovaModelsError: sambaNovaModelsError,
                    tScriptConfiguration: $tScriptConfiguration,
                    onRefreshModels: refreshLLMModels(for:),
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
            workspaceNavigation
            if let currentLiveActivityStage {
                activityBanner(for: currentLiveActivityStage)
            }
            currentSectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        tint: TotalRecGlass.recordingRed
                    )
                }
            }

            providerStatusBadge

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
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecGlassPanel(cornerRadius: 20)
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

    private var headerSubtitle: String {
        if let activeSession = appModel.activeSession {
            return activeSession.sourceDescription
        }
        return "Ready for a new session"
    }

    private var providerStatusBadge: some View {
        ViewThatFits(in: .horizontal) {
            TotalRecGlassCluster(spacing: 14) {
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
                            tint: isOpenAIKeyConfigured ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
                        )
                    } else if provider == .tscript {
                        detailBadge(
                            selectedTScriptModel?.displayName ?? "Model registry pending",
                            systemImage: selectedTScriptModel == nil ? "server.rack" : "square.stack.3d.up.fill",
                            tint: selectedTScriptModel == nil ? TotalRecGlass.neutralTint : TotalRecGlass.successGreen
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
            }

            VStack(alignment: .leading, spacing: 8) {
                detailBadge(
                    provider.rawValue,
                    systemImage: providerSystemImage,
                    tint: workflowSectionTint(selectedSection)
                )

                TotalRecGlassCluster(spacing: 14) {
                    HStack(spacing: 10) {
                        if provider == .openAI {
                            detailBadge(
                                isOpenAIKeyConfigured ? "API key configured" : "API key missing",
                                systemImage: isOpenAIKeyConfigured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                                tint: isOpenAIKeyConfigured ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
                            )
                        } else if provider == .tscript {
                            detailBadge(
                                selectedTScriptModel?.displayName ?? "Model registry pending",
                                systemImage: selectedTScriptModel == nil ? "server.rack" : "square.stack.3d.up.fill",
                                tint: selectedTScriptModel == nil ? TotalRecGlass.neutralTint : TotalRecGlass.successGreen
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

    private var workspaceNavigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionNavigation

            if selectedSection == .transcript, availableTranscriptSteps.count > 1 {
                transcriptStepNavigation
            }
        }
    }

    private var sectionNavigation: some View {
        ViewThatFits(in: .horizontal) {
            compactSectionNavigation(vertical: false)
            compactSectionNavigation(vertical: true)
        }
        .padding(4)
        .totalRecStaticPanel(cornerRadius: 18, tint: ambientAccentTint)
    }

    private var transcriptStepNavigation: some View {
        ViewThatFits(in: .horizontal) {
            compactTranscriptStepNavigation(vertical: false)
            compactTranscriptStepNavigation(vertical: true)
        }
        .padding(4)
        .totalRecStaticPanel(cornerRadius: 18, tint: workflowSectionTint(.transcript))
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

    private func compactTranscriptStepNavigation(vertical: Bool) -> some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            ForEach(availableTranscriptSteps) { step in
                transcriptStepNavigationButton(for: step)
            }
        }
    }

    private func sectionNavigationButton(for section: WorkflowSection) -> some View {
        let isSelected = selectedSection == section
        let tint = workflowSectionTint(section)

        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: workflowSectionIcon(section))
                    .imageScale(.medium)
                    .foregroundStyle(isSelected ? TotalRecGlass.accentForeground(tint) : .secondary)
                Text(section.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .totalRecStaticRoundedRect(
                cornerRadius: 14,
                tint: isSelected ? tint : nil
            )
        }
        .buttonStyle(.plain)
    }

    private func transcriptStepNavigationButton(for step: TranscriptWorkspaceStep) -> some View {
        let isSelected = selectedTranscriptStep == step
        let tint = workflowSectionTint(.transcript)

        return Button {
            selectedTranscriptStep = step
        } label: {
            HStack(spacing: 8) {
                Image(systemName: transcriptStepIcon(step))
                    .imageScale(.medium)
                    .foregroundStyle(isSelected ? TotalRecGlass.accentForeground(tint) : .secondary)
                Text(step.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .totalRecStaticRoundedRect(
                cornerRadius: 14,
                tint: isSelected ? tint : nil
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
        .totalRecStaticRoundedRect(cornerRadius: 14, tint: item.tint)
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
                        tint: TotalRecGlass.warningAmber
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
        detail: String? = nil,
        detailSystemImage: String = "sparkles",
        detailTint: Color? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TotalRecGlass.accentForeground(tint))
                    .frame(width: 40, height: 40)
                    .totalRecStaticRoundedRect(cornerRadius: 14, tint: tint)
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
                detailBadge(detail, systemImage: detailSystemImage, tint: detailTint ?? tint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticPanel(cornerRadius: 18, tint: tint)
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
                        tint: TotalRecGlass.captureBlue
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Latest Transcript Preview")
                            .font(.headline)
                        Text("Use the main workflow navigation to continue transcript review without losing the current capture context.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

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
                pageCard {
                    Text("What Happens Next")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Capture or import audio into a dedicated session.", systemImage: "1.circle.fill")
                        Label("Run transcription when the audio is ready.", systemImage: "2.circle.fill")
                        Label("Correct transcript text, then clean speakers and generate notes.", systemImage: "3.circle.fill")
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
            Button(action: saveAudio) {
                Label("Save Audio…", systemImage: "square.and.arrow.down")
            }
                .totalRecGlassButton()
                .disabled(appModel.audioURL == nil)

            Button {
                copyTranscriptAsMarkdown()
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .totalRecGlassButton()
            .disabled(!appModel.transcriptState.hasDisplayText)

            Button(action: saveTranscript) {
                Label("Save Transcript…", systemImage: "square.and.arrow.down")
            }
                .totalRecGlassButton()
                .disabled(appModel.transcriptState.isEmpty)
        }
    }

    private var transcriptSection: some View {
        sectionScrollContainer {
            transcriptSectionOverview
            transcriptStepContent
        }
    }

    private var transcriptSectionOverview: some View {
        workspaceHero(
            title: "Transcript workspace",
            description: transcriptStepDescription(for: selectedTranscriptStep),
            systemImage: "text.quote",
            tint: workflowSectionTint(.transcript),
            detail: hasTranscriptDisplayText
                ? "\(appModel.transcriptState.orderedSpeakerLabels.count) speakers"
                : (appModel.audioURL == nil ? nil : "Audio ready\(formattedDurationSuffix)")
        )
    }

    @ViewBuilder
    private var transcriptStepContent: some View {
        ZStack(alignment: .topLeading) {
            ForEach(TranscriptWorkspaceStep.allCases) { step in
                if loadedTranscriptSteps.contains(step) {
                    transcriptStepView(for: step)
                        .opacity(selectedTranscriptStep == step ? 1 : 0)
                        .allowsHitTesting(selectedTranscriptStep == step)
                        .accessibilityHidden(selectedTranscriptStep != step)
                        .zIndex(selectedTranscriptStep == step ? 1 : 0)
                }
            }
        }
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
            transcriptionSetupCard
            readinessCard(
                title: "Transcription readiness",
                subtitle: "Verify provider requirements, audio availability, and hint quality before you run or re-run transcription.",
                items: transcriptionReadinessItems
            )
            transcriptRunActionCard
            sessionDiagnosticsCard
        }
    }

    private var transcriptRunActionCard: some View {
        pageCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(hasTranscriptDisplayText ? "Re-run transcription" : "Run transcription")
                    .font(.headline)

                Text(
                    appModel.audioURL == nil
                        ? "Record or import audio from the Capture page, then run transcription."
                        : "This step owns provider selection and execution. Successful runs open Transcript for wording cleanup before speaker review and export."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

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
                    statusBanner(
                        "A new transcription run replaces the current transcript result for this session.",
                        systemImage: "arrow.clockwise.circle",
                        tint: TotalRecGlass.captureBlue
                    )
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
                        appModel.setStatusMessage(message)
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
                        showSettingsSheet = true
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
                        showSettingsSheet = true
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
                title: appModel.insightArtifact == nil ? "Generate transcript artifacts" : "Insights and artifacts",
                description: "Turn the transcript into reusable summaries, decision logs, action lists, and other workflow-specific outputs.",
                systemImage: "list.bullet.rectangle.portrait",
                tint: workflowSectionTint(.insights),
                detail: hasTranscriptDisplayText ? "Transcript ready" : "Transcript required",
                detailSystemImage: hasTranscriptDisplayText ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                detailTint: hasTranscriptDisplayText ? TotalRecGlass.successGreen : TotalRecGlass.warningAmber
            )

            readinessCard(
                title: "Insights readiness",
                subtitle: "Check transcript access, provider availability, and workflow state before generating an artifact.",
                items: insightsReadinessItems
            )

            pageCard {
                insightsPanel

                HStack(spacing: 8) {
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
        }
    }

    private var insightsPanel: some View {
            VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insight Workflow")
                        .font(.headline)
                    Text("Generate a transcript-derived artifact for the current audio session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                    Button {
                        runInsightsGeneration()
                    } label: {
                        Text("Generate Artifact")
                    }
                    .disabled(isInsightActionDisabled)
                    .totalRecGlassButton(prominent: true)
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
                        Text("Use the selected workflow template as the default, or switch this on to fully control the LLM instructions. Keep the {{TRANSCRIPT}} token where the diarized text should be inserted.")
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
                            ? "The new artifact is streaming in now. The saved artifact remains unchanged until this run completes."
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
                    .background(Color.gray.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            appModel.setStatusMessage("Insight generation failed: Custom prompt required.")
            return
        }

        if !isAPIKeyConfigured(for: defaultInsightProvider) {
            appModel.insightRunError = "\(defaultInsightProvider.displayName) API key missing."
            appModel.setStatusMessage("Insight generation failed: \(defaultInsightProvider.displayName) API key missing.")
            showSettingsSheet = true
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
            appModel.setStatusMessage("Failed to save TScript settings: \(error.localizedDescription)")
        }

        let oldBaseURL = oldValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBaseURL = newValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldBaseURL != newBaseURL {
            tScriptModelsResponse = nil
            tScriptModelsError = nil
        }
    }

    private func refreshLLMModels(for provider: LLMProvider) {
        switch provider {
        case .openAI:
            guard isOpenAIKeyConfigured else {
                openAIModelsError = "Add an OpenAI API key in Settings before loading models."
                return
            }
            guard !isOpenAIModelsLoading else { return }
            isOpenAIModelsLoading = true
            openAIModelsError = nil
        case .sambaNova:
            guard isSambaNovaKeyConfigured else {
                sambaNovaModelsError = "Add a SambaNova API key in Settings before loading models."
                return
            }
            guard !isSambaNovaModelsLoading else { return }
            isSambaNovaModelsLoading = true
            sambaNovaModelsError = nil
        }

        Task {
            do {
                let models = try await llmModelCatalogService.fetchModels(for: provider)
                try AIConfigManager.shared.updateCachedModels(models, for: provider)
                let config = AIConfigManager.shared.configuration

                await MainActor.run {
                    switch provider {
                    case .openAI:
                        isOpenAIModelsLoading = false
                        openAIModels = config.openAI.cachedModels
                        openAIModelsUpdatedAt = config.openAI.modelsUpdatedAt
                        openAIModelsError = nil
                    case .sambaNova:
                        isSambaNovaModelsLoading = false
                        sambaNovaModels = config.sambaNova.cachedModels
                        sambaNovaModelsUpdatedAt = config.sambaNova.modelsUpdatedAt
                        sambaNovaModelsError = nil
                    }

                    defaultInsightModelID = config.defaultInsightModelID
                    nameSuggestionModelID = config.nameSuggestionModelID
                }
            } catch {
                await MainActor.run {
                    switch provider {
                    case .openAI:
                        isOpenAIModelsLoading = false
                        openAIModelsError = error.localizedDescription
                    case .sambaNova:
                        isSambaNovaModelsLoading = false
                        sambaNovaModelsError = error.localizedDescription
                    }
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
                    appModel.setStatusMessage("Save failed: \(error.localizedDescription)")
                }
            }
        }
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
        appModel.setStatusMessage(successMessage)
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
                    appModel.setStatusMessage("Save failed: \(error.localizedDescription)")
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
        appModel.isRecording ? TotalRecGlass.recordingRed : TotalRecGlass.captureBlue
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
                .totalRecGlassButton()
                .disabled(appModel.activeSession == nil || appModel.hasProtectedActivity)

                Text("\(appModel.recentSessionSummaries.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .totalRecGlassPill()
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
                .totalRecGlassPanel(cornerRadius: 18, tint: captureTint)
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
        .totalRecGlassPanel(cornerRadius: 22)
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
        .totalRecGlassRoundedRect(cornerRadius: 16, tint: captureTint)
        .opacity(selectedSection == .capture ? 1.0 : 0.68)
    }

    private var sessionCaptureButtons: some View {
        Group {
            Button(appModel.isRecording ? "Stop Recording" : "Start Recording", action: onToggleRecording)
                .totalRecGlassButton(prominent: true)
                .keyboardShortcut(.space, modifiers: [])

            Button("Import Audio…", action: onImportAudio)
                .totalRecGlassButton()
                .disabled(appModel.isBusy)

            if appModel.activeSession != nil {
                Button("Clear Workspace", action: onClearWorkspace)
                    .totalRecGlassButton()
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
                        .totalRecStaticPill(tint: .accentColor)
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
                if session.hasInsightArtifact {
                    sessionMetaPill("Insights", systemImage: "list.bullet.rectangle")
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
        .totalRecStaticRoundedRect(cornerRadius: 12, tint: isActive ? .accentColor : nil)
        .opacity(isLocked ? 0.6 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sessionMetaPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .totalRecStaticPill()
    }

    private func stageTitle(_ stage: SessionStage) -> String {
        stage.totalRecStatusLabel
    }

    private func stageIcon(_ stage: SessionStage) -> String {
        stage.totalRecStatusIcon
    }

    private func stageTint(_ stage: SessionStage) -> Color {
        stage.totalRecStatusTint
    }
}

private struct SettingsSheetView: View {
    private static let contentColumnWidth: CGFloat = 700
    private static let apiKeyFieldWidth: CGFloat = 420

    @Binding var nameSuggestionProvider: NameSuggestionProvider
    @Binding var defaultInsightWorkflow: InsightWorkflow
    @Binding var defaultInsightProvider: LLMProvider
    @Binding var defaultInsightModelID: String
    @Binding var nameSuggestionModelID: String
    @Binding var openAIAPIKey: String
    @Binding var sambaNovaAPIKey: String
    @Binding var sambaNovaBaseURL: String
    let openAIModels: [ProviderModelDescriptor]
    let sambaNovaModels: [ProviderModelDescriptor]
    let openAIModelsUpdatedAt: Date?
    let sambaNovaModelsUpdatedAt: Date?
    let isOpenAIModelsLoading: Bool
    let isSambaNovaModelsLoading: Bool
    let openAIModelsError: String?
    let sambaNovaModelsError: String?
    @Binding var tScriptConfiguration: TScriptConfiguration
    var onRefreshModels: (LLMProvider) -> Void
    var onClose: () -> Void

    private var hasOpenAIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSambaNovaKey: Bool {
        !sambaNovaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func providerModels(for provider: LLMProvider) -> [ProviderModelDescriptor] {
        switch provider {
        case .openAI:
            return openAIModels
        case .sambaNova:
            return sambaNovaModels
        }
    }

    private func effectiveModelChoices(
        for provider: LLMProvider,
        feature: LLMFeature,
        selectedID: String
    ) -> [ProviderModelDescriptor] {
        let filtered = providerModels(for: provider).filter { $0.supports(feature: feature) }
        let trimmed = selectedID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if !filtered.isEmpty {
                return filtered
            }
            return [
                ProviderModelDescriptor(
                    id: provider.defaultModelID(for: feature),
                    displayName: provider.defaultModelID(for: feature),
                    provider: provider,
                    contextWindow: nil,
                    supportsStreaming: true,
                    supportsJSONMode: true,
                    lifecycle: .unknown
                )
            ]
        }

        if filtered.contains(where: { $0.id == trimmed }) {
            return filtered
        }

        return filtered + [
            ProviderModelDescriptor(
                id: trimmed,
                displayName: trimmed,
                provider: provider,
                contextWindow: nil,
                supportsStreaming: true,
                supportsJSONMode: true,
                lifecycle: .unknown
            )
        ]
    }

    private func modelRefreshStatus(for provider: LLMProvider) -> String {
        let updatedAt: Date?
        let models: [ProviderModelDescriptor]
        switch provider {
        case .openAI:
            updatedAt = openAIModelsUpdatedAt
            models = openAIModels
        case .sambaNova:
            updatedAt = sambaNovaModelsUpdatedAt
            models = sambaNovaModels
        }

        if let updatedAt {
            return "Loaded \(models.count) models on \(updatedAt.formatted(date: .abbreviated, time: .shortened))."
        }
        return models.isEmpty ? "No models cached yet." : "Loaded \(models.count) models."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader
                textGenerationProvidersSection
                insightDefaultsSection
                if BuildFeatures.nameSuggestionsEnabled {
                    nameSuggestionsSection
                }
                tScriptServerSection
            }
            .frame(maxWidth: Self.contentColumnWidth, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
        .background(
            TotalRecAmbientBackground(
                accent: TotalRecGlass.transcriptViolet,
                secondaryAccent: TotalRecGlass.captureBlue
            )
        )
    }

    private var settingsHeader: some View {
        HStack(alignment: .center) {
            Text("Settings")
                .font(.title2.bold())
            Spacer()
            Button("Done") { onClose() }
                .totalRecGlassButton(prominent: true)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
    }

    private var textGenerationProvidersSection: some View {
        settingsSectionCard(
            title: "Text Generation Providers",
            subtitle: "Store provider credentials, refresh `/models`, and choose defaults for Insights and speaker name suggestions."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                providerCredentialCard(
                    provider: .openAI,
                    subtitle: hasOpenAIKey
                        ? "Stored in Keychain and used for OpenAI transcription, Insights, and compatible chat-completions workflows."
                        : "OpenAI features stay unavailable until you add a key.",
                    apiKey: $openAIAPIKey,
                    hasKey: hasOpenAIKey,
                    baseURLBinding: nil,
                    models: openAIModels,
                    isLoading: isOpenAIModelsLoading,
                    refreshError: openAIModelsError
                )

                providerCredentialCard(
                    provider: .sambaNova,
                    subtitle: hasSambaNovaKey
                        ? "Stored in Keychain and used for SambaNova chat-completions features."
                        : "Add a SambaNova key to enable provider-backed Insights and name suggestions.",
                    apiKey: $sambaNovaAPIKey,
                    hasKey: hasSambaNovaKey,
                    baseURLBinding: $sambaNovaBaseURL,
                    models: sambaNovaModels,
                    isLoading: isSambaNovaModelsLoading,
                    refreshError: sambaNovaModelsError
                )
            }
        }
    }

    private var insightDefaultsSection: some View {
        settingsSectionCard(
            title: "Insights",
            subtitle: "Choose the default workflow and provider/model pair used for transcript-derived artifacts."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Default Insight Workflow", selection: $defaultInsightWorkflow) {
                    ForEach(InsightWorkflow.allCases) { workflow in
                        Text(workflow.displayName).tag(workflow)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)

                Text(defaultInsightWorkflow.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Insights Provider", selection: $defaultInsightProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Insights Model", selection: $defaultInsightModelID) {
                    ForEach(effectiveModelChoices(for: defaultInsightProvider, feature: .insights, selectedID: defaultInsightModelID)) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)

                Text("New sessions start from the \(defaultInsightWorkflow.displayName.lowercased()) workflow and use \(defaultInsightProvider.displayName) with the selected model by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nameSuggestionsSection: some View {
        settingsSectionCard(
            title: "Name Suggestions",
            subtitle: "Choose how speaker names are suggested for diarized transcripts."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Name Suggestions Provider", selection: $nameSuggestionProvider) {
                    ForEach(NameSuggestionProvider.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420, alignment: .leading)

                if let llmProvider = nameSuggestionProvider.llmProvider {
                    Picker("Name Suggestion Model", selection: $nameSuggestionModelID) {
                        ForEach(effectiveModelChoices(for: llmProvider, feature: .nameSuggestions, selectedID: nameSuggestionModelID)) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360, alignment: .leading)

                    Text("Speaker cleanup will use \(llmProvider.displayName) with the selected model when AI suggestions are enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Speaker name suggestions are disabled. The cleanup view will stay manual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
                        .foregroundStyle(hasTScriptBaseURL ? TotalRecGlass.accentForeground(TotalRecGlass.successGreen) : .secondary)

                    DeferredCommitTextField("https://transcribe-api.localhost:1355", text: $tScriptConfiguration.baseURL)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .totalRecReadableInset(cornerRadius: 12)

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
                            .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))

                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .totalRecGlassRoundedRect(cornerRadius: 12, tint: TotalRecGlass.warningAmber)
                }
            }
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
        .totalRecStaticPanel(cornerRadius: 18)
    }

    @ViewBuilder
    private func providerCredentialCard(
        provider: LLMProvider,
        subtitle: String,
        apiKey: Binding<String>,
        hasKey: Bool,
        baseURLBinding: Binding<String>?,
        models: [ProviderModelDescriptor],
        isLoading: Bool,
        refreshError: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    providerAPIKeyField(apiKey: apiKey, hasKey: hasKey)
                        .frame(maxWidth: Self.apiKeyFieldWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    providerStatusBlock(provider: provider, hasKey: hasKey, models: models, isLoading: isLoading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    providerAPIKeyField(apiKey: apiKey, hasKey: hasKey)
                    providerStatusBlock(provider: provider, hasKey: hasKey, models: models, isLoading: isLoading)
                }
            }

            if let baseURLBinding {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)

                    DeferredCommitTextField(provider.defaultBaseURL, text: baseURLBinding)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .totalRecReadableInset(cornerRadius: 12)

                Text("Base URL defaults to \(provider.defaultBaseURL). Change it only if SambaNova gives you a different endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(isLoading ? "Refreshing…" : "Refresh Models") {
                    onRefreshModels(provider)
                }
                .disabled(isLoading || !hasKey)
                .totalRecGlassButton()
                .controlSize(.small)

                Text(modelRefreshStatus(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let refreshError, !refreshError.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))

                    Text(refreshError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .totalRecGlassRoundedRect(cornerRadius: 12, tint: TotalRecGlass.warningAmber)
            }
        }
        .padding(14)
        .totalRecReadableInset(cornerRadius: 16)
    }

    private func providerAPIKeyField(apiKey: Binding<String>, hasKey: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hasKey ? "key.fill" : "key")
                .foregroundStyle(hasKey ? TotalRecGlass.accentForeground(TotalRecGlass.successGreen) : .secondary)

            DeferredCommitSecureField("sk-...", text: apiKey)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .totalRecReadableInset(cornerRadius: 12)
    }

    private func providerStatusBlock(
        provider: LLMProvider,
        hasKey: Bool,
        models: [ProviderModelDescriptor],
        isLoading: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                hasKey ? "Key saved" : "No key saved",
                systemImage: hasKey ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(hasKey ? TotalRecGlass.accentForeground(TotalRecGlass.successGreen) : .secondary)

            Text(isLoading ? "Refreshing model catalog…" : "\(models.count) models cached")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasKey {
                Button("Clear Key") {
                    switch provider {
                    case .openAI:
                        openAIAPIKey = ""
                    case .sambaNova:
                        sambaNovaAPIKey = ""
                    }
                }
                .font(.caption.weight(.semibold))
                .totalRecGlassButton()
                .controlSize(.small)
            }
        }
        .frame(minWidth: 120, alignment: .leading)
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
