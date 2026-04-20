import Combine
import Foundation

@MainActor
final class TranscriptPlaybackController: ObservableObject, AudioPlaybackEngineDelegate {
    @Published private(set) var selectedSegmentID: UUID?
    @Published private(set) var activeSegmentID: UUID?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var audioURL: URL?
    @Published private(set) var audioDuration: TimeInterval?
    @Published private(set) var clipRange: TranscriptState.PlaybackRange?

    private let engine: AudioPlaybackEngine
    private var transcript = TranscriptState()

    convenience init() {
        self.init(engine: AVPlayerAudioPlaybackEngine())
    }

    init(engine: AudioPlaybackEngine) {
        self.engine = engine
        self.audioDuration = engine.duration
        self.currentTime = engine.currentTime
        self.engine.delegate = self
    }

    var selectedSegment: TranscriptSegment? {
        guard let selectedSegmentID else { return nil }
        return transcript.segment(withID: selectedSegmentID)
    }

    var canPlaySelectedSegment: Bool {
        guard let selectedSegmentID, audioURL != nil else { return false }
        return transcript.playbackRange(forSegmentID: selectedSegmentID, audioDuration: effectiveAudioDuration) != nil
    }

    func updateSession(audioURL: URL?, audioDuration: TimeInterval?, transcript: TranscriptState) {
        let audioChanged = self.audioURL != audioURL
        let playbackSegmentsChanged = playbackRelevantSegments(self.transcript) != playbackRelevantSegments(transcript)

        self.transcript = transcript
        self.audioDuration = audioDuration ?? engine.duration

        if audioChanged {
            self.audioURL = audioURL
            engine.load(url: audioURL)
            resetPlayback(resetPosition: true)
            return
        }

        if playbackSegmentsChanged {
            resetPlayback(resetPosition: false)
            return
        }

        if let selectedSegmentID, transcript.segment(withID: selectedSegmentID) == nil {
            resetPlayback(resetPosition: false)
            return
        }

        if isPlaying {
            activeSegmentID = transcript.segmentID(at: currentTime, audioDuration: effectiveAudioDuration)
        }
    }

    func selectAndPlay(segmentID: UUID) {
        selectedSegmentID = segmentID
        playSelectedClip()
    }

    func selectSegment(_ segmentID: UUID) {
        selectedSegmentID = segmentID
    }

    func playSelectedClip() {
        playSelectedClip(contextPadding: 0)
    }

    func playSelectedClipWithContext() {
        playSelectedClip(contextPadding: 2.0)
    }

    func pause() {
        engine.pause()
        isPlaying = false
        activeSegmentID = nil
        clipRange = nil
        currentTime = engine.currentTime
    }

    func stopAndClearSelection() {
        resetPlayback(resetPosition: false)
    }

    func audioPlaybackEngineDidUpdateTime(_ time: TimeInterval) {
        handleTimeUpdate(time)
    }

    private var effectiveAudioDuration: TimeInterval? {
        audioDuration ?? engine.duration
    }

    private func playSelectedClip(contextPadding: TimeInterval) {
        guard let selectedSegmentID,
              audioURL != nil,
              let baseRange = transcript.playbackRange(forSegmentID: selectedSegmentID, audioDuration: effectiveAudioDuration) else {
            pause()
            return
        }

        let clampedStart = max(baseRange.start - contextPadding, 0)
        let upperBound = effectiveAudioDuration ?? (baseRange.end + contextPadding)
        let clampedEnd = min(baseRange.end + contextPadding, upperBound)
        guard clampedEnd > clampedStart else { return }

        clipRange = TranscriptState.PlaybackRange(start: clampedStart, end: clampedEnd)
        currentTime = clampedStart
        activeSegmentID = transcript.segmentID(at: clampedStart, audioDuration: effectiveAudioDuration) ?? selectedSegmentID
        engine.seek(to: clampedStart, tolerance: 0)
        engine.play()
        isPlaying = true
    }

    private func handleTimeUpdate(_ time: TimeInterval) {
        currentTime = time
        audioDuration = audioDuration ?? engine.duration

        guard isPlaying else { return }

        if let clipRange, time >= clipRange.end {
            engine.pause()
            engine.seek(to: clipRange.end, tolerance: 0)
            currentTime = clipRange.end
            isPlaying = false
            activeSegmentID = nil
            self.clipRange = nil
            return
        }

        activeSegmentID = transcript.segmentID(at: time, audioDuration: effectiveAudioDuration)
    }

    private func resetPlayback(resetPosition: Bool) {
        engine.pause()
        isPlaying = false
        selectedSegmentID = nil
        activeSegmentID = nil
        clipRange = nil

        if resetPosition {
            engine.seek(to: 0, tolerance: 0)
            currentTime = 0
        } else {
            currentTime = engine.currentTime
        }
    }

    private func playbackRelevantSegments(_ transcript: TranscriptState) -> [PlaybackComparableSegment] {
        transcript.segments.map {
            PlaybackComparableSegment(id: $0.id, start: $0.start, end: $0.end)
        }
    }
}

private struct PlaybackComparableSegment: Equatable {
    let id: UUID
    let start: TimeInterval?
    let end: TimeInterval?
}
