import Foundation
@preconcurrency import AVFoundation

enum RecordingCaptureFileState: Equatable {
    case missing
    case empty
    case candidate(byteCount: Int64)

    var canAttemptRecovery: Bool {
        if case .candidate = self {
            return true
        }
        return false
    }

    var displayText: String {
        switch self {
        case .missing:
            return "Capture file is missing"
        case .empty:
            return "Empty capture (0 bytes)"
        case let .candidate(byteCount):
            return "Raw capture (\(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)))"
        }
    }
}

enum RecordingRecoveryError: LocalizedError {
    case missingCapture
    case emptyCapture
    case unreadableCapture(String)
    case noAudioTrack
    case mixdownFailed(String)
    case invalidMixedAudio

    var errorDescription: String? {
        switch self {
        case .missingCapture:
            return "The raw capture file is missing. Open the session folder to inspect the saved files."
        case .emptyCapture:
            return "The raw capture is empty, so there is no audio to recover. Check recording permissions before trying another recording."
        case let .unreadableCapture(reason):
            return "The raw capture could not be read as media: \(reason)"
        case .noAudioTrack:
            return "The raw capture contains no audio track, so it cannot be recovered."
        case let .mixdownFailed(reason):
            return "The raw capture is present, but audio recovery failed during mixdown: \(reason)"
        case .invalidMixedAudio:
            return "Audio recovery produced an invalid or empty audio file. The raw capture has been kept for another attempt."
        }
    }
}

struct RecordingArtifactValidator {
    static func inspectCaptureFile(at url: URL?, fileManager: FileManager = .default) -> RecordingCaptureFileState {
        guard let url,
              fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? NSNumber else {
            return .missing
        }

        let size = byteCount.int64Value
        return size > 0 ? .candidate(byteCount: size) : .empty
    }

    static func validateCapture(at url: URL) async throws {
        switch inspectCaptureFile(at: url) {
        case .missing:
            throw RecordingRecoveryError.missingCapture
        case .empty:
            throw RecordingRecoveryError.emptyCapture
        case .candidate:
            break
        }

        let asset = AVURLAsset(url: url)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw RecordingRecoveryError.noAudioTrack
            }
        } catch let error as RecordingRecoveryError {
            throw error
        } catch {
            throw RecordingRecoveryError.unreadableCapture(error.localizedDescription)
        }
    }

    static func validateMixedAudio(at url: URL) async throws -> TimeInterval? {
        guard case .candidate = inspectCaptureFile(at: url) else {
            throw RecordingRecoveryError.invalidMixedAudio
        }

        let asset = AVURLAsset(url: url)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw RecordingRecoveryError.invalidMixedAudio
            }

            let seconds = try await asset.load(.duration).seconds
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch let error as RecordingRecoveryError {
            throw error
        } catch {
            throw RecordingRecoveryError.invalidMixedAudio
        }
    }
}

protocol RecordingFinalizing {
    func finalizeCapture(
        at sourceURL: URL,
        outputURL: URL,
        systemGain: Float,
        micGain: Float
    ) async throws -> TimeInterval?
}

struct RecordingFinalizer: RecordingFinalizing {
    func finalizeCapture(
        at sourceURL: URL,
        outputURL: URL,
        systemGain: Float,
        micGain: Float
    ) async throws -> TimeInterval? {
        try await RecordingArtifactValidator.validateCapture(at: sourceURL)

        do {
            try await withCheckedThrowingContinuation { continuation in
                Mixdown.toM4A(
                    sourceMOV: sourceURL,
                    outputM4A: outputURL,
                    systemGain: systemGain,
                    micGain: micGain
                ) { result in
                    continuation.resume(with: result.map { _ in () })
                }
            }
        } catch {
            throw RecordingRecoveryError.mixdownFailed(error.localizedDescription)
        }

        return try await RecordingArtifactValidator.validateMixedAudio(at: outputURL)
    }
}
