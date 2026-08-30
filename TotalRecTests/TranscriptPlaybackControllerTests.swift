import XCTest
@testable import TotalRec

@MainActor
final class TranscriptPlaybackControllerTests: XCTestCase {
    func testSelectingSegmentSeeksAndStartsPlayback() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: transcript
        )
        controller.selectAndPlay(segmentID: transcript.segments[0].id)

        XCTAssertEqual(controller.selectedSegmentID, transcript.segments[0].id)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(engine.loadedURL?.path, "/tmp/audio.m4a")
        XCTAssertEqual(engine.seekHistory.last ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(controller.clipRange, TranscriptState.PlaybackRange(start: 0, end: 1))
    }

    func testPlaybackStopsAtClipEnd() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: transcript
        )
        controller.selectAndPlay(segmentID: transcript.segments[0].id)
        engine.advance(to: 1.05)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.activeSegmentID)
        XCTAssertNil(controller.clipRange)
        XCTAssertGreaterThanOrEqual(engine.pauseCount, 1)
        XCTAssertEqual(engine.seekHistory.last ?? -1, 1, accuracy: 0.001)
    }

    func testContextPlaybackClampsToAudioBounds() {
        let engine = FakeAudioPlaybackEngine(duration: 5)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let segment = TranscriptSegment(speakerLabel: "A", text: "Hello", start: 1, end: 4)
        let transcript = TranscriptState(segments: [segment])

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 5,
            transcript: transcript
        )
        controller.selectSegment(segment.id)
        controller.playSelectedClipWithContext()

        XCTAssertEqual(controller.clipRange, TranscriptState.PlaybackRange(start: 0, end: 5))
        XCTAssertEqual(engine.seekHistory.last ?? -1, 0, accuracy: 0.001)
    }

    func testSessionChangeStopsPlaybackAndClearsSelection() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio-a.m4a"),
            audioDuration: 12,
            transcript: transcript
        )
        controller.selectAndPlay(segmentID: transcript.segments[1].id)

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio-b.m4a"),
            audioDuration: 9,
            transcript: transcript
        )

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.selectedSegmentID)
        XCTAssertNil(controller.activeSegmentID)
        XCTAssertEqual(engine.loadedURL?.path, "/tmp/audio-b.m4a")
    }

    func testTranscriptReplacementStopsPlaybackAndClearsSelection() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: transcript
        )
        controller.selectAndPlay(segmentID: transcript.segments[0].id)

        let replacement = TranscriptState(
            segments: [TranscriptSegment(speakerLabel: "A", text: "Replacement", start: 0, end: 2)]
        )
        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: replacement
        )

        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.selectedSegmentID)
        XCTAssertNil(controller.activeSegmentID)
    }

    func testTranscriptTextEditKeepsSelectionStable() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: transcript
        )
        controller.selectAndPlay(segmentID: transcript.segments[0].id)

        var edited = transcript
        XCTAssertTrue(edited.updateText("Hello again", forSegmentID: transcript.segments[0].id))

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: edited
        )

        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.selectedSegmentID, transcript.segments[0].id)
        XCTAssertEqual(controller.activeSegmentID, transcript.segments[0].id)
    }

    func testSelectFirstAvailableSegmentUsesVisibleOrderAndDoesNotStartPlayback() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()
        let missingID = UUID()

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            audioDuration: 12,
            transcript: transcript
        )
        let seekCountAfterLoadingAudio = engine.seekHistory.count
        controller.selectFirstAvailableSegment(from: [missingID, transcript.segments[1].id, transcript.segments[0].id])

        XCTAssertEqual(controller.selectedSegmentID, transcript.segments[1].id)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(engine.seekHistory.count, seekCountAfterLoadingAudio)
    }

    func testSelectFirstAvailableSegmentKeepsExistingSelection() {
        let engine = FakeAudioPlaybackEngine(duration: 12)
        let controller = TranscriptPlaybackController(engine: engine)
        retainForTestProcess(engine, controller)
        let transcript = makeTranscript()

        controller.updateSession(audioURL: nil, audioDuration: 12, transcript: transcript)
        controller.selectSegment(transcript.segments[1].id)
        controller.selectFirstAvailableSegment(from: transcript.segments.map(\.id))

        XCTAssertEqual(controller.selectedSegmentID, transcript.segments[1].id)
    }

    private func makeTranscript() -> TranscriptState {
        TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: "A", text: "Hello", start: 0, end: 1),
                TranscriptSegment(speakerLabel: "B", text: "World", start: 1, end: 3)
            ]
        )
    }

    private func retainForTestProcess(_ objects: AnyObject...) {
        PlaybackTestRetainer.retainedObjects.append(contentsOf: objects)
    }
}

@MainActor
private enum PlaybackTestRetainer {
    static var retainedObjects: [AnyObject] = []
}

private final class FakeAudioPlaybackEngine: AudioPlaybackEngine {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var isPlaying = false
    weak var delegate: (any AudioPlaybackEngineDelegate)?

    private(set) var loadedURL: URL?
    private(set) var seekHistory: [TimeInterval] = []
    private(set) var pauseCount = 0

    init(duration: TimeInterval?) {
        self.duration = duration
    }

    func load(url: URL?) {
        loadedURL = url
        currentTime = 0
    }

    func seek(to time: TimeInterval, tolerance: TimeInterval) {
        currentTime = time
        seekHistory.append(time)
    }

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
        pauseCount += 1
    }

    func stop() {
        isPlaying = false
    }

    func advance(to time: TimeInterval) {
        currentTime = time
        MainActor.assumeIsolated { [delegate] in
            delegate?.audioPlaybackEngineDidUpdateTime(time)
        }
    }
}
