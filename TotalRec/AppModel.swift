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
    @Published private(set) var insightStreamingText = ""
    @Published private(set) var insightRunStartedAt: Date?
    @Published private(set) var isStoppingInsightArtifact = false
    @Published private(set) var transientNotice: TransientNotice?
    @Published var showPermissionAlert = false
    @Published var insightRunError: String?
    @Published var systemGain: Float = 1.0
    @Published var micGain: Float = 1.0

    private let store: SessionStore
    private let recorder: any AudioRecording
    private let recordingFinalizer: any RecordingFinalizing
    private let transcriber: any AudioTranscribing
    private let insightGenerator: any InsightGenerating
    private let defaultInsightSettingsProvider: () -> InsightSettings
    private var insightGenerationTask: Task<Void, Never>?
    private var transientNoticeDismissalTask: Task<Void, Never>?

    init(
        store: SessionStore? = nil,
        recorder: (any AudioRecording)? = nil,
        recordingFinalizer: (any RecordingFinalizing)? = nil,
        transcriber: (any AudioTranscribing)? = nil,
        insightGenerator: (any InsightGenerating)? = nil,
        defaultInsightSettingsProvider: (() -> InsightSettings)? = nil,
        shouldRestoreLatestSession: Bool = true
    ) {
        self.store = store ?? SessionStore()
        self.recorder = recorder ?? SystemAudioRecorder()
        self.recordingFinalizer = recordingFinalizer ?? RecordingFinalizer()
        self.transcriber = transcriber ?? FileTranscriber()
        self.insightGenerator = insightGenerator ?? InsightGenerationService()
        self.defaultInsightSettingsProvider = defaultInsightSettingsProvider ?? {
            InsightSettings(selectedWorkflow: AIConfigManager.shared.configuration.normalizedInsightWorkflow)
        }

        if shouldRestoreLatestSession {
            restoreLatestSession()
        } else {
            refreshRecentSessions()
        }
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

    var rawCaptureFileState: RecordingCaptureFileState {
        RecordingArtifactValidator.inspectCaptureFile(at: tempMOVURL)
    }

    var canRetryRecordingFinalization: Bool {
        activeSession?.stage == .failed &&
            activeSession?.mixedAudioFilename == nil &&
            rawCaptureFileState.canAttemptRecovery
    }

    var mixedAudioDuration: TimeInterval? {
        activeSession?.mixedAudioDuration
    }

    var transcriptState: TranscriptState {
        activeSession?.transcriptState ?? TranscriptState()
    }

    var insightArtifact: InsightArtifact? {
        activeSession?.insightArtifact
    }

    var insightArtifactContent: String {
        insightArtifact?.content ?? ""
    }

    var insightSettings: InsightSettings {
        activeSession?.insightSettings ?? defaultInsightSettingsProvider()
    }

    var isRecording: Bool {
        activeSession?.stage == .recording || activeSession?.stage == .preparingRecording
    }

    var isTranscribing: Bool {
        activeSession?.stage == .transcribing
    }

    var isGeneratingInsightArtifact: Bool {
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
        activeSession?.stage.totalRecMenuBarIconName ?? SessionStage.idle.totalRecMenuBarIconName
    }

    var menuBarTitle: String {
        activeSession?.stage.totalRecMenuBarTitle ?? SessionStage.idle.totalRecMenuBarTitle
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

    var insightRunElapsedText: String? {
        guard let insightRunStartedAt, isGeneratingInsightArtifact else { return nil }
        let elapsed = Int(Date().timeIntervalSince(insightRunStartedAt))
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

    func showNotice(
        _ message: String,
        style: TransientNoticeStyle = .info,
        autoDismissAfter delay: TimeInterval? = 6
    ) {
        transientNoticeDismissalTask?.cancel()

        let notice = TransientNotice(message: message, style: style)
        transientNotice = notice

        guard let delay, delay > 0 else { return }
        transientNoticeDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.transientNotice?.id == notice.id else { return }
            self?.transientNotice = nil
            self?.transientNoticeDismissalTask = nil
        }
    }

    func dismissTransientNotice() {
        transientNoticeDismissalTask?.cancel()
        transientNoticeDismissalTask = nil
        transientNotice = nil
    }

    func updateInsightSettings(_ settings: InsightSettings) {
        mutateActiveSession { session in
            session.insightSettings = settings
        }
    }

    func startRecording() {
        Task {
            await startRecording { [weak self] in
                self?.showPermissionAlert = true
            }
        }
    }

    func startInsightArtifactGeneration() {
        guard insightGenerationTask == nil else { return }

        insightGenerationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.insightGenerationTask = nil
                self.isStoppingInsightArtifact = false
            }

            do {
                try await self.generateInsightArtifact()
            } catch is CancellationError {
                // Cancellation is user initiated and already reflected in model state.
            } catch {
                // AppModel already surfaced the failure state.
            }
        }
    }

    func stopInsightArtifactGeneration() {
        guard let insightGenerationTask, isGeneratingInsightArtifact else { return }

        DiagnosticsLogger.log(
            category: "Insights",
            message: "Stopping insight artifact generation.",
            metadata: [
                "workflow": insightSettings.selectedWorkflow.rawValue,
                "streamedChars": "\(insightStreamingText.count)"
            ]
        )

        isStoppingInsightArtifact = true
        mutateActiveSession { session in
            session.statusMessage = "Stopping insight generation..."
            session.lastError = nil
            session.updatedAt = Date()
        }

        insightGenerationTask.cancel()
    }

    func selectSession(_ sessionID: UUID) {
        guard canSwitchSessions || activeSession?.id == sessionID else {
            showNotice(
                "Finish the current recording or processing task before switching sessions.",
                style: .warning
            )
            return
        }

        do {
            guard var session = try store.loadSession(id: sessionID) else { return }
            recoveryNotice = normalizeRecoveredState(for: &session)
            setActiveSession(session, persist: recoveryNotice != nil)
            resetTransientRunState()
        } catch {
            showNotice("Failed to open session: \(error.localizedDescription)", style: .error)
        }
    }

    func showNewSessionWorkspace() {
        guard !hasProtectedActivity else {
            showNotice(
                "Finish the current recording or processing task before starting a new workspace.",
                style: .warning
            )
            return
        }

        activeSession = nil
        resetTransientRunState()
        recoveryNotice = nil
        try? store.clearCurrentSession()
        refreshRecentSessions()
    }

    func deleteSession(_ sessionID: UUID) {
        guard canSwitchSessions || activeSession?.id != sessionID else {
            showNotice(
                "Finish the current recording or processing task before deleting a session.",
                style: .warning
            )
            return
        }

        do {
            let deletingActiveSession = activeSession?.id == sessionID
            try store.deleteSession(sessionID)

            resetTransientRunState()
            recoveryNotice = nil

            if deletingActiveSession {
                if let replacement = try store.listRecentSessions().first {
                    setActiveSession(replacement)
                    refreshRecentSessions()
                } else {
                    activeSession = nil
                    try? store.clearCurrentSession()
                    refreshRecentSessions()
                }
            } else {
                refreshRecentSessions()
            }
        } catch {
            showNotice("Failed to delete session: \(error.localizedDescription)", style: .error)
        }
    }

    @discardableResult
    func renameSession(_ sessionID: UUID, to proposedTitle: String) -> Bool {
        let normalizedTitle = proposedTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalizedTitle.isEmpty else {
            showNotice("Session title cannot be empty.", style: .warning)
            return false
        }

        if activeSession?.id == sessionID {
            guard activeSession?.displayTitle != normalizedTitle else { return true }
            mutateActiveSession { session in
                session.title = normalizedTitle
            }
            showNotice("Session renamed.", style: .success)
            return true
        }

        do {
            guard var session = try store.loadSession(id: sessionID) else {
                showNotice("The session could not be found.", style: .error)
                return false
            }
            guard session.displayTitle != normalizedTitle else { return true }

            session.title = normalizedTitle
            session.updatedAt = Date()
            try store.save(session, makeCurrent: false)
            refreshRecentSessions()
            showNotice("Session renamed.", style: .success)
            return true
        } catch {
            showNotice("Failed to rename session: \(error.localizedDescription)", style: .error)
            return false
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

    func updateInsightArtifact(_ artifact: InsightArtifact?) {
        mutateActiveSession { session in
            session.insightArtifact = artifact
            if artifact?.hasContent == true {
                session.stage = .completed
                session.statusMessage = "Insight artifact updated."
            }
        }
    }

    @discardableResult
    func consolidateConsecutiveSpeakers() -> Bool {
        guard var transcript = activeSession?.transcriptState else { return false }
        guard transcript.consolidateConsecutiveSpeakers() else { return false }
        updateTranscript(transcript)
        updateWorkflowStatus("Consolidated consecutive speaker turns.")
        return true
    }

    @discardableResult
    func resetSpeakerAliases() -> Bool {
        guard var transcript = activeSession?.transcriptState else { return false }
        let before = transcript.plainTextExport
        transcript.resetAliases()
        guard transcript.plainTextExport != before else { return false }
        updateTranscript(transcript)
        updateWorkflowStatus("Speaker aliases reset.")
        return true
    }

    func startRecording(onPermissionNeeded: @escaping () -> Void) async {
        guard !hasProtectedActivity else { return }
        resetInsightRunState()

        do {
            var session = try store.createSession(
                sourceDescription: "Recording \(Self.sessionDateFormatter.string(from: Date()))",
                insightSettings: defaultInsightSettingsProvider()
            )
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
        resetInsightRunState()

        updateWorkflowStatus("Stopping recording...")

        do {
            let captureURL = try await stopRecorder()
            mutateActiveSession { session in
                session.stage = .mixingDown
                session.statusMessage = "Mixing down recording..."
                session.recordingStoppedAt = Date()
            }
            try await finalizeRecordingCapture(at: captureURL)
            return true
        } catch {
            markCurrentSessionFailed("Stop failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func retryRecordingFinalization() async -> Bool {
        guard canRetryRecordingFinalization, let captureURL = tempMOVURL else {
            return false
        }

        resetInsightRunState()
        mutateActiveSession { session in
            session.stage = .mixingDown
            session.statusMessage = "Recovering audio from raw capture..."
            session.lastError = nil
        }

        do {
            try await finalizeRecordingCapture(at: captureURL)
            return true
        } catch {
            markCurrentSessionFailed("Recovery failed: \(error.localizedDescription)")
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
        resetInsightRunState()
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
                let result = try await Self.transcribeWithTScriptOffMain(
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

    func generateInsightArtifact() async throws {
        guard transcriptState.hasDisplayText else {
            insightRunError = InsightGenerationService.ServiceError.missingTranscript.localizedDescription
            throw InsightGenerationService.ServiceError.missingTranscript
        }

        DiagnosticsLogger.log(
            category: "Insights",
            message: "Starting insight artifact generation.",
            metadata: [
                "workflow": insightSettings.selectedWorkflow.rawValue,
                "customPrompt": insightSettings.useCustomPrompt ? "true" : "false",
                "transcriptChars": "\(transcriptState.rawText.count)"
            ]
        )

        insightRunError = nil
        insightStreamingText = ""
        insightRunStartedAt = Date()

        mutateActiveSession { session in
            session.stage = .generatingInsights
            session.statusMessage = "Generating insight artifact..."
            session.lastError = nil
            session.updatedAt = Date()
        }

        do {
            let artifact = try await insightGenerator.generateArtifact(
                from: transcriptState,
                settings: insightSettings
            ) { [weak self] event in
                self?.applyInsightGenerationEvent(event)
            }
            try Task.checkCancellation()

            mutateActiveSession { session in
                session.insightArtifact = artifact
                session.stage = .completed
                session.statusMessage = "\(artifact.title) ready."
                session.lastError = nil
                session.updatedAt = Date()
            }
            insightStreamingText = ""
            insightRunStartedAt = nil
            insightRunError = nil
            DiagnosticsLogger.log(
                category: "Insights",
                message: "Insight artifact generation completed.",
                metadata: [
                    "workflow": artifact.workflow.rawValue,
                    "artifactChars": "\(artifact.content.count)",
                    "transport": artifact.transport.rawValue
                ]
            )
        } catch is CancellationError {
            DiagnosticsLogger.log(
                category: "Insights",
                message: "Insight artifact generation stopped.",
                metadata: [
                    "workflow": insightSettings.selectedWorkflow.rawValue,
                    "streamedChars": "\(insightStreamingText.count)"
                ]
            )
            insightRunStartedAt = nil
            insightRunError = nil
            mutateActiveSession { session in
                session.stage = session.transcriptState.isEmpty ? .readyToTranscribe : .completed
                session.statusMessage = "Insight generation stopped."
                session.lastError = nil
                session.updatedAt = Date()
            }
            throw CancellationError()
        } catch {
            DiagnosticsLogger.logError(
                category: "Insights",
                message: "Insight artifact generation failed.",
                error: error,
                metadata: [
                    "workflow": insightSettings.selectedWorkflow.rawValue,
                    "streamedChars": "\(insightStreamingText.count)",
                    "runStarted": insightRunStartedAt?.ISO8601Format() ?? "nil"
                ]
            )
            insightRunError = error.localizedDescription
            mutateActiveSession { session in
                session.stage = session.transcriptState.isEmpty ? .readyToTranscribe : .completed
                session.statusMessage = "Insight generation failed: \(error.localizedDescription)"
                session.lastError = error.localizedDescription
                session.updatedAt = Date()
            }
            insightRunStartedAt = nil
            throw error
        }
    }

    func revealMainStatus() -> String {
        if let session = activeSession {
            return "\(menuBarTitle): \(session.statusMessage)"
        }
        return "Ready"
    }

    private func importAudio(
        description: String,
        importer: @escaping (RecordingSession) async throws -> URL
    ) async {
        isImportingAudio = true

        do {
            var session = try store.createSession(
                sourceDescription: description,
                insightSettings: defaultInsightSettingsProvider()
            )
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
                current.insightArtifact = nil
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
        resetTransientRunState()
        refreshRecentSessions()
    }

    private func updateWorkflowStatus(_ statusMessage: String) {
        mutateActiveSession { session in
            session.statusMessage = statusMessage
        }
    }

    private func markCurrentSessionFailed(_ message: String) {
        if activeSession == nil {
            do {
                var session = try store.createSession(
                    sourceDescription: "Recovered session",
                    insightSettings: defaultInsightSettingsProvider()
                )
                session.stage = .failed
                session.statusMessage = message
                session.lastError = message
                session.updatedAt = Date()
                try store.save(session)
                setActiveSession(session)
            } catch {
                let session = RecordingSession(
                    sourceDescription: "Recovered session",
                    insightSettings: defaultInsightSettingsProvider(),
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
            do {
                try store.save(session)
            } catch {
                DiagnosticsLogger.logError(
                    category: "SessionStore",
                    message: "Failed to persist active session.",
                    error: error,
                    metadata: [
                        "sessionID": session.id.uuidString,
                        "stage": session.stage.rawValue
                    ]
                )
            }
        } else {
            do {
                try store.setCurrentSession(session.id)
            } catch {
                DiagnosticsLogger.logError(
                    category: "SessionStore",
                    message: "Failed to update current session pointer.",
                    error: error,
                    metadata: ["sessionID": session.id.uuidString]
                )
            }
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

    private func applyInsightGenerationEvent(_ event: TextGenerationEvent) {
        switch event {
        case .started:
            if insightRunStartedAt == nil {
                insightRunStartedAt = Date()
            }
        case let .textDelta(delta):
            insightStreamingText.append(delta)
        case .completed:
            break
        case let .failed(message):
            insightRunError = message
        }
    }

    private func resetInsightRunState() {
        insightStreamingText = ""
        insightRunStartedAt = nil
        insightRunError = nil
        isStoppingInsightArtifact = false
    }

    private func resetTransientRunState() {
        processingPreviewText = ""
        resetInsightRunState()
        dismissTransientNotice()
    }

    private func stopRecorder() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            recorder.stopRecording { result in
                continuation.resume(with: result)
            }
        }
    }

    private func finalizeRecordingCapture(at captureURL: URL) async throws {
        guard let session = activeSession else {
            throw RecordingRecoveryError.missingCapture
        }

        let audioURL = try store.mixedAudioURL(for: session)
        let duration = try await recordingFinalizer.finalizeCapture(
            at: captureURL,
            outputURL: audioURL,
            systemGain: systemGain,
            micGain: micGain
        )

        mutateActiveSession { current in
            current.mixedAudioFilename = audioURL.lastPathComponent
            current.mixedAudioDuration = duration
            current.stage = .readyToTranscribe
            current.statusMessage = "Recording saved. Ready to transcribe."
            current.lastError = nil
            current.recordingStoppedAt = current.recordingStoppedAt ?? Date()
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
            updateWorkflowStatus(totalChunks > 1 ? "Transcribing chunk \(index + 1)/\(totalChunks)..." : "Transcribing...")
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
            updateWorkflowStatus("Transcription complete. (Apple, \(totalChunks) chunks)")
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
                localeID: Locale.current.identifier,
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
            updateWorkflowStatus(totalChunks > 1 ? "Transcribing chunk \(index + 1)/\(totalChunks)..." : "Transcribing...")

            let chunkState = try await Self.transcribeOpenAIChunkOffMain(
                audioURL: chunk.url,
                apiKey: apiKey,
                knownSpeakers: knownSpeakers
            )
            combinedState.append(chunkState, timeOffset: chunk.startTime)
        }

        if totalChunks > 1 {
            updateWorkflowStatus("Transcription complete. (OpenAI, \(totalChunks) chunks)")
        }
        return combinedState
    }

    private nonisolated static func transcribeOpenAIChunkOffMain(
        audioURL: URL,
        apiKey: String,
        knownSpeakers: [OpenAITranscriber.KnownSpeaker]
    ) async throws -> TranscriptState {
        try await Task.detached(priority: .userInitiated) {
            try await OpenAITranscriber().transcribeDiarized(
                audioURL: audioURL,
                apiKey: apiKey,
                baseURL: "https://api.openai.com",
                chunkingStrategy: "auto",
                knownSpeakerNames: nil,
                knownSpeakerReferences: nil,
                knownSpeakers: knownSpeakers.isEmpty ? nil : knownSpeakers,
                onProgress: nil
            )
        }.value
    }

    private nonisolated static func transcribeWithTScriptOffMain(
        audioURL: URL,
        configuration: TScriptTranscriptionRunConfiguration
    ) async throws -> (transcriptState: TranscriptState, warning: String?) {
        try await Task.detached(priority: .userInitiated) {
            let result = try await TScriptTranscriber().transcribe(
                audioURL: audioURL,
                configuration: configuration
            )
            return (result.transcriptState, result.warning)
        }.value
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
