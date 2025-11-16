import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct ContentView: View {
    @State private var isRecording = false
    @State private var permissionAlert = false
    @State private var tempMOVURL: URL?
    @State private var mixedM4AURL: URL?
    @State private var mixedAudioDuration: TimeInterval?
    @State private var transcript: String = ""
    @State private var transcriptState = TranscriptState()
    @State private var status: String = "Idle"
    @State private var systemGain: Float = 1.0
    @State private var micGain: Float = 1.0
    @State private var isTranscribing = false
    @State private var lastTranscriptCount: Int = 0
    @State private var showSaveBeforeRecordingPrompt = false
    @State private var knownSpeakerNamesInputs: [String] = Array(repeating: "", count: 4)
    @State private var knownSpeakerRefsInputs: [String] = Array(repeating: "", count: 4)
    @State private var showSettingsSheet: Bool = false
    @State private var showTranscriptFormatDialog: Bool = false
    @State private var showImportOptionsDialog: Bool = false
    @State private var showURLImportSheet: Bool = false
    @State private var importURLString: String = ""
    @State private var isImportingAudio: Bool = false

    private var hasPartialKnownSpeaker: Bool {
        let count = min(knownSpeakerNamesInputs.count, knownSpeakerRefsInputs.count)
        for i in 0..<count {
            let name = knownSpeakerNamesInputs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = knownSpeakerRefsInputs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if (name.isEmpty && !ref.isEmpty) || (!name.isEmpty && ref.isEmpty) { return true }
        }
        return false
    }

    private var preparedKnownSpeakers: [OpenAITranscriber.KnownSpeaker] {
        var list: [OpenAITranscriber.KnownSpeaker] = []
        let count = min(4, min(knownSpeakerNamesInputs.count, knownSpeakerRefsInputs.count))
        for i in 0..<count {
            let name = knownSpeakerNamesInputs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = knownSpeakerRefsInputs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !ref.isEmpty {
                list.append(OpenAITranscriber.KnownSpeaker(name: name, reference: ref))
            }
        }
        return list
    }

    enum TranscriptionProvider: String, CaseIterable, Identifiable {
        case appleOnDevice = "Apple (On-Device)"
        case appleCloud = "Apple (Cloud)"
        case openAI = "OpenAI (Diarized)"
        var id: String { rawValue }
    }

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
            case .plainText: return "Plain Text (.txt)"
            case .json: return "JSON (.json)"
            case .webVTT: return "WebVTT Caption (.vtt)"
            case .srt: return "SubRip Caption (.srt)"
            }
        }

        var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .json: return "json"
            case .webVTT: return "vtt"
            case .srt: return "srt"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText: return .plainText
            case .json: return .json
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

    @State private var openAIAPIKey: String = ""
    @AppStorage("openAIChunkingStrategy") private var openAIChunkingStrategy: String = "auto" // "auto" or "none"
    @State private var provider: TranscriptionProvider = .appleCloud
    @State private var nameSuggestionProvider: NameSuggestionProvider = .openAI
    @State private var selectedSection: WorkflowSection = .capture

    private let recorder = SystemAudioRecorder()
    private let transcriber = FileTranscriber()
    private let nameSuggestionService = NameSuggestionService()

    @State private var nameSuggestionRequestSignal = 0
    @State private var isNameSuggestionRequestInFlight = false
    @State private var meetingNotes: String = ""
    @State private var isGeneratingMeetingNotes = false
    @State private var meetingNotesError: String?
    @State private var customInsightsPrompt: String = MeetingNotesService.defaultPrompt
    @State private var useCustomInsightsPrompt: Bool = false
    @State private var transcriptViewID = UUID()

    init() {
        // Initialize provider and key from configuration
        let config = AIConfigManager.shared.configuration
        switch config.defaultProvider.lowercased() {
        case "openai":
            _provider = State(initialValue: .openAI)
        case "apple (on-device)", "apple_ondevice", "apple-ondevice", "apple_on_device":
            _provider = State(initialValue: .appleOnDevice)
        default:
            _provider = State(initialValue: .appleCloud)
        }
        _openAIAPIKey = State(initialValue: AIConfigManager.shared.openAIKey() ?? "")
        if let storedSuggestionProvider = NameSuggestionProvider(rawValue: config.nameSuggestionProvider.lowercased()) {
            _nameSuggestionProvider = State(initialValue: storedSuggestionProvider)
        } else {
            _nameSuggestionProvider = State(initialValue: .openAI)
        }
    }

    private var speakerLabelsInTranscript: [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        let lines = transcriptState.displayText.components(separatedBy: CharacterSet.newlines)
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let rawLabel = String(trimmed[..<colonIndex])
            let label = baseLabel(from: rawLabel)
            guard !label.isEmpty else { continue }
            if !seen.contains(label) {
                seen.insert(label)
                ordered.append(label)
            }
        }
        return ordered
    }

    private func baseLabel(from rawLabel: String) -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespaces)
        if let parenIndex = trimmed.firstIndex(of: "(") {
            let base = trimmed[..<parenIndex]
            return base.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private var canAccessTranscript: Bool {
        mixedM4AURL != nil || !transcriptState.displayText.isEmpty
    }

    private var canAccessInsights: Bool {
        !transcriptState.displayText.isEmpty
    }

    private var hasCustomSpeakerAliases: Bool {
        for label in transcriptState.orderedSpeakerLabels {
            let alias = transcriptState.alias(for: label).trimmingCharacters(in: .whitespacesAndNewlines)
            if alias.caseInsensitiveCompare(label) != .orderedSame {
                return true
            }
        }
        return false
    }

    private var isTranscriptionActionDisabled: Bool {
        mixedM4AURL == nil ||
        isTranscribing ||
        isImportingAudio ||
        (provider == .openAI && hasPartialKnownSpeaker)
    }

    private func accessIssue(for section: WorkflowSection) -> String? {
        switch section {
        case .capture:
            return nil
        case .transcript:
            if canAccessTranscript { return nil }
            if mixedM4AURL == nil {
                return "Record or import audio before reviewing transcripts."
            }
            return "Run transcription to unlock speaker-label tools."
        case .insights:
            if transcriptState.displayText.isEmpty {
                return "Generate a transcript first to unlock insights."
            }
            if openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Set an OpenAI API key in Settings to analyze transcripts."
            }
            return nil
        }
    }


    private var providerStatusBadge: some View {
        HStack(spacing: 8) {
            Label(provider.rawValue, systemImage: provider == .openAI ? "brain.head.profile" : "waveform")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            if provider == .openAI {
                let hasKey = (AIConfigManager.shared.openAIKey() ?? "").isEmpty == false
                Label(hasKey ? "API key configured" : "API key missing", systemImage: hasKey ? "checkmark.seal" : "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(hasKey ? .green : .orange)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .capture:
            captureSection
        case .transcript:
            transcriptSection
        case .insights:
            insightsSection
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture & Prepare")
                .font(.title3).bold()
            Text("Record system audio, import existing files, and kick off transcription when you're ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(isRecording ? "Stop Recording" : "Start Recording") {
                    if isRecording {
                        stopRecording()
                    } else {
                        if mixedM4AURL != nil || !transcriptState.isEmpty {
                            showSaveBeforeRecordingPrompt = true
                        } else {
                            startRecording()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button("Import Audio…") { showImportOptionsDialog = true }
                    .disabled(isRecording || isTranscribing || isImportingAudio)

                Button("Save Audio…", action: saveAudio)
                    .disabled(mixedM4AURL == nil)

                Button("Save Transcript…") { showTranscriptFormatDialog = true }
                    .disabled(transcriptState.isEmpty)

                Spacer()
            }

            if let mov = tempMOVURL {
                LabeledContent("Temp .mov") { Text(mov.lastPathComponent) }
            }
            if let m4a = mixedM4AURL {
                LabeledContent("Mixed .m4a") { Text(m4a.lastPathComponent) }
            }

            if !transcriptState.displayText.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Latest Transcript Preview")
                            .font(.headline)
                        Spacer()
                        Button("Open Transcript Tools") { selectedSection = .transcript }
                            .buttonStyle(.bordered)
                    }
                    ScrollView {
                        Text(transcriptState.attributedDisplayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if transcriptState.displayText.isEmpty {
            transcriptEmptyState
        } else {
            transcriptReviewContent
        }
    }

    @ViewBuilder
    private var transcriptEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript not available yet")
                .font(.title3).bold()
            Text(mixedM4AURL == nil
                 ? "Record or import audio from the Capture tab, then run transcription to unlock speaker-label tools."
                 : "✅ Audio is ready\(formattedDurationSuffix()). Run transcription to unlock speaker-label tools.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            transcriptCallToAction
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transcriptCallToAction: some View {
        HStack(spacing: 8) {
            Button("Transcribe Audio") { transcribe() }
                .disabled(isTranscriptionActionDisabled)
                .buttonStyle(.borderedProminent)
            Button("Go to Capture") { selectedSection = .capture }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var transcriptReviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcript Review & Speaker Tools")
                .font(.title3).bold()
            transcriptManagementToolbar

                TranscriptView(
                    transcript: $transcriptState,
                    suggestionService: nameSuggestionService,
                    externalSuggestionTrigger: $nameSuggestionRequestSignal,
                    externalRequestInFlight: $isNameSuggestionRequestInFlight
                )
                .id(transcriptViewID)

        }
        .padding()
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transcriptManagementToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(isTranscribing ? "Transcribing..." : "Re-run Transcription") {
                    transcribe()
                }
                .disabled(isTranscriptionActionDisabled)
                .buttonStyle(.bordered)

                Button(isNameSuggestionRequestInFlight ? "Requesting…" : "Request Suggestions") {
                    status = "Requesting speaker name suggestions..."
                    nameSuggestionRequestSignal &+= 1
                }
                .disabled(isNameSuggestionRequestInFlight || transcriptState.displayText.isEmpty || nameSuggestionProvider == .disabled)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("requestSuggestionsToolbarButton")

                Button("Consolidate Consecutive Speakers", action: consolidateConsecutiveSpeakers)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("consolidateSpeakersButton")

                Button("Reset Speaker Names", action: resetSpeakerAliases)
                    .buttonStyle(.bordered)
                    .disabled(!hasCustomSpeakerAliases)
                    .accessibilityIdentifier("resetAliasesButtonToolbar")
            }

            HStack(spacing: 8) {
                Button("Save Transcript (Text)") { saveTranscript(as: .plainText) }
                    .buttonStyle(.bordered)
                    .disabled(transcriptState.isEmpty)
                Button("Save Transcript (JSON)") { saveTranscript(as: .json) }
                    .buttonStyle(.bordered)
                    .disabled(transcriptState.isEmpty)
            }

            if isNameSuggestionRequestInFlight {
                Text("Contacting \(nameSuggestionProvider.displayName) for name ideas…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

#if os(macOS)
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

    @ViewBuilder
    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Insights")
                .font(.title3).bold()
            Text("Generate structured meeting notes and future analytics from your transcript.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            meetingNotesPanel

            HStack(spacing: 8) {
                Button("Save Notes (Text)") { saveMeetingNotes(as: .plainText) }
                    .buttonStyle(.bordered)
                    .disabled(meetingNotes.isEmpty)
                Button("Save Notes (JSON)") { saveMeetingNotes(as: .json) }
                    .buttonStyle(.bordered)
                    .disabled(meetingNotes.isEmpty)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        let base = VStack(alignment: .leading, spacing: 16) {
            headerContent
            sectionTabs
        }
        return base
        .padding()
        .onChange(of: selectedSection) { oldValue, newValue in
            guard newValue != oldValue else { return }
            if let issue = accessIssue(for: newValue) {
                selectedSection = oldValue
            }
        }
        .onChange(of: transcriptState.displayText.isEmpty) { _, _ in
            if !canAccessTranscript && selectedSection == .transcript {
                selectedSection = .capture
            }
            if !canAccessInsights && selectedSection == .insights {
                selectedSection = canAccessTranscript ? .transcript : .capture
            }
        }
        .confirmationDialog(
            "Save current session?",
            isPresented: $showSaveBeforeRecordingPrompt,
            titleVisibility: .visible
        ) {
            Button("Save Audio…") { saveAudio() }
            Button("Save Transcript…") {
                showSaveBeforeRecordingPrompt = false
                showTranscriptFormatDialog = true
            }
                .disabled(transcriptState.isEmpty)
            Button("Discard", role: .destructive) {
                transcriptState = TranscriptState()
                lastTranscriptCount = 0
                mixedM4AURL = nil
                status = "Starting new recording..."
                startRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have an existing mixed audio and/or transcript. Would you like to save them before starting a new recording?")
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
        .alert("Screen capture permission required",
               isPresented: $permissionAlert,
               actions: {
                   Button("OK", role: .cancel) {}
               }, message: {
                   Text("Grant Screen Recording permission in System Settings > Privacy & Security > Screen Recording, then try again.")
               })
        .onChange(of: provider) { oldProvider, newProvider in
            let value: String
            switch newProvider {
            case .openAI: value = "openai"
            case .appleOnDevice: value = "apple_ondevice"
            case .appleCloud: value = "apple_cloud"
            }
            do { try AIConfigManager.shared.setDefaultProvider(value) } catch {
                status = "Failed to save default provider: \(error.localizedDescription)"
            }
        }
        .onChange(of: nameSuggestionProvider) { _, newProvider in
            do { try AIConfigManager.shared.setNameSuggestionProvider(newProvider.rawValue) } catch {
                status = "Failed to save name suggestion provider: \(error.localizedDescription)"
            }
        }
        .onChange(of: openAIAPIKey) { oldKey, newKey in
            do { try AIConfigManager.shared.updateOpenAIKey(newKey.isEmpty ? nil : newKey) } catch {
                status = "Failed to save OpenAI key: \(error.localizedDescription)"
            }
        }
        .onChange(of: useCustomInsightsPrompt) { _, newValue in
            if newValue && customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                customInsightsPrompt = MeetingNotesService.defaultPrompt
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showSettingsSheet = true }) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsSheetView(
                provider: $provider,
                nameSuggestionProvider: $nameSuggestionProvider,
                openAIAPIKey: $openAIAPIKey,
                openAIChunkingStrategy: $openAIChunkingStrategy,
                knownSpeakerNamesInputs: $knownSpeakerNamesInputs,
                knownSpeakerRefsInputs: $knownSpeakerRefsInputs,
                systemGain: $systemGain,
                micGain: $micGain,
                onClose: { showSettingsSheet = false }
            )
            .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(isPresented: $showURLImportSheet) {
            URLImportSheet(
                urlString: $importURLString,
                isImporting: isImportingAudio,
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

    @ViewBuilder
    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TotalRec")
                .font(.largeTitle).bold()

            Text("Status: \(status)")
                .font(.callout)
                .foregroundStyle(.secondary)
            providerStatusBadge
        }
    }

    // MARK: - Actions

    private func consolidateConsecutiveSpeakers() {
        guard transcriptState.consolidateConsecutiveSpeakers() else {
            status = "No consecutive speaker turns to consolidate."
            return
        }
        transcript = transcriptState.displayText
        lastTranscriptCount = transcriptState.displayText.count
        transcriptViewID = UUID()
        status = "Consolidated consecutive speaker turns."
    }

    private func resetSpeakerAliases() {
        guard hasCustomSpeakerAliases else {
            status = "Speaker aliases already reset."
            return
        }
        transcriptState.resetAliases()
        transcript = transcriptState.displayText
        lastTranscriptCount = transcriptState.displayText.count
        transcriptViewID = UUID()
        status = "Speaker aliases reset."
    }

    private func transcribeWithOpenAI(audioURL: URL) async {
        do {
            let chunks = try await AudioChunker.chunkIfNeeded(
                sourceURL: audioURL,
                strategy: openAIChunkingStrategy
            )
            print("[Transcribe][OpenAI] Using \(chunks.count) chunk(s) for \(audioURL.lastPathComponent)")
            defer {
                for chunk in chunks where chunk.isTemporary {
                    try? FileManager.default.removeItem(at: chunk.url)
                }
            }

            var combinedState = TranscriptState()
            let totalChunks = chunks.count
            for (index, chunk) in chunks.enumerated() {
                await MainActor.run {
                    if totalChunks > 1 {
                        status = "Transcribing chunk \(index + 1)/\(totalChunks)..."
                    } else {
                        status = "Transcribing..."
                    }
                }
                print("[Transcribe][OpenAI] Uploading chunk \(index + 1)/\(totalChunks) from \(chunk.url.lastPathComponent) offset=\(String(format: "%.2f", chunk.startTime))s")

                let chunkState = try await OpenAITranscriber().transcribeDiarized(
                    audioURL: chunk.url,
                    apiKey: openAIAPIKey,
                    baseURL: "https://api.openai.com",
                    chunkingStrategy: openAIChunkingStrategy,
                    knownSpeakerNames: nil,
                    knownSpeakerReferences: nil,
                    knownSpeakers: preparedKnownSpeakers.isEmpty ? nil : preparedKnownSpeakers,
                    onProgress: nil
                )
                print("[Transcribe][OpenAI] Chunk \(index + 1)/\(totalChunks) returned \(chunkState.segments.count) segments")
                combinedState.append(chunkState, timeOffset: chunk.startTime)
            }

            await MainActor.run {
                transcriptState = combinedState
                transcript = combinedState.displayText
                lastTranscriptCount = combinedState.displayText.count
                status = totalChunks > 1 ? "Transcription complete. (OpenAI, \(totalChunks) chunks)" : "Transcription complete. (OpenAI)"
                selectedSection = .transcript
                isTranscribing = false
            }
        } catch {
            print("[Transcribe][OpenAI] Failed: \(error)")
            await MainActor.run {
                status = "OpenAI failed: \(error.localizedDescription)"
                isTranscribing = false
            }
        }
    }

    private func generateMeetingNotes() async {
        guard !transcriptState.displayText.isEmpty else {
            await MainActor.run {
                meetingNotesError = "Transcript is empty."
            }
            return
        }

        await MainActor.run {
            isGeneratingMeetingNotes = true
            meetingNotesError = nil
            status = "Generating meeting notes..."
        }

        do {
            let trimmedPrompt = useCustomInsightsPrompt ? customInsightsPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if useCustomInsightsPrompt && (trimmedPrompt ?? "").isEmpty {
                await MainActor.run {
                    meetingNotesError = "Enter a custom prompt or disable the option."
                    status = "Meeting notes failed: Custom prompt required."
                    isGeneratingMeetingNotes = false
                }
                return
            }

            let notes = try await MeetingNotesService().generateNotes(from: transcriptState, promptOverride: trimmedPrompt)
            await MainActor.run {
                meetingNotes = notes
                status = "Meeting notes ready."
                selectedSection = .insights
                isGeneratingMeetingNotes = false
            }
        } catch {
            await MainActor.run {
                meetingNotesError = error.localizedDescription
                status = "Meeting notes failed: \(error.localizedDescription)"
                isGeneratingMeetingNotes = false
            }
        }
    }

    private func importAudioFromFileSystem() {
        guard !isImportingAudio else {
            status = "Audio import already in progress."
            return
        }
        guard !isRecording else {
            status = "Stop recording before importing audio."
            return
        }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { await performLocalAudioImport(url) }
            }
        }
        #else
        status = "File import is only supported on macOS."
        #endif
    }

    private func beginURLImport(from rawString: String) {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter a valid audio URL."
            return
        }
        guard let remoteURL = URL(string: trimmed),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            status = "Unsupported audio URL. Use http or https."
            return
        }
        showURLImportSheet = false
        importURLString = ""
        Task { await performRemoteAudioImport(remoteURL) }
    }

    private func performLocalAudioImport(_ sourceURL: URL) async {
        await MainActor.run {
            isImportingAudio = true
            status = "Importing audio..."
        }
        do {
            let ext = preferredExtension(from: sourceURL)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("totalrec-import-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            await MainActor.run {
                applyImportedAudio(at: dest, description: sourceURL.lastPathComponent)
            }
        } catch {
            await MainActor.run {
                status = "Audio import failed: \(error.localizedDescription)"
            }
        }
        await MainActor.run { isImportingAudio = false }
    }

    private func performRemoteAudioImport(_ remoteURL: URL) async {
        await MainActor.run {
            isImportingAudio = true
            status = "Downloading audio..."
        }
        do {
            let (tempFile, response) = try await URLSession.shared.download(from: remoteURL)
            let ext = preferredExtension(from: remoteURL, fallback: extensionFromResponse(response) ?? "m4a")
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("totalrec-import-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempFile, to: dest)
            await MainActor.run {
                let description = remoteURL.lastPathComponent.isEmpty ? (remoteURL.host ?? "Remote audio") : remoteURL.lastPathComponent
                applyImportedAudio(at: dest, description: description)
            }
        } catch {
            await MainActor.run {
                status = "Audio import failed: \(error.localizedDescription)"
            }
        }
        await MainActor.run { isImportingAudio = false }
    }

    @MainActor
    private func applyImportedAudio(at url: URL, description: String) {
        mixedM4AURL = url
        tempMOVURL = nil
        transcriptState = TranscriptState()
        transcript = ""
        lastTranscriptCount = 0
        status = "Imported audio: \(description)"
        selectedSection = .capture
        updateMixedAudioDuration(for: url)
    }

    private func preferredExtension(from url: URL, fallback: String = "m4a") -> String {
        let ext = url.pathExtension
        return ext.isEmpty ? fallback : ext
    }

    private func extensionFromResponse(_ response: URLResponse?) -> String? {
        guard let suggested = response?.suggestedFilename else { return nil }
        let ext = URL(fileURLWithPath: suggested).pathExtension
        return ext.isEmpty ? nil : ext
    }

    private func formattedDurationSuffix() -> String {
        guard let duration = mixedAudioDuration else { return "" }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: " (~%d:%02d)", minutes, seconds)
    }

    private func updateMixedAudioDuration(for url: URL) {
#if os(macOS)
        Task {
            let asset = AVURLAsset(url: url)
            do {
                let seconds = try await asset.load(.duration).seconds
                await MainActor.run { mixedAudioDuration = seconds }
            } catch {
                await MainActor.run { mixedAudioDuration = nil }
            }
        }
#else
        mixedAudioDuration = nil
#endif
    }

    private func startRecording() {
        status = "Preparing recording..."
        transcript = ""
        transcriptState = TranscriptState()
        mixedM4AURL = nil
        mixedAudioDuration = nil

        let tmp = FileManager.default.temporaryDirectory
        let movURL = tmp.appendingPathComponent("totalrec-\(UUID().uuidString).mov")
        tempMOVURL = movURL

        Task {
            do {
                try await recorder.startRecording(
                    to: movURL,
                    onPermissionNeeded: { permissionAlert = true }
                )
                await MainActor.run {
                    isRecording = true
                    status = "Recording (system + mic)..."
                }
            } catch {
                await MainActor.run {
                    status = "Failed to start: \(error.localizedDescription)"
                    isRecording = false
                }
            }
        }
    }

    private func stopRecording() {
        status = "Stopping..."
        recorder.stopRecording { result in
            switch result {
            case .success:
                status = "Stopped. Mixing down..."
                mixDown()
            case .failure(let error):
                status = "Stop failed: \(error.localizedDescription)"
            }
            isRecording = false
        }
    }

    private func mixDown() {
        guard let mov = tempMOVURL else { return }
        status = "Mixing down..."

        let tmp = FileManager.default.temporaryDirectory
        let m4aURL = tmp.appendingPathComponent("totalrec-\(UUID().uuidString).m4a")

        Mixdown.toM4A(
            sourceMOV: mov,
            outputM4A: m4aURL,
            systemGain: systemGain,
            micGain: micGain
        ) { result in
            switch result {
            case .success(let url):
                mixedM4AURL = url
                status = "Mixdown complete: \(url.lastPathComponent)"
                updateMixedAudioDuration(for: url)
            case .failure(let error):
                status = "Mixdown failed: \(error.localizedDescription)"
            }
        }
    }

    private func transcribe() {
        guard let audioURL = mixedM4AURL else { return }

        status = "Transcribing..."

        isTranscribing = true
        transcript = ""
        transcriptState = TranscriptState()
        lastTranscriptCount = 0

        switch provider {
        case .appleOnDevice, .appleCloud:
            let onDevice = (provider == .appleOnDevice)
            transcriber.transcribeFile(
                at: audioURL,
                onDevicePreferred: onDevice,
                onProgress: { partial in
                    DispatchQueue.main.async {
                        if partial.count >= lastTranscriptCount {
                            let startIndex = partial.index(partial.startIndex, offsetBy: lastTranscriptCount)
                            let delta = String(partial[startIndex...])
                            if !delta.isEmpty { transcriptState.appendToRawText(delta) }
                            lastTranscriptCount = partial.count
                        } else {
                            transcriptState.updateRawText(partial)
                            lastTranscriptCount = partial.count
                        }
                    }
                },
                completion: { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let full):
                            if full.count >= lastTranscriptCount {
                                let startIndex = full.index(full.startIndex, offsetBy: lastTranscriptCount)
                                let delta = String(full[startIndex...])
                                if !delta.isEmpty { transcriptState.appendToRawText(delta) }
                                lastTranscriptCount = full.count
                            }
                            transcript = full
                            status = "Transcription complete. (Apple)"
                            selectedSection = .transcript
                        case .failure(let error):
                            status = "Transcription failed: \(error.localizedDescription)"
                        }
                        isTranscribing = false
                    }
                }
            )

        case .openAI:
            if openAIAPIKey.isEmpty {
                status = "OpenAI API key missing. Enter it above."
                isTranscribing = false
                return
            }
            if hasPartialKnownSpeaker {
                status = "Please provide both a Name and a Sample for each known speaker, or clear the incomplete rows."
                isTranscribing = false
                return
            }
            Task { await transcribeWithOpenAI(audioURL: audioURL) }
        }
    }

    // MARK: - Save helpers
    private func saveAudio() {
        guard let url = mixedM4AURL else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Audio]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    DispatchQueue.main.async { status = "Save failed: \(error.localizedDescription)" }
                }
            }
        }
        #endif
    }

    private func saveTranscript(as format: TranscriptExportFormat) {
        guard !transcriptState.isEmpty else { return }
        #if os(macOS)
        let stateToSave = transcriptState
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format.suggestedFilename(hasSpeakerLabels: stateToSave.hasSpeakerLabels)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                do {
                    switch format {
                    case .json:
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(stateToSave)
                        try data.write(to: dest)
                    case .plainText:
                        let data = stateToSave.plainTextExport.data(using: .utf8) ?? Data()
                        try data.write(to: dest)
                    case .webVTT:
                        let renderer = TranscriptRenderer(transcript: stateToSave)
                        let text = renderer.captions(format: .webVTT)
                        try text.write(to: dest, atomically: true, encoding: .utf8)
                    case .srt:
                        let renderer = TranscriptRenderer(transcript: stateToSave)
                        let text = renderer.captions(format: .srt)
                        try text.write(to: dest, atomically: true, encoding: .utf8)
                    }
                } catch {
                    DispatchQueue.main.async { status = "Save failed: \(error.localizedDescription)" }
                }
            }
        }
        #endif
    }

    private enum MeetingNotesExportFormat {
        case plainText
        case json

        var displayName: String {
            switch self {
            case .plainText: return "notes.txt"
            case .json: return "notes.json"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText: return .plainText
            case .json: return .json
            }
        }
    }

    private func saveMeetingNotes(as format: MeetingNotesExportFormat) {
        guard !meetingNotes.isEmpty else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format.displayName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                do {
                    switch format {
                    case .plainText:
                        try meetingNotes.write(to: dest, atomically: true, encoding: .utf8)
                    case .json:
                        let payload = ["notes": meetingNotes]
                        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
                        try data.write(to: dest)
                    }
                } catch {
                    DispatchQueue.main.async { status = "Save failed: \(error.localizedDescription)" }
                }
            }
        }
        #endif
    }
}

private extension ContentView {
    @ViewBuilder
    private var sectionTabs: some View {
        TabView(selection: $selectedSection) {
            workflowTab(.capture, title: "Capture", systemImage: "waveform") { captureSection }
            workflowTab(.transcript, title: "Transcript", systemImage: "text.quote") { transcriptSection }
            workflowTab(.insights, title: "Insights", systemImage: "list.bullet.rectangle") { insightsSection }
        }
        .tabViewStyle(.automatic)
    }

    @ViewBuilder
    private func workflowTab<Content: View>(_ section: WorkflowSection, title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        AnyView(ScrollView { content() })
            .tag(section)
            .tabItem { Label(title, systemImage: systemImage) }
    }

    private var meetingNotesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting Notes")
                    .font(.headline)
                Spacer()
                if isGeneratingMeetingNotes {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button("Generate Meeting Notes") {
                    Task { await generateMeetingNotes() }
                }
                .disabled(isGeneratingMeetingNotes || transcriptState.displayText.isEmpty || isTranscribing)
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $useCustomInsightsPrompt.animation()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use custom GPT-5 prompt")
                            .font(.subheadline)
                        Text("Switch on to provide your own instructions for meeting notes. Keep the {{TRANSCRIPT}} token where the diarized text should be inserted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if useCustomInsightsPrompt {
                    TextEditor(text: $customInsightsPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2))
                        )
                    HStack {
                        Text("Need ideas? Start from the default template and tailor it to your workflow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to template") {
                            customInsightsPrompt = MeetingNotesService.defaultPrompt
                        }
                        .font(.caption)
                    }
                } else {
                    Text("Using TotalRec's default meeting-notes prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = meetingNotesError, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            if meetingNotes.isEmpty {
                Text("No meeting notes yet. Generate notes to see a structured summary of this meeting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(meetingNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(minHeight: 160)
            }
        }
        .padding(.top, 12)
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
        .onAppear { isFieldFocused = true }
    }
}

private struct SettingsSheetView: View {
    @Binding var provider: ContentView.TranscriptionProvider
    @Binding var nameSuggestionProvider: NameSuggestionProvider
    @Binding var openAIAPIKey: String
    @Binding var openAIChunkingStrategy: String
    @Binding var knownSpeakerNamesInputs: [String]
    @Binding var knownSpeakerRefsInputs: [String]
    @Binding var systemGain: Float
    @Binding var micGain: Float
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.title2).bold()
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Provider").font(.headline)
                Picker("Transcription Provider", selection: $provider) {
                    ForEach(ContentView.TranscriptionProvider.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                if provider == .openAI {
                    Text((AIConfigManager.shared.openAIKey() ?? "").isEmpty ? "OpenAI API key not set." : "OpenAI API key stored in Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Provider-specific settings
            Group {
                if provider == .openAI {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenAI").font(.headline)
                        HStack {
                            SecureField("OpenAI API Key", text: $openAIAPIKey)
                                .textFieldStyle(.roundedBorder)
                            Button("Clear") { openAIAPIKey = "" }
                        }
                        Picker("Chunking", selection: $openAIChunkingStrategy) {
                            Text("Auto").tag("auto")
                            Text("None").tag("none")
                        }
                        .pickerStyle(.segmented)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Known Speakers (optional)").font(.headline)
                            ForEach(0..<4, id: \.self) { idx in
                                HStack {
                                    TextField("Name #\(idx + 1)", text: $knownSpeakerNamesInputs[idx])
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Reference (data:audio/... or URL)", text: $knownSpeakerRefsInputs[idx])
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            HStack {
                                Spacer()
                                Button("Clear Speakers") {
                                    knownSpeakerNamesInputs = Array(repeating: "", count: 4)
                                    knownSpeakerRefsInputs = Array(repeating: "", count: 4)
                                }
                            }
                        }
                        Text("Optional: Provide up to 4 known speakers. Both Name and Sample are required for each.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No provider-specific settings for \(provider.rawValue).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name Suggestions").font(.headline)
                Picker("Name Suggestions Provider", selection: $nameSuggestionProvider) {
                    ForEach(NameSuggestionProvider.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("Choose how speaker names are suggested for diarized transcripts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Mixdown Gains
            VStack(alignment: .leading, spacing: 8) {
                Text("Mixdown Gains").font(.headline)
                HStack {
                    VStack(alignment: .leading) {
                        Text("System: \(String(format: "%.2f", systemGain))")
                        Slider(value: Binding(
                            get: { Double(systemGain) },
                            set: { systemGain = Float($0) }
                        ), in: 0.0...1.5)
                    }
                    VStack(alignment: .leading) {
                        Text("Mic: \(String(format: "%.2f", micGain))")
                        Slider(value: Binding(
                            get: { Double(micGain) },
                            set: { micGain = Float($0) }
                        ), in: 0.0...1.5)
                    }
                }
            }

            Spacer()
        }
        .padding()
    }
}

#if os(macOS)
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            updateWindow(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            updateWindow(nsView)
        }
    }

    private func updateWindow(_ nsView: NSView) {
        guard let window = nsView.window else { return }
        configure(window)
    }
}
#endif

#Preview {
    ContentView()
}
