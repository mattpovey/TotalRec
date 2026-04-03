import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let appleTranscriptionChunkDuration: TimeInterval = 45

    @Published private(set) var activeSession: RecordingSession?
    @Published private(set) var recentSessionSummaries: [RecordingSessionSummary] = []
    @Published private(set) var isImportingAudio = false
    @Published private(set) var processingPreviewText = ""
    @Published private(set) var recoveryNotice: String?
    @Published var showPermissionAlert = false
    @Published var meetingNotesError: String?
    @Published var systemGain: Float = 1.0
    @Published var micGain: Float = 1.0

    private let store = SessionStore()
    private let recorder = SystemAudioRecorder()
    private let transcriber = FileTranscriber()

    private init() {
        restoreLatestSession()
    }

    var status: String {
        activeSession?.statusMessage ?? "Idle"
    }

    var statusText: String {
        status
    }

    var tempMOVURL: URL? {
        guard let activeSession else { return nil }
        return store.fileURL(for: activeSession.captureMovieFilename, in: activeSession)
    }

    var mixedM4AURL: URL? {
        guard let activeSession else { return nil }
        return store.fileURL(for: activeSession.mixedAudioFilename, in: activeSession)
    }

    var activeSessionDirectoryURL: URL? {
        guard let activeSession else { return nil }
        return store.sessionDirectoryURL(for: activeSession)
    }

    var audioURL: URL? {
        mixedM4AURL
    }

    var mixedAudioDuration: TimeInterval? {
        activeSession?.mixedAudioDuration
    }

    var transcriptState: TranscriptState {
        activeSession?.transcriptState ?? TranscriptState()
    }

    var meetingNotes: String {
        activeSession?.meetingNotes ?? ""
    }

    var isRecording: Bool {
        activeSession?.stage == .recording || activeSession?.stage == .preparingRecording
    }

    var isTranscribing: Bool {
        activeSession?.stage == .transcribing
    }

    var isGeneratingMeetingNotes: Bool {
        activeSession?.stage == .generatingInsights
    }

    var hasProtectedActivity: Bool {
        activeSession?.hasProtectedActivity == true
    }

    var canSwitchSessions: Bool {
        !hasProtectedActivity
    }

    var hasSessionContent: Bool {
        activeSession?.hasUserData == true
    }

    var isBusy: Bool {
        hasProtectedActivity || isImportingAudio
    }

    var menuBarIconName: String {
        switch activeSession?.stage {
        case .recording:
            return "record.circle"
        case .preparingRecording:
            return "record.circle.dotted"
        case .mixingDown, .transcribing, .generatingInsights, .importingAudio:
            return "gearshape.2"
        case .failed:
            return "exclamationmark.triangle"
        case .readyToTranscribe, .completed:
            return "waveform.and.mic"
        case .idle, .none:
            return "waveform"
        }
    }

    var menuBarTitle: String {
        switch activeSession?.stage {
        case .recording:
            return "Recording"
        case .preparingRecording:
            return "Preparing Recording"
        case .mixingDown:
            return "Mixing Down"
        case .transcribing:
            return "Transcribing"
        case .generatingInsights:
            return "Generating Notes"
        case .importingAudio:
            return "Importing Audio"
        case .readyToTranscribe:
            return "Ready to Transcribe"
        case .completed:
            return "Session Saved"
        case .failed:
            return "Attention Needed"
        case .idle, .none:
            return "Ready"
        }
    }

    var recordingStartedAt: Date? {
        activeSession?.recordingStartedAt
    }

    var recordingElapsedText: String? {
        guard let recordingStartedAt, isRecording else { return nil }
        let elapsed = Int(Date().timeIntervalSince(recordingStartedAt))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func clearPermissionAlert() {
        showPermissionAlert = false
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    func startRecording() {
        Task {
            await startRecording { [weak self] in
                self?.showPermissionAlert = true
            }
        }
    }

    func selectSession(_ sessionID: UUID) {
        guard canSwitchSessions || activeSession?.id == sessionID else {
            updateStatus("Finish the current recording or processing task before switching sessions.")
            return
        }

        do {
            guard var session = try store.loadSession(id: sessionID) else { return }
            recoveryNotice = normalizeRecoveredState(for: &session)
            setActiveSession(session, persist: recoveryNotice != nil)
            processingPreviewText = ""
            meetingNotesError = nil
        } catch {
            updateStatus("Failed to open session: \(error.localizedDescription)")
        }
    }

    func showNewSessionWorkspace() {
        guard !hasProtectedActivity else {
            updateStatus("Finish the current recording or processing task before starting a new workspace.")
            return
        }

        activeSession = nil
        processingPreviewText = ""
        meetingNotesError = nil
        recoveryNotice = nil
        try? store.clearCurrentSession()
        refreshRecentSessions()
    }

    func deleteSession(_ sessionID: UUID) {
        guard canSwitchSessions || activeSession?.id != sessionID else {
            updateStatus("Finish the current recording or processing task before deleting a session.")
            return
        }

        do {
            let deletingActiveSession = activeSession?.id == sessionID
            try store.deleteSession(sessionID)

            processingPreviewText = ""
            meetingNotesError = nil
            recoveryNotice = nil

            if deletingActiveSession {
                if let replacement = try store.listRecentSessions().first {
                    setActiveSession(replacement)
                } else {
                    activeSession = nil
                    try? store.clearCurrentSession()
                    refreshRecentSessions()
                }
            } else {
                refreshRecentSessions()
            }
        } catch {
            updateStatus("Failed to delete session: \(error.localizedDescription)")
        }
    }

    func updateTranscript(_ transcriptState: TranscriptState) {
        mutateActiveSession { session in
            session.transcriptState = transcriptState
            session.updatedAt = Date()
            if !transcriptState.isEmpty && session.stage == .readyToTranscribe {
                session.stage = .completed
                session.statusMessage = "Transcript updated."
            }
        }
    }

    func updateTranscriptState(_ transcriptState: TranscriptState) {
        updateTranscript(transcriptState)
    }

    func updateMeetingNotes(_ notes: String) {
        mutateActiveSession { session in
            session.meetingNotes = notes
            session.updatedAt = Date()
            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.stage = .completed
                session.statusMessage = "Meeting notes updated."
            }
        }
    }

    @discardableResult
    func consolidateConsecutiveSpeakers() -> Bool {
        guard var transcript = activeSession?.transcriptState else { return false }
        guard transcript.consolidateConsecutiveSpeakers() else { return false }
        updateTranscript(transcript)
        updateStatus("Consolidated consecutive speaker turns.")
        return true
    }

    @discardableResult
    func resetSpeakerAliases() -> Bool {
        guard var transcript = activeSession?.transcriptState else { return false }
        let before = transcript.plainTextExport
        transcript.resetAliases()
        guard transcript.plainTextExport != before else { return false }
        updateTranscript(transcript)
        updateStatus("Speaker aliases reset.")
        return true
    }

    func startRecording(onPermissionNeeded: @escaping () -> Void) async {
        guard !hasProtectedActivity else { return }
        meetingNotesError = nil

        do {
            var session = try store.createSession(sourceDescription: "Recording \(Self.sessionDateFormatter.string(from: Date()))")
            let movieURL = try store.captureMovieURL(for: session)
            session.captureMovieFilename = movieURL.lastPathComponent
            session.stage = .preparingRecording
            session.statusMessage = "Preparing recording..."
            session.updatedAt = Date()
            try store.save(session)
            setActiveSession(session)
            recoveryNotice = nil

            try await recorder.startRecording(
                to: movieURL,
                onPermissionNeeded: {
                    Task { @MainActor in onPermissionNeeded() }
                }
            )

            mutateActiveSession { current in
                current.stage = .recording
                current.statusMessage = "Recording (system + mic)..."
                current.recordingStartedAt = Date()
                current.recordingStoppedAt = nil
                current.lastError = nil
            }
        } catch {
            markCurrentSessionFailed("Failed to start: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func stopRecording() async -> Bool {
        guard isRecording || activeSession?.stage == .mixingDown else { return false }
        meetingNotesError = nil

        updateStatus("Stopping recording...")

        do {
            _ = try await stopRecorder()
            mutateActiveSession { session in
                session.stage = .mixingDown
                session.statusMessage = "Mixing down recording..."
                session.recordingStoppedAt = Date()
            }

            guard let session = activeSession, let movieURL = tempMOVURL else {
                throw NSError(domain: "TotalRec.AppModel", code: -100, userInfo: [NSLocalizedDescriptionKey: "Missing captured recording data."])
            }

            let audioURL = try store.mixedAudioURL(for: session)
            try await mixDown(sourceMOV: movieURL, outputM4A: audioURL, systemGain: systemGain, micGain: micGain)
            let duration = try? await AVURLAsset(url: audioURL).load(.duration).seconds

            mutateActiveSession { current in
                current.mixedAudioFilename = audioURL.lastPathComponent
                current.mixedAudioDuration = duration
                current.stage = .readyToTranscribe
                current.statusMessage = "Recording saved. Ready to transcribe."
                current.lastError = nil
            }
            return true
        } catch {
            markCurrentSessionFailed("Stop failed: \(error.localizedDescription)")
            return false
        }
    }

    func importAudioFromFileSystem(_ sourceURL: URL) async {
        guard !hasProtectedActivity else { return }
        await importAudio(description: sourceURL.lastPathComponent) { [self] session in
            let ext = Self.preferredExtension(from: sourceURL)
            let dest = try self.store.importedAudioURL(for: session, ext: ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return dest
        }
    }

    func importAudioFromRemoteURL(_ remoteURL: URL) async {
        guard !hasProtectedActivity else { return }
        await importAudio(description: remoteURL.lastPathComponent.isEmpty ? (remoteURL.host ?? "Remote audio") : remoteURL.lastPathComponent) { [self] session in
            let (tempFile, response) = try await URLSession.shared.download(from: remoteURL)
            let ext = Self.preferredExtension(from: remoteURL, fallback: Self.extensionFromResponse(response) ?? "m4a")
            let dest = try self.store.importedAudioURL(for: session, ext: ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempFile, to: dest)
            return dest
        }
    }

    func transcribe(_ configuration: TranscriptionRunConfiguration) async {
        guard let audioURL = mixedM4AURL else { return }
        let provider = configuration.provider

        processingPreviewText = ""
        meetingNotesError = nil
        mutateActiveSession { session in
            session.stage = .transcribing
            session.statusMessage = "Transcribing..."
            session.lastError = nil
            session.lastTranscriptionProvider = provider.rawValue
            session.updatedAt = Date()
        }

        do {
            let transcriptState: TranscriptState
            let completionStatus: String
            switch provider {
            case .appleOnDevice, .appleCloud:
                let onDevice = provider == .appleOnDevice
                let result = try await transcribeWithApple(audioURL: audioURL, onDevicePreferred: onDevice)
                transcriptState = TranscriptState(rawText: result.text)
                completionStatus = result.chunkCount > 1
                    ? "Transcription complete. (Apple, \(result.chunkCount) chunks)"
                    : "Transcription complete. (Apple)"
            case .openAI:
                transcriptState = try await transcribeWithOpenAI(
                    audioURL: audioURL,
                    apiKey: configuration.openAIAPIKey,
                    uploadChunkingStrategy: configuration.openAIChunkingStrategy,
                    knownSpeakers: configuration.knownSpeakers
                )
                completionStatus = "Transcription complete. (OpenAI)"
            case .tscript:
                guard let tscriptConfiguration = configuration.tscript else {
                    throw NSError(
                        domain: "TotalRec.AppModel",
                        code: -101,
                        userInfo: [NSLocalizedDescriptionKey: "TScript configuration is missing."]
                    )
                }
                let result = try await TScriptTranscriber().transcribe(
                    audioURL: audioURL,
                    configuration: tscriptConfiguration
                )
                transcriptState = result.transcriptState
                completionStatus = tScriptCompletionStatus(for: result.warning)
            }

            mutateActiveSession { session in
                session.transcriptState = transcriptState
                session.stage = transcriptState.isEmpty ? .readyToTranscribe : .completed
                session.statusMessage = completionStatus
                session.lastError = nil
                session.updatedAt = Date()
            }
            processingPreviewText = ""
        } catch {
            processingPreviewText = ""
            mutateActiveSession { session in
                if !session.transcriptState.isEmpty {
                    session.stage = .completed
                } else {
                    session.stage = .readyToTranscribe
                }
                session.statusMessage = provider == .openAI
                    ? "OpenAI failed: \(error.localizedDescription)"
                    : (provider == .tscript
                        ? "TScript failed: \(error.localizedDescription)"
                        : "Transcription failed: \(error.localizedDescription)")
                session.lastError = error.localizedDescription
                session.updatedAt = Date()
            }
        }
    }

    private func tScriptCompletionStatus(for warning: String?) -> String {
        guard let warning else { return "Transcription complete. (TScript)" }

        let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Transcription complete. (TScript)" }

        if trimmed.localizedCaseInsensitiveContains("without diarization enabled") ||
            trimmed.localizedCaseInsensitiveContains("did not return diarized speaker output") {
            return "Transcription complete. (TScript, diarization unavailable)"
        }

        return "Transcription complete. (TScript, warning)"
    }

    func generateMeetingNotes(promptOverride: String?) async throws {
        guard transcriptState.hasDisplayText else {
            meetingNotesError = MeetingNotesService.ServiceError.missingTranscript.localizedDescription
            throw MeetingNotesService.ServiceError.missingTranscript
        }

        meetingNotesError = nil

        mutateActiveSession { session in
            session.stage = .generatingInsights
            session.statusMessage = "Generating meeting notes..."
            session.lastError = nil
            session.updatedAt = Date()
        }

        do {
            let notes = try await MeetingNotesService().generateNotes(from: transcriptState, promptOverride: promptOverride)
            mutateActiveSession { session in
                session.meetingNotes = notes
                session.stage = .completed
                session.statusMessage = "Meeting notes ready."
                session.lastError = nil
                session.updatedAt = Date()
            }
        } catch {
            meetingNotesError = error.localizedDescription
            mutateActiveSession { session in
                session.stage = session.transcriptState.isEmpty ? .readyToTranscribe : .completed
                session.statusMessage = "Meeting notes failed: \(error.localizedDescription)"
                session.lastError = error.localizedDescription
                session.updatedAt = Date()
            }
            throw error
        }
    }

    func revealMainStatus() -> String {
        if let session = activeSession {
            return "\(menuBarTitle): \(session.statusMessage)"
        }
        return "Ready"
    }

    func setStatusMessage(_ statusMessage: String) {
        updateStatus(statusMessage)
    }

    private func importAudio(
        description: String,
        importer: @escaping (RecordingSession) async throws -> URL
    ) async {
        isImportingAudio = true

        do {
            var session = try store.createSession(sourceDescription: description)
            session.stage = .importingAudio
            session.statusMessage = "Importing audio..."
            session.updatedAt = Date()
            try store.save(session)
            setActiveSession(session)
            recoveryNotice = nil

            let importedURL = try await importer(session)
            let duration = try? await AVURLAsset(url: importedURL).load(.duration).seconds

            mutateActiveSession { current in
                current.captureMovieFilename = nil
                current.mixedAudioFilename = importedURL.lastPathComponent
                current.mixedAudioDuration = duration
                current.transcriptState = TranscriptState()
                current.meetingNotes = ""
                current.stage = .readyToTranscribe
                current.statusMessage = "Imported audio: \(description)"
                current.lastError = nil
                current.updatedAt = Date()
            }
        } catch {
            markCurrentSessionFailed("Audio import failed: \(error.localizedDescription)")
        }

        isImportingAudio = false
    }

    private func restoreLatestSession() {
        guard var restored = try? store.loadLatestSession() else {
            activeSession = nil
            refreshRecentSessions()
            return
        }

        recoveryNotice = normalizeRecoveredState(for: &restored)
        setActiveSession(restored, persist: recoveryNotice != nil)
        refreshRecentSessions()
    }

    private func updateStatus(_ statusMessage: String) {
        mutateActiveSession { session in
            session.statusMessage = statusMessage
            session.updatedAt = Date()
        }
    }

    private func markCurrentSessionFailed(_ message: String) {
        if activeSession == nil {
            do {
                var session = try store.createSession(sourceDescription: "Recovered session")
                session.stage = .failed
                session.statusMessage = message
                session.lastError = message
                session.updatedAt = Date()
                try store.save(session)
                setActiveSession(session)
            } catch {
                let session = RecordingSession(
                    sourceDescription: "Recovered session",
                    stage: .failed,
                    statusMessage: message,
                    lastError: message
                )
                activeSession = session
                refreshRecentSessions()
            }
            return
        }

        mutateActiveSession { session in
            session.stage = session.mixedAudioFilename == nil ? .failed : .readyToTranscribe
            session.statusMessage = message
            session.lastError = message
            session.updatedAt = Date()
        }
    }

    private func mutateActiveSession(_ update: (inout RecordingSession) -> Void) {
        guard var session = activeSession else { return }
        update(&session)
        session.updatedAt = Date()
        setActiveSession(session, persist: true)
    }

    private func setActiveSession(_ session: RecordingSession, persist: Bool = false) {
        if persist {
            try? store.save(session)
        } else {
            try? store.setCurrentSession(session.id)
        }
        activeSession = session
        mergeActiveSessionIntoRecentSessions(session)
    }

    private func refreshRecentSessions() {
        do {
            var sessions = try store.listRecentSessionSummaries()
            if let activeSession,
               let existingIndex = sessions.firstIndex(where: { $0.id == activeSession.id }) {
                sessions[existingIndex] = activeSession.summary
            } else if let activeSession {
                sessions.insert(activeSession.summary, at: 0)
            }
            recentSessionSummaries = sessions
        } catch {
            recentSessionSummaries = activeSession.map { [$0.summary] } ?? []
        }
    }

    private func mergeActiveSessionIntoRecentSessions(_ session: RecordingSession) {
        var sessions = recentSessionSummaries
        let summary = session.summary
        if let existingIndex = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[existingIndex] = summary
        } else {
            sessions.append(summary)
        }

        sessions.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        if sessions.count > 12 {
            sessions = Array(sessions.prefix(12))
        }

        recentSessionSummaries = sessions
    }

    private func normalizeRecoveredState(for session: inout RecordingSession) -> String? {
        guard session.hasProtectedActivity else { return nil }

        let recoveryMessage = "Recovered an interrupted session. Review the saved artifacts before continuing."
        session.lastError = recoveryMessage
        if session.mixedAudioFilename != nil {
            session.stage = session.transcriptState.isEmpty ? .readyToTranscribe : .completed
        } else {
            session.stage = .failed
        }
        session.statusMessage = "Recovered an interrupted session."
        session.updatedAt = Date()
        return recoveryMessage
    }

    private func stopRecorder() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            recorder.stopRecording { result in
                continuation.resume(with: result)
            }
        }
    }

    private func mixDown(sourceMOV: URL, outputM4A: URL, systemGain: Float, micGain: Float) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Mixdown.toM4A(
                sourceMOV: sourceMOV,
                outputM4A: outputM4A,
                systemGain: systemGain,
                micGain: micGain
            ) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    private struct AppleTranscriptionResult {
        let text: String
        let chunkCount: Int
    }

    private func transcribeWithApple(audioURL: URL, onDevicePreferred: Bool) async throws -> AppleTranscriptionResult {
        let chunks = try await AudioChunker.chunkIfNeeded(
            sourceURL: audioURL,
            strategy: "auto",
            maxDuration: Self.appleTranscriptionChunkDuration
        )
        defer {
            for chunk in chunks where chunk.isTemporary {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        var completedChunks: [String] = []
        let totalChunks = chunks.count

        for (index, chunk) in chunks.enumerated() {
            updateStatus(totalChunks > 1 ? "Transcribing chunk \(index + 1)/\(totalChunks)..." : "Transcribing...")
            let text = try await transcribeAppleChunk(
                audioURL: chunk.url,
                onDevicePreferred: onDevicePreferred,
                completedChunks: completedChunks
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                completedChunks.append(trimmed)
            }
        }

        if totalChunks > 1 {
            updateStatus("Transcription complete. (Apple, \(totalChunks) chunks)")
        }

        return AppleTranscriptionResult(
            text: completedChunks.joined(separator: "\n\n"),
            chunkCount: totalChunks
        )
    }

    private func transcribeAppleChunk(
        audioURL: URL,
        onDevicePreferred: Bool,
        completedChunks: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            transcriber.transcribeFile(
                at: audioURL,
                onDevicePreferred: onDevicePreferred,
                onProgress: { [weak self] partial in
                    Task { @MainActor in
                        let previewChunks = completedChunks + [partial]
                        self?.processingPreviewText = previewChunks
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n\n")
                    }
                },
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }

    private func transcribeWithOpenAI(
        audioURL: URL,
        apiKey: String,
        uploadChunkingStrategy: String,
        knownSpeakers: [OpenAITranscriber.KnownSpeaker]
    ) async throws -> TranscriptState {
        let chunks = try await AudioChunker.chunkIfNeeded(
            sourceURL: audioURL,
            strategy: uploadChunkingStrategy
        )
        defer {
            for chunk in chunks where chunk.isTemporary {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        var combinedState = TranscriptState()
        let totalChunks = chunks.count
        for (index, chunk) in chunks.enumerated() {
            updateStatus(totalChunks > 1 ? "Transcribing chunk \(index + 1)/\(totalChunks)..." : "Transcribing...")

            let chunkState = try await OpenAITranscriber().transcribeDiarized(
                audioURL: chunk.url,
                apiKey: apiKey,
                baseURL: "https://api.openai.com",
                chunkingStrategy: "auto",
                knownSpeakerNames: nil,
                knownSpeakerReferences: nil,
                knownSpeakers: knownSpeakers.isEmpty ? nil : knownSpeakers,
                onProgress: nil
            )
            combinedState.append(chunkState, timeOffset: chunk.startTime)
        }

        if totalChunks > 1 {
            updateStatus("Transcription complete. (OpenAI, \(totalChunks) chunks)")
        }
        return combinedState
    }

    private static func preferredExtension(from url: URL, fallback: String = "m4a") -> String {
        let ext = url.pathExtension
        return ext.isEmpty ? fallback : ext
    }

    private static func extensionFromResponse(_ response: URLResponse?) -> String? {
        guard let suggested = response?.suggestedFilename else { return nil }
        let ext = URL(fileURLWithPath: suggested).pathExtension
        return ext.isEmpty ? nil : ext
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
