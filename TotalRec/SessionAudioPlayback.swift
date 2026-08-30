import Combine
import Foundation
import SwiftUI

enum SessionAudioAvailability: Equatable {
    case noAudio
    case unavailable
    case ready
}

@MainActor
final class SessionAudioPlaybackController: ObservableObject, AudioPlaybackEngineDelegate {
    @Published private(set) var audioURL: URL?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var isPlaying = false
    @Published private(set) var availability: SessionAudioAvailability = .noAudio

    private let engine: AudioPlaybackEngine
    private let isPlayableFile: (URL) -> Bool

    convenience init() {
        self.init(engine: AVPlayerAudioPlaybackEngine())
    }

    init(
        engine: AudioPlaybackEngine,
        isPlayableFile: @escaping (URL) -> Bool = SessionAudioPlaybackController.defaultFileValidator
    ) {
        self.engine = engine
        self.isPlayableFile = isPlayableFile
        self.engine.delegate = self
    }

    var canPlay: Bool {
        availability == .ready
    }

    func updateSession(audioURL: URL?, duration: TimeInterval?) {
        let normalizedDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let audioChanged = self.audioURL != audioURL

        self.duration = normalizedDuration ?? engine.duration

        guard audioChanged else { return }

        engine.pause()
        engine.seek(to: 0, tolerance: 0)
        engine.load(url: nil)
        self.audioURL = audioURL
        currentTime = 0
        isPlaying = false

        guard let audioURL else {
            availability = .noAudio
            self.duration = nil
            return
        }

        guard isPlayableFile(audioURL) else {
            availability = .unavailable
            self.duration = normalizedDuration
            return
        }

        availability = .ready
        engine.load(url: audioURL)
        self.duration = normalizedDuration ?? engine.duration
    }

    func togglePlayback() {
        guard canPlay else { return }

        if isPlaying {
            pause()
            return
        }

        if let effectiveDuration, currentTime >= effectiveDuration - 0.05 {
            engine.seek(to: 0, tolerance: 0)
            currentTime = 0
        }

        engine.play()
        isPlaying = true
    }

    func pause() {
        engine.pause()
        currentTime = engine.currentTime
        isPlaying = false
    }

    func restart() {
        guard canPlay else { return }
        engine.seek(to: 0, tolerance: 0)
        currentTime = 0
    }

    func seek(to time: TimeInterval) {
        guard canPlay else { return }
        let clampedTime = min(max(time, 0), effectiveDuration ?? max(time, 0))
        engine.seek(to: clampedTime, tolerance: 0.05)
        currentTime = clampedTime
    }

    func audioPlaybackEngineDidUpdateTime(_ time: TimeInterval) {
        let clampedTime = min(max(time, 0), effectiveDuration ?? max(time, 0))
        currentTime = clampedTime
        duration = duration ?? engine.duration

        if let effectiveDuration, clampedTime >= effectiveDuration - 0.05 {
            let shouldPause = isPlaying || engine.isPlaying
            isPlaying = false
            if shouldPause {
                engine.pause()
            }
            currentTime = effectiveDuration
        } else {
            isPlaying = engine.isPlaying
        }
    }

    private var effectiveDuration: TimeInterval? {
        duration ?? engine.duration
    }

    nonisolated private static func defaultFileValidator(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return false
        }
        return (values.fileSize ?? 0) > 0
    }
}

struct SessionAudioPlayerView: View {
    @ObservedObject var controller: SessionAudioPlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session Audio")
                        .font(.headline)
                    Text("Listen before sending this recording to transcription.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if controller.canPlay {
                    Label("Ready", systemImage: "waveform.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TotalRecGlass.successGreen)
                }
            }

            switch controller.availability {
            case .noAudio:
                unavailableMessage(
                    "Capture or import audio to enable playback.",
                    systemImage: "waveform.slash"
                )
            case .unavailable:
                unavailableMessage(
                    "The saved audio file is missing or empty. Check Session Details for recovery options.",
                    systemImage: "exclamationmark.triangle.fill"
                )
            case .ready:
                playbackControls
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button(action: controller.togglePlayback) {
                Label(
                    controller.isPlaying ? "Pause" : "Play",
                    systemImage: controller.isPlaying ? "pause.fill" : "play.fill"
                )
                .frame(minWidth: 62)
            }
            .totalRecGlassButton(prominent: true, tint: TotalRecGlass.captureBlue)

            Button(action: controller.restart) {
                Image(systemName: "backward.end.fill")
            }
            .totalRecGlassButton()
            .help("Restart audio")
            .accessibilityLabel("Restart audio")

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: controller.seek(to:)
                ),
                in: 0...max(controller.duration ?? controller.currentTime, 1)
            )
            .accessibilityLabel("Audio position")
            .accessibilityValue(formatSessionAudioTime(controller.currentTime))

            Text("\(formatSessionAudioTime(controller.currentTime)) / \(formatSessionAudioTime(controller.duration ?? 0))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 82, alignment: .trailing)
        }
    }

    private func unavailableMessage(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .totalRecReadableInset(cornerRadius: 12)
    }
}

private func formatSessionAudioTime(_ time: TimeInterval) -> String {
    let totalSeconds = max(Int(time.rounded()), 0)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}
