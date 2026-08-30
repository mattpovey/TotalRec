import XCTest
@testable import TotalRec

@MainActor
final class SessionAudioPlaybackControllerTests: XCTestCase {
    func testPlayableSessionLoadsAndTogglesPlayback() {
        let engine = SessionAudioFakeEngine(duration: 12)
        let controller = makeController(engine: engine)
        let url = URL(fileURLWithPath: "/tmp/session-a.m4a")

        controller.updateSession(audioURL: url, duration: 12)
        controller.togglePlayback()

        XCTAssertEqual(controller.availability, .ready)
        XCTAssertEqual(engine.loadedURL, url)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(engine.isPlaying)

        controller.togglePlayback()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(engine.isPlaying)
    }

    func testSessionChangeStopsAndResetsPlayback() {
        let engine = SessionAudioFakeEngine(duration: 12)
        let controller = makeController(engine: engine)

        controller.updateSession(audioURL: URL(fileURLWithPath: "/tmp/session-a.m4a"), duration: 12)
        controller.togglePlayback()
        engine.advance(to: 4)

        let nextURL = URL(fileURLWithPath: "/tmp/session-b.m4a")
        controller.updateSession(audioURL: nextURL, duration: 8)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 8)
        XCTAssertEqual(engine.loadedURL, nextURL)
    }

    func testUnavailableFileCannotPlay() {
        let engine = SessionAudioFakeEngine(duration: nil)
        let controller = SessionAudioPlaybackController(
            engine: engine,
            isPlayableFile: { _ in false }
        )

        controller.updateSession(
            audioURL: URL(fileURLWithPath: "/tmp/missing.m4a"),
            duration: nil
        )
        controller.togglePlayback()

        XCTAssertEqual(controller.availability, .unavailable)
        XCTAssertFalse(controller.canPlay)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.loadedURL)
    }

    func testSeekClampsToDurationAndRestartReturnsToBeginning() {
        let engine = SessionAudioFakeEngine(duration: 10)
        let controller = makeController(engine: engine)
        controller.updateSession(audioURL: URL(fileURLWithPath: "/tmp/session.m4a"), duration: 10)

        controller.seek(to: 15)
        XCTAssertEqual(controller.currentTime, 10)
        XCTAssertEqual(engine.seekHistory.last, 10)

        controller.restart()
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(engine.seekHistory.last, 0)
    }

    func testPlaybackCompletionStopsAndCanRestart() {
        let engine = SessionAudioFakeEngine(duration: 5)
        let controller = makeController(engine: engine)
        controller.updateSession(audioURL: URL(fileURLWithPath: "/tmp/session.m4a"), duration: 5)
        controller.togglePlayback()

        engine.advance(to: 5)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 5)

        controller.togglePlayback()

        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(engine.seekHistory.last, 0)
    }

    private func makeController(engine: SessionAudioFakeEngine) -> SessionAudioPlaybackController {
        SessionAudioPlaybackController(engine: engine, isPlayableFile: { _ in true })
    }
}

private final class SessionAudioFakeEngine: AudioPlaybackEngine {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var isPlaying = false
    weak var delegate: (any AudioPlaybackEngineDelegate)?

    private(set) var loadedURL: URL?
    private(set) var seekHistory: [TimeInterval] = []

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
