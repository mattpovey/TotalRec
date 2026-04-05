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
    let hasInsightArtifact: Bool

    var hasMeetingNotes: Bool {
        hasInsightArtifact
    }

    var hasProtectedActivity: Bool {
        switch stage {
        case .preparingRecording, .recording, .mixingDown, .importingAudio, .transcribing, .generatingInsights:
            return true
        case .idle, .readyToTranscribe, .completed, .failed:
            return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case sourceDescription
        case stage
        case statusMessage
        case lastError
        case lastTranscriptionProvider
        case hasAudio
        case hasTranscript
        case hasInsightArtifact
        case hasMeetingNotes
    }

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        sourceDescription: String,
        stage: SessionStage,
        statusMessage: String,
        lastError: String?,
        lastTranscriptionProvider: String?,
        hasAudio: Bool,
        hasTranscript: Bool,
        hasInsightArtifact: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceDescription = sourceDescription
        self.stage = stage
        self.statusMessage = statusMessage
        self.lastError = lastError
        self.lastTranscriptionProvider = lastTranscriptionProvider
        self.hasAudio = hasAudio
        self.hasTranscript = hasTranscript
        self.hasInsightArtifact = hasInsightArtifact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.sourceDescription = try container.decode(String.self, forKey: .sourceDescription)
        self.stage = try container.decode(SessionStage.self, forKey: .stage)
        self.statusMessage = try container.decode(String.self, forKey: .statusMessage)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.lastTranscriptionProvider = try container.decodeIfPresent(String.self, forKey: .lastTranscriptionProvider)
        self.hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        self.hasTranscript = try container.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false
        let decodedHasInsightArtifact = try container.decodeIfPresent(Bool.self, forKey: .hasInsightArtifact)
        let legacyHasMeetingNotes = try container.decodeIfPresent(Bool.self, forKey: .hasMeetingNotes)
        self.hasInsightArtifact = decodedHasInsightArtifact ?? legacyHasMeetingNotes ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sourceDescription, forKey: .sourceDescription)
        try container.encode(stage, forKey: .stage)
        try container.encode(statusMessage, forKey: .statusMessage)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(lastTranscriptionProvider, forKey: .lastTranscriptionProvider)
        try container.encode(hasAudio, forKey: .hasAudio)
        try container.encode(hasTranscript, forKey: .hasTranscript)
        try container.encode(hasInsightArtifact, forKey: .hasInsightArtifact)
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
    var insightArtifact: InsightArtifact?
    var insightSettings: InsightSettings
    var stage: SessionStage
    var statusMessage: String
    var lastError: String?
    var recordingStartedAt: Date?
    var recordingStoppedAt: Date?
    var lastTranscriptionProvider: String?

    init(
        id: UUID = UUID(),
        sourceDescription: String = "Session",
        insightSettings: InsightSettings = InsightSettings(),
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
        self.insightArtifact = nil
        self.insightSettings = insightSettings
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
        insightArtifact?.hasContent == true
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
            hasInsightArtifact: insightArtifact?.hasContent == true
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case sourceDescription
        case sessionDirectoryName
        case captureMovieFilename
        case mixedAudioFilename
        case mixedAudioDuration
        case transcriptState
        case insightArtifact
        case insightSettings
        case meetingNotes
        case stage
        case statusMessage
        case lastError
        case recordingStartedAt
        case recordingStoppedAt
        case lastTranscriptionProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.sourceDescription = try container.decodeIfPresent(String.self, forKey: .sourceDescription) ?? "Session"
        self.sessionDirectoryName = try container.decodeIfPresent(String.self, forKey: .sessionDirectoryName) ?? id.uuidString
        self.captureMovieFilename = try container.decodeIfPresent(String.self, forKey: .captureMovieFilename)
        self.mixedAudioFilename = try container.decodeIfPresent(String.self, forKey: .mixedAudioFilename)
        self.mixedAudioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .mixedAudioDuration)
        self.transcriptState = try container.decodeIfPresent(TranscriptState.self, forKey: .transcriptState) ?? TranscriptState()

        let decodedArtifact = try container.decodeIfPresent(InsightArtifact.self, forKey: .insightArtifact)
        let legacyNotes = try container.decodeIfPresent(String.self, forKey: .meetingNotes)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedArtifact {
            self.insightArtifact = decodedArtifact.hasContent ? decodedArtifact : nil
        } else if let legacyNotes, !legacyNotes.isEmpty {
            self.insightArtifact = InsightArtifact(
                workflow: .meetingNotes,
                title: InsightWorkflow.meetingNotes.artifactTitle,
                content: legacyNotes,
                generatedAt: updatedAt,
                provider: .openAI,
                modelID: "gpt-5-mini",
                transport: .conversation,
                promptUsed: InsightWorkflow.meetingNotes.promptTemplate
            )
        } else {
            self.insightArtifact = nil
        }

        self.insightSettings = try container.decodeIfPresent(InsightSettings.self, forKey: .insightSettings)
            ?? InsightSettings(selectedWorkflow: insightArtifact?.workflow ?? .fallbackDefault)
        self.stage = try container.decodeIfPresent(SessionStage.self, forKey: .stage) ?? .idle
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage) ?? "Idle"
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.recordingStartedAt = try container.decodeIfPresent(Date.self, forKey: .recordingStartedAt)
        self.recordingStoppedAt = try container.decodeIfPresent(Date.self, forKey: .recordingStoppedAt)
        self.lastTranscriptionProvider = try container.decodeIfPresent(String.self, forKey: .lastTranscriptionProvider)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sourceDescription, forKey: .sourceDescription)
        try container.encode(sessionDirectoryName, forKey: .sessionDirectoryName)
        try container.encodeIfPresent(captureMovieFilename, forKey: .captureMovieFilename)
        try container.encodeIfPresent(mixedAudioFilename, forKey: .mixedAudioFilename)
        try container.encodeIfPresent(mixedAudioDuration, forKey: .mixedAudioDuration)
        try container.encode(transcriptState, forKey: .transcriptState)
        try container.encodeIfPresent(insightArtifact, forKey: .insightArtifact)
        try container.encode(insightSettings, forKey: .insightSettings)
        try container.encode(stage, forKey: .stage)
        try container.encode(statusMessage, forKey: .statusMessage)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(recordingStartedAt, forKey: .recordingStartedAt)
        try container.encodeIfPresent(recordingStoppedAt, forKey: .recordingStoppedAt)
        try container.encodeIfPresent(lastTranscriptionProvider, forKey: .lastTranscriptionProvider)
    }
}
