import XCTest
@testable import TotalRec

@MainActor
final class AppModelInsightTests: XCTestCase {
    func testSuccessfulInsightRunReplacesArtifactAndClearsTransientState() async throws {
        let store = SessionStore(baseDirectoryURL: makeTemporaryDirectory())
        defer { cleanup(store) }

        var session = try store.createSession(
            sourceDescription: "Session",
            insightSettings: InsightSettings(selectedWorkflow: .podcastSummary)
        )
        session.transcriptState = TranscriptState(rawText: "Speaker 1: Welcome back.")
        session.insightArtifact = InsightArtifact(
            workflow: .meetingNotes,
            title: "Meeting Notes",
            content: "Old artifact",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .openAI,
            modelID: "gpt-5-mini",
            transport: .conversation,
            promptUsed: InsightWorkflow.meetingNotes.promptTemplate
        )
        try store.save(session)

        let generator = MockInsightGenerator(
            result: .success(
                InsightArtifact(
                    workflow: .podcastSummary,
                    title: "Podcast Summary",
                    content: "New artifact",
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_123),
                    provider: .openAI,
                    modelID: "gpt-5-mini",
                    transport: .responses,
                    promptUsed: InsightWorkflow.podcastSummary.promptTemplate
                )
            ),
            events: [.started, .textDelta("Streaming"), .completed("New artifact")]
        )
        let model = AppModel(
            store: store,
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(),
            insightGenerator: generator,
            defaultInsightSettingsProvider: { InsightSettings(selectedWorkflow: .podcastSummary) },
            shouldRestoreLatestSession: false
        )
        model.selectSession(session.id)

        try await model.generateInsightArtifact()

        XCTAssertEqual(model.insightArtifact?.workflow, .podcastSummary)
        XCTAssertEqual(model.insightArtifact?.content, "New artifact")
        XCTAssertEqual(model.insightStreamingText, "")
        XCTAssertNil(model.insightRunStartedAt)
        XCTAssertNil(model.insightRunError)
        XCTAssertEqual(model.activeSession?.stage, .completed)
    }

    func testFailedInsightRunPreservesSavedArtifactAndLeavesPartialOutputUnsaved() async {
        let store = SessionStore(baseDirectoryURL: makeTemporaryDirectory())
        defer { cleanup(store) }

        var session = try! store.createSession(
            sourceDescription: "Session",
            insightSettings: InsightSettings(selectedWorkflow: .meetingNotes)
        )
        session.transcriptState = TranscriptState(rawText: "Speaker 1: Hello.")
        session.insightArtifact = InsightArtifact(
            workflow: .meetingNotes,
            title: "Meeting Notes",
            content: "Saved artifact",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .openAI,
            modelID: "gpt-5-mini",
            transport: .conversation,
            promptUsed: InsightWorkflow.meetingNotes.promptTemplate
        )
        try! store.save(session)

        let generator = MockInsightGenerator(
            result: .failure(MockError.failed),
            events: [.started, .textDelta("Partial output"), .failed(MockError.failed.localizedDescription)]
        )
        let model = AppModel(
            store: store,
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(),
            insightGenerator: generator,
            defaultInsightSettingsProvider: { InsightSettings(selectedWorkflow: .meetingNotes) },
            shouldRestoreLatestSession: false
        )
        model.selectSession(session.id)

        do {
            try await model.generateInsightArtifact()
            XCTFail("Expected insight generation to fail.")
        } catch {
            XCTAssertEqual(error.localizedDescription, MockError.failed.localizedDescription)
        }

        XCTAssertEqual(model.insightArtifact?.content, "Saved artifact")
        XCTAssertEqual(model.insightStreamingText, "Partial output")
        XCTAssertEqual(model.insightRunError, MockError.failed.localizedDescription)
        XCTAssertNil(model.insightRunStartedAt)
        XCTAssertEqual(model.activeSession?.stage, .completed)
    }

    func testNewSessionUsesDefaultInsightWorkflowSeed() async throws {
        let store = SessionStore(baseDirectoryURL: makeTemporaryDirectory())
        defer { cleanup(store) }

        let model = AppModel(
            store: store,
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(),
            insightGenerator: MockInsightGenerator(
                result: .success(
                    InsightArtifact(
                        workflow: .podcastSummary,
                        title: "Podcast Summary",
                        content: "Artifact",
                        generatedAt: Date(),
                        provider: .openAI,
                        modelID: "gpt-5-mini",
                        transport: .responses,
                        promptUsed: InsightWorkflow.podcastSummary.promptTemplate
                    )
                )
            ),
            defaultInsightSettingsProvider: { InsightSettings(selectedWorkflow: .podcastSummary) },
            shouldRestoreLatestSession: false
        )

        await model.startRecording(onPermissionNeeded: {})

        XCTAssertEqual(model.activeSession?.insightSettings.selectedWorkflow, .podcastSummary)
    }

    func testStoppingInsightRunCancelsTaskWithoutReplacingSavedArtifact() async throws {
        let store = SessionStore(baseDirectoryURL: makeTemporaryDirectory())
        defer { cleanup(store) }

        var session = try store.createSession(
            sourceDescription: "Session",
            insightSettings: InsightSettings(selectedWorkflow: .podcastSummary)
        )
        session.transcriptState = TranscriptState(rawText: "Speaker 1: Welcome back.")
        session.insightArtifact = InsightArtifact(
            workflow: .meetingNotes,
            title: "Meeting Notes",
            content: "Saved artifact",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .openAI,
            modelID: "gpt-5-mini",
            transport: .conversation,
            promptUsed: InsightWorkflow.meetingNotes.promptTemplate
        )
        try store.save(session)

        let model = AppModel(
            store: store,
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(),
            insightGenerator: SlowCancellableInsightGenerator(),
            defaultInsightSettingsProvider: { InsightSettings(selectedWorkflow: .podcastSummary) },
            shouldRestoreLatestSession: false
        )
        model.selectSession(session.id)

        model.startInsightArtifactGeneration()

        for _ in 0..<20 {
            if model.isGeneratingInsightArtifact {
                break
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(model.isGeneratingInsightArtifact)
        XCTAssertEqual(model.insightStreamingText, "Partial output")

        model.stopInsightArtifactGeneration()

        for _ in 0..<50 {
            if !model.isGeneratingInsightArtifact {
                break
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(model.isGeneratingInsightArtifact)
        XCTAssertFalse(model.isStoppingInsightArtifact)
        XCTAssertEqual(model.insightArtifact?.content, "Saved artifact")
        XCTAssertEqual(model.insightStreamingText, "Partial output")
        XCTAssertNil(model.insightRunError)
        XCTAssertNil(model.insightRunStartedAt)
        XCTAssertEqual(model.activeSession?.statusMessage, "Insight generation stopped.")
        XCTAssertNil(model.activeSession?.lastError)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ store: SessionStore) {
        if let session = try? store.loadLatestSession() {
            let directory = store.sessionDirectoryURL(for: session)
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
    }
}

private final class FakeRecorder: AudioRecording {
    private var currentURL: URL?

    func startRecording(to url: URL, onPermissionNeeded: @escaping () -> Void) async throws {
        currentURL = url
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        completion(.success(currentURL ?? URL(fileURLWithPath: "/tmp/fake.mov")))
    }
}

private final class FakeTranscriber: AudioTranscribing {
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

private struct MockInsightGenerator: InsightGenerating {
    let result: Result<InsightArtifact, Error>
    var events: [TextGenerationEvent] = []

    func generateArtifact(
        from transcript: TranscriptState,
        settings: InsightSettings,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> InsightArtifact {
        for event in events {
            onEvent(event)
        }
        return try result.get()
    }
}

private struct SlowCancellableInsightGenerator: InsightGenerating {
    func generateArtifact(
        from transcript: TranscriptState,
        settings: InsightSettings,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> InsightArtifact {
        onEvent(.started)
        onEvent(.textDelta("Partial output"))
        try await Task.sleep(nanoseconds: 30_000_000_000)

        return InsightArtifact(
            workflow: settings.selectedWorkflow,
            title: settings.selectedWorkflow.artifactTitle,
            content: "Completed artifact",
            generatedAt: Date(),
            provider: .openAI,
            modelID: "gpt-5-mini",
            transport: .responses,
            promptUsed: settings.effectivePrompt
        )
    }
}

private enum MockError: LocalizedError {
    case failed

    var errorDescription: String? {
        switch self {
        case .failed:
            return "Mock insight generation failed."
        }
    }
}
