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
    @State private var transcript: String = ""
    @State private var transcriptModel: Transcript?
    @State private var status: String = "Idle"
    @State private var systemGain: Float = 1.0
    @State private var micGain: Float = 1.0
    @State private var isTranscribing = false
    @State private var lastTranscriptCount: Int = 0
    @State private var showSaveBeforeRecordingPrompt = false
    @State private var knownSpeakerNamesInputs: [String] = Array(repeating: "", count: 4)
    @State private var knownSpeakerRefsInputs: [String] = Array(repeating: "", count: 4)
    @State private var showSettingsSheet: Bool = false

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

    @State private var openAIAPIKey: String = ""
    @AppStorage("openAIChunkingStrategy") private var openAIChunkingStrategy: String = "auto" // "auto" or "none"
    @State private var provider: TranscriptionProvider = .appleCloud

    private let recorder = SystemAudioRecorder()
    private let transcriber = FileTranscriber()

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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TotalRec")
                .font(.largeTitle).bold()

            // Status + transcript preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Status: \(status)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !transcript.isEmpty {
                    Text("Transcript (live):")
                        .font(.headline)
                    ScrollView {
                        Text(transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                }
            }

            // Transcription Provider
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Provider")
                    .font(.headline)
                Picker("Provider", selection: $provider) {
                    ForEach(TranscriptionProvider.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                
                if provider == .openAI {
                    Text("Configure OpenAI settings from the gear button in the toolbar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Controls
            HStack(spacing: 12) {
                Button(isRecording ? "Stop Recording" : "Start Recording") {
                    if isRecording {
                        stopRecording()
                    } else {
                        // If there is existing audio or transcript, offer to save
                        if mixedM4AURL != nil || !transcript.isEmpty {
                            showSaveBeforeRecordingPrompt = true
                        } else {
                            startRecording()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button(isTranscribing ? "Transcribing..." : "Transcribe")
                {
                    transcribe()
                }
                .disabled(mixedM4AURL == nil || isTranscribing || (provider == .openAI && hasPartialKnownSpeaker))
                
                Button("Save Audio…") {
                    saveAudio()
                }
                .disabled(mixedM4AURL == nil)

                Button("Save Transcript…") {
                    saveTranscript()
                }
                .disabled(transcript.isEmpty)
            }

            // File locations
            if let mov = tempMOVURL {
                LabeledContent("Temp .mov") {
                    Text(mov.lastPathComponent)
                }
            }
            if let m4a = mixedM4AURL {
                LabeledContent("Mixed .m4a") {
                    Text(m4a.lastPathComponent)
                }
            }

            Spacer()
        }
        .padding()
        .confirmationDialog(
            "Save current session?",
            isPresented: $showSaveBeforeRecordingPrompt,
            titleVisibility: .visible
        ) {
            Button("Save Audio…") { saveAudio() }
            Button("Save Transcript…") { saveTranscript() }
                .disabled(transcript.isEmpty)
            Button("Discard", role: .destructive) {
                transcript = ""
                lastTranscriptCount = 0
                mixedM4AURL = nil
                status = "Starting new recording..."
                startRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have an existing mixed audio and/or transcript. Would you like to save them before starting a new recording?")
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
        .onChange(of: openAIAPIKey) { oldKey, newKey in
            do { try AIConfigManager.shared.updateOpenAIKey(newKey.isEmpty ? nil : newKey) } catch {
                status = "Failed to save OpenAI key: \(error.localizedDescription)"
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
    }

    // MARK: - Actions

    private func startRecording() {
        status = "Preparing recording..."
        transcript = ""
        transcriptModel = nil
        mixedM4AURL = nil

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
        transcriptModel = nil
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
                            if !delta.isEmpty { transcript += delta }
                            lastTranscriptCount = partial.count
                        } else {
                            transcript = partial
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
                                if !delta.isEmpty { transcript += delta }
                                lastTranscriptCount = full.count
                            }
                            transcriptModel = Transcript(
                                segments: [TranscriptSegment(speakerLabel: nil, text: transcript, start: nil, end: nil)]
                            )
                            status = "Transcription complete. (Apple)"
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
            }
            if hasPartialKnownSpeaker {
                status = "Please provide both a Name and a Sample for each known speaker, or clear the incomplete rows."
                isTranscribing = false
                return
            }
            OpenAITranscriber().transcribeDiarized(
                audioURL: audioURL,
                apiKey: openAIAPIKey,
                baseURL: "https://api.openai.com",
                chunkingStrategy: openAIChunkingStrategy,
                knownSpeakerNames: nil,
                knownSpeakerReferences: nil,
                knownSpeakers: preparedKnownSpeakers.isEmpty ? nil : preparedKnownSpeakers,
                onProgress: nil
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let model):
                        transcriptModel = model
                        let renderer = TranscriptRenderer(transcript: model)
                        let rendered = renderer.plainText()
                        transcript = rendered
                        lastTranscriptCount = rendered.count
                        status = "Transcription complete. (OpenAI)"
                    case .failure(let error):
                        status = "OpenAI failed: \(error.localizedDescription)"
                    }
                    isTranscribing = false
                }
            }
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

    private func saveTranscript() {
        guard let model = currentTranscriptModel() else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        var types: [UTType] = [.plainText, .json]
        if let vtt = UTType(filenameExtension: "vtt") {
            types.append(vtt)
        }
        if let srt = UTType(filenameExtension: "srt") {
            types.append(srt)
        }
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = "transcript.txt"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                do {
                    let renderer = TranscriptRenderer(transcript: model)
                    try writeTranscript(using: renderer, to: dest)
                } catch {
                    DispatchQueue.main.async { status = "Save failed: \(error.localizedDescription)" }
                }
            }
        }
        #endif
    }

    private func currentTranscriptModel() -> Transcript? {
        if let model = transcriptModel { return model }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Transcript(segments: [TranscriptSegment(speakerLabel: nil, text: text, start: nil, end: nil)])
    }

    #if os(macOS)
    private func writeTranscript(using renderer: TranscriptRenderer, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        switch ext {
        case "json":
            let data = try renderer.json(pretty: true)
            try data.write(to: url)
        case "vtt":
            let text = renderer.captions(format: .webVTT)
            try text.write(to: url, atomically: true, encoding: .utf8)
        case "srt":
            let text = renderer.captions(format: .srt)
            try text.write(to: url, atomically: true, encoding: .utf8)
        default:
            let text = renderer.plainText()
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif
}

private struct SettingsSheetView: View {
    @Binding var provider: ContentView.TranscriptionProvider
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

#Preview {
    ContentView()
}
