import Foundation

enum SessionStage: String, Codable {
    case idle
    case preparingRecording
    case recording
    case mixingDown
    case importingAudio
    case readyToTranscribe
    case transcribing
    case generatingInsights
    case completed
    case failed
}

struct RecordingSessionSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let sourceDescription: String
    let stage: SessionStage
    let statusMessage: String
    let lastError: String?
    let lastTranscriptionProvider: String?
    let hasAudio: Bool
    let hasTranscript: Bool
    let hasMeetingNotes: Bool

    var hasProtectedActivity: Bool {
        switch stage {
        case .preparingRecording, .recording, .mixingDown, .importingAudio, .transcribing, .generatingInsights:
            return true
        case .idle, .readyToTranscribe, .completed, .failed:
            return false
        }
    }
}

struct RecordingSession: Codable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sourceDescription: String
    var sessionDirectoryName: String
    var captureMovieFilename: String?
    var mixedAudioFilename: String?
    var mixedAudioDuration: TimeInterval?
    var transcriptState: TranscriptState
    var meetingNotes: String
    var stage: SessionStage
    var statusMessage: String
    var lastError: String?
    var recordingStartedAt: Date?
    var recordingStoppedAt: Date?
    var lastTranscriptionProvider: String?

    init(
        id: UUID = UUID(),
        sourceDescription: String = "Session",
        stage: SessionStage = .idle,
        statusMessage: String = "Idle",
        lastError: String? = nil
    ) {
        let now = Date()
        self.id = id
        self.createdAt = now
        self.updatedAt = now
        self.sourceDescription = sourceDescription
        self.sessionDirectoryName = id.uuidString
        self.captureMovieFilename = nil
        self.mixedAudioFilename = nil
        self.mixedAudioDuration = nil
        self.transcriptState = TranscriptState()
        self.meetingNotes = ""
        self.stage = stage
        self.statusMessage = statusMessage
        self.lastError = lastError
        self.recordingStartedAt = nil
        self.recordingStoppedAt = nil
        self.lastTranscriptionProvider = nil
    }

    var hasProtectedActivity: Bool {
        switch stage {
        case .preparingRecording, .recording, .mixingDown, .importingAudio, .transcribing, .generatingInsights:
            return true
        case .idle, .readyToTranscribe, .completed, .failed:
            return false
        }
    }

    var hasUserData: Bool {
        captureMovieFilename != nil ||
        mixedAudioFilename != nil ||
        !transcriptState.isEmpty ||
        !meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summary: RecordingSessionSummary {
        RecordingSessionSummary(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceDescription: sourceDescription,
            stage: stage,
            statusMessage: statusMessage,
            lastError: lastError,
            lastTranscriptionProvider: lastTranscriptionProvider,
            hasAudio: mixedAudioFilename != nil,
            hasTranscript: !transcriptState.isEmpty,
            hasMeetingNotes: !meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}
