import XCTest
@testable import TotalRec

@MainActor
final class RecordingRecoveryTests: XCTestCase {
    func testCaptureInspectionDistinguishesMissingEmptyAndCandidateFiles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("capture.mov")
        XCTAssertEqual(RecordingArtifactValidator.inspectCaptureFile(at: captureURL), .missing)

        XCTAssertTrue(FileManager.default.createFile(atPath: captureURL.path, contents: Data()))
        XCTAssertEqual(RecordingArtifactValidator.inspectCaptureFile(at: captureURL), .empty)

        try Data([0x01, 0x02, 0x03]).write(to: captureURL)
        XCTAssertEqual(
            RecordingArtifactValidator.inspectCaptureFile(at: captureURL),
            .candidate(byteCount: 3)
        )
    }

    func testCaptureValidationRejectsMissingAndEmptyFilesBeforeMediaInspection() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureURL = directory.appendingPathComponent("capture.mov")

        do {
            try await RecordingArtifactValidator.validateCapture(at: captureURL)
            XCTFail("Missing capture should fail validation.")
        } catch RecordingRecoveryError.missingCapture {
            // Expected.
        }

        XCTAssertTrue(FileManager.default.createFile(atPath: captureURL.path, contents: Data()))
        do {
            try await RecordingArtifactValidator.validateCapture(at: captureURL)
            XCTFail("Empty capture should fail validation.")
        } catch RecordingRecoveryError.emptyCapture {
            // Expected.
        }
    }

    func testRecoveryErrorsProvideDistinctActionableMessages() throws {
        let messages = try [
            RecordingRecoveryError.missingCapture,
            .emptyCapture,
            .unreadableCapture("Unsupported container"),
            .noAudioTrack,
            .mixdownFailed("Encoder unavailable"),
            .invalidMixedAudio
        ].map { try XCTUnwrap($0.errorDescription) }

        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertTrue(messages[0].contains("missing"))
        XCTAssertTrue(messages[1].contains("empty"))
        XCTAssertTrue(messages[2].contains("could not be read"))
        XCTAssertTrue(messages[3].contains("no audio track"))
        XCTAssertTrue(messages[4].contains("mixdown"))
        XCTAssertTrue(messages[5].contains("invalid or empty audio file"))
    }

    func testEmptyCaptureIsNotOfferedForRecovery() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)

        var session = try store.createSession(sourceDescription: "Empty recording")
        let captureURL = try store.captureMovieURL(for: session)
        XCTAssertTrue(FileManager.default.createFile(atPath: captureURL.path, contents: Data()))
        session.captureMovieFilename = captureURL.lastPathComponent
        session.stage = .failed
        session.statusMessage = "Stop failed"
        session.lastError = "Stop failed"
        try store.save(session)

        let model = makeModel(store: store, finalizer: SuccessfulRecordingFinalizer())
        model.selectSession(session.id)

        XCTAssertEqual(model.rawCaptureFileState, .empty)
        XCTAssertFalse(model.canRetryRecordingFinalization)
        let recovered = await model.retryRecordingFinalization()
        XCTAssertFalse(recovered)
    }

    func testFailedSessionCanRetryFinalizationFromCandidateCapture() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)

        var session = try store.createSession(sourceDescription: "Recoverable recording")
        let captureURL = try store.captureMovieURL(for: session)
        try Data([0x01, 0x02, 0x03]).write(to: captureURL)
        session.captureMovieFilename = captureURL.lastPathComponent
        session.stage = .failed
        session.statusMessage = "Stop failed"
        session.lastError = "Stop failed"
        try store.save(session)

        let model = makeModel(store: store, finalizer: SuccessfulRecordingFinalizer(duration: 42))
        model.selectSession(session.id)

        XCTAssertTrue(model.canRetryRecordingFinalization)
        let recovered = await model.retryRecordingFinalization()
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.activeSession?.stage, .readyToTranscribe)
        XCTAssertEqual(model.activeSession?.mixedAudioFilename, "audio.m4a")
        XCTAssertEqual(model.activeSession?.mixedAudioDuration, 42)
        XCTAssertEqual(model.activeSession?.statusMessage, "Recording saved. Ready to transcribe.")
        XCTAssertNil(model.activeSession?.lastError)
    }

    func testFailedRecoveryKeepsSessionAndRawCaptureAvailable() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)

        var session = try store.createSession(sourceDescription: "Recoverable recording")
        let captureURL = try store.captureMovieURL(for: session)
        try Data([0x01, 0x02, 0x03]).write(to: captureURL)
        session.captureMovieFilename = captureURL.lastPathComponent
        session.stage = .failed
        try store.save(session)

        let model = makeModel(store: store, finalizer: FailingRecordingFinalizer())
        model.selectSession(session.id)

        let recovered = await model.retryRecordingFinalization()
        XCTAssertFalse(recovered)
        XCTAssertEqual(model.activeSession?.stage, .failed)
        XCTAssertEqual(model.rawCaptureFileState, .candidate(byteCount: 3))
        XCTAssertTrue(model.canRetryRecordingFinalization)
        XCTAssertEqual(model.activeSession?.lastError, "Recovery failed: Simulated mixdown failure.")
    }

    func testStopFailureLeavesCandidateCaptureEligibleForRecovery() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)
        let model = AppModel(
            store: store,
            recorder: StopFailingRecorder(),
            recordingFinalizer: SuccessfulRecordingFinalizer(),
            transcriber: RecoveryFakeTranscriber(),
            insightGenerator: RecoveryFakeInsightGenerator(),
            shouldRestoreLatestSession: false
        )

        await model.startRecording(onPermissionNeeded: {})

        let stopped = await model.stopRecording()
        XCTAssertFalse(stopped)
        XCTAssertEqual(model.activeSession?.stage, .failed)
        XCTAssertEqual(model.activeSession?.lastError, "Stop failed: The recorder could not finalize the capture.")
        XCTAssertTrue(model.canRetryRecordingFinalization)
    }

    private func makeModel(
        store: SessionStore,
        finalizer: any RecordingFinalizing
    ) -> AppModel {
        AppModel(
            store: store,
            recorder: StopFailingRecorder(),
            recordingFinalizer: finalizer,
            transcriber: RecoveryFakeTranscriber(),
            insightGenerator: RecoveryFakeInsightGenerator(),
            shouldRestoreLatestSession: false
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotalRec-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct SuccessfulRecordingFinalizer: RecordingFinalizing {
    var duration: TimeInterval? = 12

    func finalizeCapture(
        at sourceURL: URL,
        outputURL: URL,
        systemGain: Float,
        micGain: Float
    ) async throws -> TimeInterval? {
        try Data([0x01]).write(to: outputURL)
        return duration
    }
}

private struct FailingRecordingFinalizer: RecordingFinalizing {
    func finalizeCapture(
        at sourceURL: URL,
        outputURL: URL,
        systemGain: Float,
        micGain: Float
    ) async throws -> TimeInterval? {
        throw RecordingRecoveryTestError.mixdownFailed
    }
}

private final class StopFailingRecorder: AudioRecording {
    private var captureURL: URL?

    func startRecording(to url: URL, onPermissionNeeded: @escaping () -> Void) async throws {
        captureURL = url
        try Data([0x01, 0x02, 0x03]).write(to: url)
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        completion(.failure(RecordingRecoveryTestError.recorderFinalizationFailed))
    }
}

private final class RecoveryFakeTranscriber: AudioTranscribing {
    func transcribeFile(
        at url: URL,
        localeID: String,
        onDevicePreferred: Bool,
        onProgress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.success(""))
    }
}

private struct RecoveryFakeInsightGenerator: InsightGenerating {
    func generateArtifact(
        from transcript: TranscriptState,
        settings: InsightSettings,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> InsightArtifact {
        throw RecordingRecoveryTestError.unusedDependency
    }
}

private enum RecordingRecoveryTestError: LocalizedError {
    case mixdownFailed
    case recorderFinalizationFailed
    case unusedDependency

    var errorDescription: String? {
        switch self {
        case .mixdownFailed:
            return "Simulated mixdown failure."
        case .recorderFinalizationFailed:
            return "The recorder could not finalize the capture."
        case .unusedDependency:
            return "This dependency should not be called by recording recovery tests."
        }
    }
}
