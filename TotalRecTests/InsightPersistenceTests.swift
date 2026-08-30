import XCTest
@testable import TotalRec

final class InsightPersistenceTests: XCTestCase {
    func testAPIKeyMemoryCacheReadsEachAccountOnlyOnce() {
        var cache = APIKeyMemoryCache()
        var openAIReads = 0
        var sambaNovaReads = 0

        let firstOpenAIValue = cache.value(for: "openai") {
            openAIReads += 1
            return "openai-example"
        }
        let secondOpenAIValue = cache.value(for: "openai") {
            openAIReads += 1
            return "unexpected"
        }
        let firstSambaNovaValue = cache.value(for: "sambanova") {
            sambaNovaReads += 1
            return "sambanova-example"
        }

        XCTAssertEqual(firstOpenAIValue, "openai-example")
        XCTAssertEqual(secondOpenAIValue, "openai-example")
        XCTAssertEqual(firstSambaNovaValue, "sambanova-example")
        XCTAssertEqual(openAIReads, 1)
        XCTAssertEqual(sambaNovaReads, 1)
    }

    func testAPIKeyMemoryCacheAlsoCachesMissingCredentials() {
        var cache = APIKeyMemoryCache()
        var reads = 0

        XCTAssertNil(cache.value(for: "missing") {
            reads += 1
            return nil
        })
        XCTAssertNil(cache.value(for: "missing") {
            reads += 1
            return "unexpected"
        })

        XCTAssertTrue(cache.isLoaded("missing"))
        XCTAssertEqual(reads, 1)
    }

    func testAPIKeyMemoryCacheReflectsSuccessfulCredentialChanges() {
        var cache = APIKeyMemoryCache()
        cache.store("old-value", for: "openai")
        cache.store("new-value", for: "openai")

        XCTAssertTrue(cache.isLoaded("openai"))
        XCTAssertEqual(cache.cachedValue(for: "openai"), "new-value")
    }

    func testLegacyMeetingNotesDecodeMigratesToInsightArtifact() throws {
        let now = Date()
        let legacySession = LegacyRecordingSession(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            sourceDescription: "Legacy Session",
            sessionDirectoryName: "legacy-session",
            captureMovieFilename: nil,
            mixedAudioFilename: nil,
            mixedAudioDuration: nil,
            transcriptState: TranscriptState(rawText: "Speaker 1: Hello"),
            meetingNotes: "# Meeting Summary\n- Legacy notes",
            stage: .completed,
            statusMessage: "Done",
            lastError: nil,
            recordingStartedAt: nil,
            recordingStoppedAt: nil,
            lastTranscriptionProvider: "openai"
        )

        let data = try JSONEncoder().encode(legacySession)
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: data)

        XCTAssertEqual(decoded.insightArtifact?.workflow, .meetingNotes)
        XCTAssertEqual(decoded.insightArtifact?.content, "# Meeting Summary\n- Legacy notes")
        XCTAssertEqual(decoded.insightArtifact?.provider, .openAI)
        XCTAssertEqual(decoded.insightArtifact?.transport, .conversation)
        XCTAssertEqual(decoded.insightSettings.selectedWorkflow, .meetingNotes)
    }

    func testSessionStoreRoundTripPersistsInsightArtifactAndSettings() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = SessionStore(baseDirectoryURL: tempDirectory)
        var session = try store.createSession(
            sourceDescription: "Podcast Draft",
            insightSettings: InsightSettings(
                selectedWorkflow: .podcastSummary,
                useCustomPrompt: true,
                customPrompt: "Summarize this episode.\n\n{{TRANSCRIPT}}"
            )
        )
        session.transcriptState = TranscriptState(rawText: "Speaker 1: Welcome back to the show.")
        session.insightArtifact = InsightArtifact(
            workflow: .podcastSummary,
            title: "Podcast Summary",
            content: "# Episode Summary\n- A concise recap",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .openAI,
            modelID: "gpt-5-mini",
            transport: .responses,
            promptUsed: "Summarize this episode.\n\n{{TRANSCRIPT}}"
        )
        try store.save(session)

        let reloaded = try XCTUnwrap(store.loadSession(id: session.id))
        XCTAssertEqual(reloaded.insightSettings.selectedWorkflow, .podcastSummary)
        XCTAssertTrue(reloaded.insightSettings.useCustomPrompt)
        XCTAssertEqual(reloaded.insightSettings.customPrompt, "Summarize this episode.\n\n{{TRANSCRIPT}}")
        XCTAssertEqual(reloaded.insightArtifact?.workflow, .podcastSummary)
        XCTAssertEqual(reloaded.insightArtifact?.provider, .openAI)
        XCTAssertEqual(reloaded.insightArtifact?.transport, .responses)

        let summaries = try store.listRecentSessionSummaries()
        XCTAssertEqual(summaries.first?.hasInsightArtifact, true)
    }

    func testAIConfigurationDefaultsInsightWorkflowWhenMissing() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "defaultProvider": "openai",
            "nameSuggestionProvider": NameSuggestionProvider.buildDefault.rawValue
        ])

        let configuration = try JSONDecoder().decode(AIConfiguration.self, from: data)

        XCTAssertEqual(configuration.normalizedInsightWorkflow, .meetingNotes)
    }

    func testAIConfigurationDefaultsProviderSelectionsWhenMissing() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "defaultProvider": "openai",
            "nameSuggestionProvider": NameSuggestionProvider.buildDefault.rawValue
        ])

        let configuration = try JSONDecoder().decode(AIConfiguration.self, from: data)

        XCTAssertEqual(configuration.normalizedInsightProvider, .openAI)
        XCTAssertEqual(configuration.defaultInsightModelID, LLMProvider.openAI.defaultModelID(for: .insights))
        XCTAssertEqual(configuration.nameSuggestionModelID, LLMProvider.openAI.defaultModelID(for: .nameSuggestions))
    }

    func testSettingsCategoriesCoverProviderTranscriptionAndInsightWorkflows() {
        XCTAssertEqual(
            TotalRecSettingsCategory.allCases,
            [.providers, .transcription, .insights]
        )
        XCTAssertEqual(
            TotalRecSettingsCategory.allCases.map(\.title),
            ["Providers", "Transcription", "Insights"]
        )
        XCTAssertEqual(Set(TotalRecSettingsCategory.allCases.map(\.systemImage)).count, 3)
        XCTAssertTrue(TotalRecSettingsCategory.allCases.allSatisfy { !$0.subtitle.isEmpty })
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct LegacyRecordingSession: Codable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let sourceDescription: String
    let sessionDirectoryName: String
    let captureMovieFilename: String?
    let mixedAudioFilename: String?
    let mixedAudioDuration: TimeInterval?
    let transcriptState: TranscriptState
    let meetingNotes: String
    let stage: SessionStage
    let statusMessage: String
    let lastError: String?
    let recordingStartedAt: Date?
    let recordingStoppedAt: Date?
    let lastTranscriptionProvider: String?
}
