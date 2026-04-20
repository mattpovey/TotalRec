import AVFoundation
import Foundation

protocol AudioPlaybackEngineDelegate: AnyObject {
    @MainActor
    func audioPlaybackEngineDidUpdateTime(_ time: TimeInterval)
}

protocol AudioPlaybackEngine: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var isPlaying: Bool { get }
    var delegate: (any AudioPlaybackEngineDelegate)? { get set }

    func load(url: URL?)
    func seek(to time: TimeInterval, tolerance: TimeInterval)
    func play()
    func pause()
    func stop()
}

final class AVPlayerAudioPlaybackEngine: AudioPlaybackEngine {
    weak var delegate: (any AudioPlaybackEngineDelegate)?

    var currentTime: TimeInterval {
        player.currentTime().seconds.isFinite ? max(player.currentTime().seconds, 0) : 0
    }

    var duration: TimeInterval? {
        guard let item = player.currentItem else { return nil }
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    var isPlaying: Bool {
        player.rate > 0
    }

    private let player = AVPlayer()
    private var currentURL: URL?
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.emitTimeUpdate()
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func load(url: URL?) {
        guard currentURL != url else { return }

        stop()
        currentURL = url

        guard let url else {
            player.replaceCurrentItem(with: nil)
            emitTimeUpdate()
            return
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        emitTimeUpdate()
    }

    func seek(to time: TimeInterval, tolerance: TimeInterval) {
        let cmTime = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        let toleranceTime = CMTime(seconds: max(tolerance, 0), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: toleranceTime, toleranceAfter: toleranceTime) { [weak self] _ in
            self?.emitTimeUpdate()
        }
    }

    func play() {
        player.play()
        emitTimeUpdate()
    }

    func pause() {
        player.pause()
        emitTimeUpdate()
    }

    func stop() {
        player.pause()
    }

    private func emitTimeUpdate() {
        let time = currentTime
        Task { @MainActor [weak delegate] in
            delegate?.audioPlaybackEngineDidUpdateTime(time)
        }
    }
}
