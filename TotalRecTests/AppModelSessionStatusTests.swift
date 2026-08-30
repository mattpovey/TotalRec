import XCTest
@testable import TotalRec

@MainActor
final class AppModelSessionStatusTests: XCTestCase {
    func testTransientNoticeDoesNotMutateOrReorderSessionHistory() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)

        var olderSession = try store.createSession(sourceDescription: "Older session")
        olderSession.updatedAt = Date(timeIntervalSince1970: 1_000)
        olderSession.statusMessage = "Transcription complete."
        try store.save(olderSession)

        var newerSession = try store.createSession(sourceDescription: "Newer session")
        newerSession.updatedAt = Date(timeIntervalSince1970: 2_000)
        newerSession.statusMessage = "Recording saved."
        try store.save(newerSession)

        let model = makeModel(store: store)
        model.selectSession(olderSession.id)
        model.showNotice(
            "Transcript copied to clipboard.",
            style: .success,
            autoDismissAfter: nil
        )

        XCTAssertEqual(model.transientNotice?.message, "Transcript copied to clipboard.")
        XCTAssertEqual(model.transientNotice?.style, .success)
        XCTAssertEqual(model.activeSession?.updatedAt, olderSession.updatedAt)
        XCTAssertEqual(model.activeSession?.statusMessage, "Transcription complete.")
        XCTAssertEqual(model.recentSessionSummaries.map(\.id), [newerSession.id, olderSession.id])

        let persistedSession = try XCTUnwrap(store.loadSession(id: olderSession.id))
        XCTAssertEqual(persistedSession.updatedAt, olderSession.updatedAt)
        XCTAssertEqual(persistedSession.statusMessage, "Transcription complete.")
    }

    func testSwitchingSessionsClearsTransientNoticeAndKeepsDurableStatus() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)
        let first = try store.createSession(sourceDescription: "First")
        let second = try store.createSession(sourceDescription: "Second")
        let model = makeModel(store: store)

        model.selectSession(first.id)
        model.showNotice("Copied", style: .success, autoDismissAfter: nil)
        model.selectSession(second.id)

        XCTAssertNil(model.transientNotice)
        XCTAssertEqual(model.activeSession?.id, second.id)
        XCTAssertEqual(model.activeSession?.statusMessage, second.statusMessage)
    }

    func testMaterialTranscriptEditStillAdvancesPersistentModificationDate() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)

        var session = try store.createSession(sourceDescription: "Editable")
        session.updatedAt = Date(timeIntervalSince1970: 1_000)
        session.stage = .readyToTranscribe
        try store.save(session)

        let model = makeModel(store: store)
        model.selectSession(session.id)
        model.updateTranscript(TranscriptState(rawText: "Material transcript edit"))

        let updatedAt = try XCTUnwrap(model.activeSession?.updatedAt)
        XCTAssertGreaterThan(updatedAt, session.updatedAt)
        XCTAssertEqual(model.activeSession?.statusMessage, "Transcript updated.")

        let persistedSession = try XCTUnwrap(store.loadSession(id: session.id))
        XCTAssertEqual(persistedSession.updatedAt, updatedAt)
        XCTAssertEqual(persistedSession.statusMessage, "Transcript updated.")
    }

    func testRenamingSessionPersistsTitleWithoutReplacingSourceOrStatus() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)

        var session = try store.createSession(sourceDescription: "Long imported recording filename.m4a")
        session.statusMessage = "Transcription complete."
        try store.save(session)
        let model = makeModel(store: store)
        model.selectSession(session.id)

        XCTAssertTrue(model.renameSession(session.id, to: "  Weekly   editorial\nmeeting  "))

        XCTAssertEqual(model.activeSession?.title, "Weekly editorial meeting")
        XCTAssertEqual(model.activeSession?.displayTitle, "Weekly editorial meeting")
        XCTAssertEqual(model.activeSession?.sourceDescription, "Long imported recording filename.m4a")
        XCTAssertEqual(model.activeSession?.statusMessage, "Transcription complete.")

        let persistedSession = try XCTUnwrap(store.loadSession(id: session.id))
        XCTAssertEqual(persistedSession.title, "Weekly editorial meeting")
        XCTAssertEqual(persistedSession.sourceDescription, "Long imported recording filename.m4a")
        XCTAssertEqual(persistedSession.statusMessage, "Transcription complete.")
    }

    func testRenamingBackgroundSessionDoesNotChangeCurrentSession() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(baseDirectoryURL: directory)
        let backgroundSession = try store.createSession(sourceDescription: "Background")
        let activeSession = try store.createSession(sourceDescription: "Active")
        let model = makeModel(store: store)
        model.selectSession(activeSession.id)

        XCTAssertTrue(model.renameSession(backgroundSession.id, to: "Reference interview"))

        XCTAssertEqual(model.activeSession?.id, activeSession.id)
        XCTAssertEqual(try store.loadLatestSession()?.id, activeSession.id)
        XCTAssertEqual(
            model.recentSessionSummaries.first(where: { $0.id == backgroundSession.id })?.displayTitle,
            "Reference interview"
        )
    }

    private func makeModel(store: SessionStore) -> AppModel {
        AppModel(
            store: store,
            recorder: SessionStatusFakeRecorder(),
            transcriber: SessionStatusFakeTranscriber(),
            insightGenerator: SessionStatusFakeInsightGenerator(),
            shouldRestoreLatestSession: false
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotalRec-SessionStatusTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class SessionStatusFakeRecorder: AudioRecording {
    func startRecording(to url: URL, onPermissionNeeded: @escaping () -> Void) async throws {}

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        completion(.failure(CancellationError()))
    }
}

private final class SessionStatusFakeTranscriber: AudioTranscribing {
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

private struct SessionStatusFakeInsightGenerator: InsightGenerating {
    func generateArtifact(
        from transcript: TranscriptState,
        settings: InsightSettings,
        onEvent: @escaping @MainActor (TextGenerationEvent) -> Void
    ) async throws -> InsightArtifact {
        throw CancellationError()
    }
}
