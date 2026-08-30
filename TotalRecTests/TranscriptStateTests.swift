import XCTest
@testable import TotalRec

final class TranscriptStateTests: XCTestCase {
    func testWorkspaceSummaryUsesClipCountForTimedTranscriptWithoutSpeakerLabels() {
        let transcript = TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: nil, text: "First", start: 0, end: 2),
                TranscriptSegment(speakerLabel: nil, text: "Second", start: 2, end: 4),
                TranscriptSegment(speakerLabel: nil, text: "Third", start: 4, end: 6)
            ]
        )

        XCTAssertEqual(transcript.workspaceSummary, "3 clips")
    }

    func testWorkspaceSummaryPrefersDiarizedSpeakerCount() {
        let transcript = TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: "SPEAKER_00", text: "First", start: 0, end: 2),
                TranscriptSegment(speakerLabel: "SPEAKER_01", text: "Second", start: 2, end: 4),
                TranscriptSegment(speakerLabel: "SPEAKER_00", text: "Third", start: 4, end: 6)
            ]
        )

        XCTAssertEqual(transcript.workspaceSummary, "2 speakers")
    }

    func testWorkspaceSummaryDescribesRawTranscriptWithoutInventingSpeakers() {
        XCTAssertEqual(TranscriptState(rawText: "Raw transcript").workspaceSummary, "Transcript ready")
        XCTAssertNil(TranscriptState().workspaceSummary)
    }

    func testUpdateTextUpdatesOnlyTargetSegment() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "World", start: 1, end: 2)
        var transcript = TranscriptState(segments: [first, second])

        XCTAssertTrue(transcript.updateText("Updated", forSegmentID: second.id))

        XCTAssertEqual(transcript.segment(withID: first.id)?.text, "Hello")
        XCTAssertEqual(transcript.segment(withID: second.id)?.text, "Updated")
        XCTAssertEqual(transcript.rawText, "A: Hello\nB: Updated")
    }

    func testUpdateTextRejectsWhitespaceOnlyEdits() {
        let segment = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 0, end: 1)
        var transcript = TranscriptState(segments: [segment])

        XCTAssertFalse(transcript.updateText("   ", forSegmentID: segment.id))
        XCTAssertEqual(transcript.segment(withID: segment.id)?.text, "Hello")
    }

    func testUpdateSpeakerLabelUpdatesOnlyTargetSegment() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "World", start: 1, end: 2)
        var transcript = TranscriptState(
            segments: [first, second],
            speakerAliases: ["A": "Alice", "B": "Bob"]
        )

        XCTAssertTrue(transcript.updateSpeakerLabel("A", forSegmentID: second.id))

        XCTAssertEqual(transcript.segment(withID: first.id)?.speakerLabel, "A")
        XCTAssertEqual(transcript.segment(withID: second.id)?.speakerLabel, "A")
    }

    func testUpdateSpeakerLabelPrunesOrphanedAliases() {
        let first = TranscriptSegment(speakerLabel: "A", text: "One", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "Two", start: 1, end: 2)
        var transcript = TranscriptState(
            segments: [first, second],
            speakerAliases: ["A": "Alice", "B": "Bob"]
        )

        XCTAssertTrue(transcript.updateSpeakerLabel("A", forSegmentID: second.id))

        XCTAssertEqual(transcript.orderedSpeakerLabels, ["A"])
        XCTAssertEqual(transcript.speakerAliases, ["A": "Alice"])
        XCTAssertEqual(transcript.alias(for: "A"), "Alice")
    }

    func testUpdateSpeakerLabelKeepsOtherAliasesStable() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Alpha", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "Beta", start: 1, end: 2)
        let third = TranscriptSegment(speakerLabel: "C", text: "Gamma", start: 2, end: 3)
        var transcript = TranscriptState(
            segments: [first, second, third],
            speakerAliases: ["A": "Alice", "B": "Bob", "C": "Carol"]
        )

        XCTAssertTrue(transcript.updateSpeakerLabel("A", forSegmentID: second.id))

        XCTAssertEqual(transcript.alias(for: "A"), "Alice")
        XCTAssertEqual(transcript.alias(for: "C"), "Carol")
        XCTAssertEqual(transcript.speakerAliases["C"], "Carol")
    }

    func testMergeSpeakerLabelReassignsAllSegmentsAndPrunesSourceAlias() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Alpha", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "Beta", start: 1, end: 2)
        let third = TranscriptSegment(speakerLabel: "B", text: "Gamma", start: 2, end: 3)
        var transcript = TranscriptState(
            segments: [first, second, third],
            speakerAliases: ["A": "Tom Holland", "B": "Thomas"]
        )

        XCTAssertTrue(transcript.mergeSpeakerLabel("B", into: "A"))

        XCTAssertEqual(transcript.orderedSpeakerLabels, ["A"])
        XCTAssertEqual(transcript.segment(withID: second.id)?.speakerLabel, "A")
        XCTAssertEqual(transcript.segment(withID: third.id)?.speakerLabel, "A")
        XCTAssertEqual(transcript.speakerAliases, ["A": "Tom Holland"])
        XCTAssertEqual(transcript.rawText, "Tom Holland: Alpha\nTom Holland: Beta\nTom Holland: Gamma")
    }

    func testSpeakerLabelMatchingAliasFindsExistingSpeakerCaseInsensitively() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Alpha", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "Beta", start: 1, end: 2)
        let transcript = TranscriptState(
            segments: [first, second],
            speakerAliases: ["A": "Tom Holland", "B": "Dominic"]
        )

        XCTAssertEqual(
            transcript.speakerLabel(matchingAlias: " tom holland ", excluding: "B"),
            "A"
        )
        XCTAssertNil(transcript.speakerLabel(matchingAlias: "Tom Holland", excluding: "A"))
    }

    func testPlaybackRangePrefersExplicitEnd() {
        let segment = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 5, end: 7)
        let transcript = TranscriptState(segments: [segment])

        let range = transcript.playbackRange(forSegmentID: segment.id, audioDuration: 20)

        XCTAssertEqual(range, TranscriptState.PlaybackRange(start: 5, end: 7))
    }

    func testPlaybackRangeFallsBackToNextSegmentStart() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 5, end: nil)
        let second = TranscriptSegment(speakerLabel: "B", text: "World", start: 8, end: 9)
        let transcript = TranscriptState(segments: [first, second])

        let range = transcript.playbackRange(forSegmentID: first.id, audioDuration: 20)

        XCTAssertEqual(range, TranscriptState.PlaybackRange(start: 5, end: 8))
    }

    func testPlaybackRangeFallsBackToTwoSecondsWhenNeeded() {
        let segment = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 5, end: nil)
        let transcript = TranscriptState(segments: [segment])

        let range = transcript.playbackRange(forSegmentID: segment.id, audioDuration: 6)

        XCTAssertEqual(range, TranscriptState.PlaybackRange(start: 5, end: 6))
    }

    func testUpdateRawTextUpdatesOnlyRawText() {
        var transcript = TranscriptState(rawText: "Original transcript")

        transcript.updateRawText("Revised transcript")

        XCTAssertEqual(transcript.rawText, "Revised transcript")
        XCTAssertTrue(transcript.segments.isEmpty)
    }

    func testLiteralMatchCountCountsAcrossSegments() {
        let transcript = TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: "A", text: "Rome met Rome.", start: 0, end: 1),
                TranscriptSegment(speakerLabel: "B", text: "Rome again.", start: 1, end: 2)
            ]
        )

        XCTAssertEqual(transcript.literalMatchCount(for: "Rome"), 3)
        XCTAssertEqual(transcript.literalMatchCount(for: "rom"), 0)
    }

    func testReplaceAllLiteralMatchesUpdatesTextWithoutChangingMetadata() {
        let first = TranscriptSegment(speakerLabel: "A", text: "Rome met Rome.", start: 0, end: 1)
        let second = TranscriptSegment(speakerLabel: "B", text: "Rome again.", start: 1, end: 3)
        var transcript = TranscriptState(segments: [first, second], speakerAliases: ["A": "Alice", "B": "Bob"])

        let replacements = transcript.replaceAllLiteralMatches(of: "Rome", with: "London")

        XCTAssertEqual(replacements, 3)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segment(withID: first.id)?.speakerLabel, "A")
        XCTAssertEqual(transcript.segment(withID: second.id)?.speakerLabel, "B")
        XCTAssertEqual(transcript.segment(withID: first.id)?.start, 0)
        XCTAssertEqual(transcript.segment(withID: first.id)?.end, 1)
        XCTAssertEqual(transcript.segment(withID: second.id)?.start, 1)
        XCTAssertEqual(transcript.segment(withID: second.id)?.end, 3)
        XCTAssertEqual(transcript.segment(withID: first.id)?.text, "London met London.")
        XCTAssertEqual(transcript.segment(withID: second.id)?.text, "London again.")
        XCTAssertEqual(transcript.rawText, "Alice: London met London.\nBob: London again.")
    }

    func testMarkdownExportIncludesAliasSectionAndTranscriptBody() {
        let transcript = TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: "SPEAKER_00", text: "Hello there.", start: 0, end: 1),
                TranscriptSegment(speakerLabel: "SPEAKER_01", text: "General Kenobi.", start: 1, end: 2)
            ],
            speakerAliases: [
                "SPEAKER_00": "Alice",
                "SPEAKER_01": "Bob"
            ]
        )

        let markdown = TranscriptRenderer(transcript: transcript).markdown()

        XCTAssertTrue(markdown.contains("# Speaker Aliases"))
        XCTAssertTrue(markdown.contains("- `SPEAKER_00`: Alice"))
        XCTAssertTrue(markdown.contains("# Transcript"))
        XCTAssertTrue(markdown.contains("**Alice:** Hello there."))
        XCTAssertTrue(markdown.contains("**Bob:** General Kenobi."))
    }

    func testMarkdownExportFallsBackToRawTextWhenNoSegmentsExist() {
        let transcript = TranscriptState(rawText: "Standalone transcript text.")

        let markdown = TranscriptRenderer(transcript: transcript).markdown()

        XCTAssertEqual(markdown, "# Transcript\n\nStandalone transcript text.")
    }

    func testJSONExportUsesStructuredSpeakerTimecodeAndTextFields() throws {
        let transcript = TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: "SPEAKER_00", text: "Hello there.", start: 0, end: 1),
                TranscriptSegment(speakerLabel: "SPEAKER_01", text: "General Kenobi.", start: 1, end: 2)
            ],
            speakerAliases: [
                "SPEAKER_00": "Alice",
                "SPEAKER_01": "Bob"
            ]
        )

        let data = try TranscriptRenderer(transcript: transcript).json()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speakers = try XCTUnwrap(payload["speakers"] as? [[String: Any]])
        let segments = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        let firstSegment = try XCTUnwrap(segments.first)
        let firstSpeaker = try XCTUnwrap(firstSegment["speaker"] as? [String: Any])
        let firstTimecode = try XCTUnwrap(firstSegment["timecode"] as? [String: Any])

        XCTAssertEqual(payload["schemaVersion"] as? Int, 2)
        XCTAssertNil(payload["combinedText"])
        XCTAssertEqual(speakers.count, 2)
        XCTAssertEqual(speakers.first?["id"] as? String, "SPEAKER_00")
        XCTAssertEqual(speakers.first?["displayName"] as? String, "Alice")
        XCTAssertEqual(firstSpeaker["id"] as? String, "SPEAKER_00")
        XCTAssertEqual(firstSpeaker["displayName"] as? String, "Alice")
        XCTAssertEqual(firstTimecode["start"] as? Double, 0)
        XCTAssertEqual(firstTimecode["end"] as? Double, 1)
        XCTAssertEqual(firstSegment["text"] as? String, "Hello there.")
    }

    func testJSONExportFallsBackToSingleRawTextSegment() throws {
        let transcript = TranscriptState(rawText: "Standalone transcript text.")

        let data = try TranscriptRenderer(transcript: transcript).json()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        let firstSegment = try XCTUnwrap(segments.first)

        XCTAssertEqual((payload["speakers"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(firstSegment["text"] as? String, "Standalone transcript text.")
        XCTAssertNil(firstSegment["speaker"])
        XCTAssertNil(firstSegment["timecode"])
    }
}
