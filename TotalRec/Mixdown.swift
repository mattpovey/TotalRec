import Foundation
@preconcurrency import AVFoundation

struct Mixdown {
    /// Mix system + mic into a single .m4a.
    /// - Parameters:
    ///   - sourceMOV: the temporary .mov that has two audio tracks (system first, mic second).
    ///   - outputM4A: destination .m4a URL (will be overwritten if exists).
    ///   - systemGain: 0.0...1.5 typical
    ///   - micGain: 0.0...1.5 typical
    static func toM4A(sourceMOV: URL,
                      outputM4A: URL,
                      systemGain: Float = 1.0,
                      micGain: Float = 1.0,
                      completion: @escaping (Result<URL, Error>) -> Void) {

        // Perform async work in a Task to preserve completion-based API
        Task {
            do {
                // Prepare asset and tracks (modern APIs)
                let asset = AVURLAsset(url: sourceMOV)
                let tracks = try await asset.loadTracks(withMediaType: .audio)

                if FileManager.default.fileExists(atPath: outputM4A.path) {
                    try? FileManager.default.removeItem(at: outputM4A)
                }

                guard let exporter = AVAssetExportSession(asset: asset,
                                                          presetName: AVAssetExportPresetAppleM4A) else {
                    throw NSError(domain: "Mixdown", code: -50,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot create exporter"]) 
                }

                exporter.outputURL = outputM4A
                exporter.outputFileType = .m4a
                exporter.metadata = nil

                // Build audio mix: assume writer created tracks in order: [system, mic]
                let audioMix = AVMutableAudioMix()
                var paramsList: [AVAudioMixInputParameters] = []

                if tracks.indices.contains(0) {
                    let p0 = AVMutableAudioMixInputParameters(track: tracks[0])
                    p0.setVolume(systemGain, at: .zero)
                    paramsList.append(p0)
                }
                if tracks.indices.contains(1) {
                    let p1 = AVMutableAudioMixInputParameters(track: tracks[1])
                    p1.setVolume(micGain, at: .zero)
                    paramsList.append(p1)
                }
                audioMix.inputParameters = paramsList
                exporter.audioMix = audioMix

                // Use modern async export API on macOS 15+, fall back to legacy on older OSes
                if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
                    // export(to:as:) throws on failure
                    try await exporter.export(to: outputM4A, as: .m4a)
                    completion(.success(outputM4A))
                } else {
                    exporter.exportAsynchronously {
                        switch exporter.status {
                        case .completed:
                            completion(.success(outputM4A))
                        case .failed, .cancelled:
                            completion(.failure(exporter.error ?? NSError(domain: "Mixdown", code: -51)))
                        default:
                            completion(.failure(NSError(domain: "Mixdown", code: -52)))
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}

struct AudioChunker {
    struct Chunk {
        let url: URL
        let startTime: TimeInterval
        let isTemporary: Bool
    }

    static let defaultMaxDuration: TimeInterval = 600 // seconds (10 minutes)

    static func chunkIfNeeded(sourceURL: URL,
                              strategy: String,
                              maxDuration: TimeInterval = defaultMaxDuration) async throws -> [Chunk] {
#if os(macOS)
        guard strategy.lowercased() == "auto" else {
            return [Chunk(url: sourceURL, startTime: 0, isTemporary: false)]
        }

        let asset = AVURLAsset(url: sourceURL)
        let durationSeconds = try await asset.load(.duration).seconds
        guard durationSeconds > maxDuration else {
            return [Chunk(url: sourceURL, startTime: 0, isTemporary: false)]
        }

        print("[AudioChunker] Splitting \(sourceURL.lastPathComponent) duration=\(String(format: "%.2f", durationSeconds))s into <=\(maxDuration)s chunks")

        var chunks: [Chunk] = []
        var cursor: TimeInterval = 0
        while cursor < durationSeconds {
            let slice = min(maxDuration, durationSeconds - cursor)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("totalrec-chunk-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            print("[AudioChunker] Exporting chunk start=\(String(format: "%.2f", cursor))s duration=\(String(format: "%.2f", slice))s")
            try await exportChunk(from: asset, start: cursor, duration: slice, to: tempURL)
            chunks.append(Chunk(url: tempURL, startTime: cursor, isTemporary: true))
            cursor += slice
        }
        print("[AudioChunker] Created \(chunks.count) chunk(s)")
        return chunks
#else
        return [Chunk(url: sourceURL, startTime: 0, isTemporary: false)]
#endif
    }

#if os(macOS)
    private static func exportChunk(from asset: AVURLAsset,
                                    start: TimeInterval,
                                    duration: TimeInterval,
                                    to destination: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioChunker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create exporter"])
        }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        exporter.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed, .cancelled:
                    let error = exporter.error ?? NSError(domain: "AudioChunker", code: -2, userInfo: [NSLocalizedDescriptionKey: "Chunk export failed"])
                    continuation.resume(throwing: error)
                default:
                    let error = exporter.error ?? NSError(domain: "AudioChunker", code: -3, userInfo: [NSLocalizedDescriptionKey: "Chunk export ended unexpectedly"])
                    continuation.resume(throwing: error)
                }
            }
        }
    }
#endif
}
