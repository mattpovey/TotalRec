import Foundation

struct TranscriptSegment: Codable, Hashable {
    let speakerLabel: String?
    let text: String
    let start: TimeInterval?
    let end: TimeInterval?

    init(speakerLabel: String?, text: String, start: TimeInterval?, end: TimeInterval?) {
        self.speakerLabel = speakerLabel
        self.text = text
        self.start = start
        self.end = end
    }
}

struct Transcript: Codable, Equatable {
    var segments: [TranscriptSegment]
    var aliasMap: [String: String]

    init(segments: [TranscriptSegment], aliasMap: [String: String] = [:]) {
        self.segments = segments
        self.aliasMap = aliasMap
    }

    func alias(for rawLabel: String) -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawLabel }
        return aliasMap[trimmed] ?? trimmed
    }

    func displaySpeaker(for segment: TranscriptSegment) -> String? {
        guard let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        return alias(for: label)
    }
}

struct TranscriptFormatter {
    let transcript: Transcript

    init(transcript: Transcript) {
        self.transcript = transcript
    }

    func joinedPlainText() -> String {
        transcript.segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            if let speaker = transcript.displaySpeaker(for: segment) {
                return "\(speaker): \(text)"
            }
            return text
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func captionLines() -> [String] {
        transcript.segments.map { segment in
            let base = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { return "" }
            if let speaker = transcript.displaySpeaker(for: segment) {
                return "\(speaker): \(base)"
            }
            return base
        }
    }
}

enum CaptionFormat {
    case webVTT
    case srt
}

struct TranscriptRenderer {
    let transcript: Transcript
    private let formatter: TranscriptFormatter

    init(transcript: Transcript) {
        self.transcript = transcript
        self.formatter = TranscriptFormatter(transcript: transcript)
    }

    func plainText() -> String {
        formatter.joinedPlainText()
    }

    func json(pretty: Bool = true) throws -> Data {
        struct JSONSegment: Codable {
            let speaker: String?
            let rawSpeaker: String?
            let text: String
            let start: TimeInterval?
            let end: TimeInterval?
        }
        struct Payload: Codable {
            let segments: [JSONSegment]
            let aliasMap: [String: String]
            let combinedText: String
        }

        let segments = transcript.segments.map { segment -> JSONSegment in
            let raw = segment.speakerLabel
            let alias = raw.flatMap { _ in transcript.displaySpeaker(for: segment) }
            return JSONSegment(
                speaker: alias,
                rawSpeaker: raw,
                text: segment.text,
                start: segment.start,
                end: segment.end
            )
        }

        let payload = Payload(
            segments: segments,
            aliasMap: transcript.aliasMap,
            combinedText: formatter.joinedPlainText()
        )
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(payload)
    }

    func captions(format: CaptionFormat) -> String {
        switch format {
        case .webVTT:
            return renderWebVTT()
        case .srt:
            return renderSRT()
        }
    }

    private func renderWebVTT() -> String {
        let header = "WEBVTT\n\n"
        let body = formattedCaptionEntries().map { entry -> String in
            var lines: [String] = []
            lines.append("\(formatTimestamp(entry.start, separator: ".")) --> \(formatTimestamp(entry.end, separator: "."))")
            lines.append(entry.text)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return header + body
    }

    private func renderSRT() -> String {
        let entries = formattedCaptionEntries()
        let lines: [String] = entries.enumerated().map { idx, entry in
            var block: [String] = []
            block.append("\(idx + 1)")
            block.append("\(formatTimestamp(entry.start, separator: ",")) --> \(formatTimestamp(entry.end, separator: ","))")
            block.append(entry.text)
            return block.joined(separator: "\n")
        }
        return lines.joined(separator: "\n\n")
    }

    private typealias CaptionEntry = (start: TimeInterval, end: TimeInterval, text: String)

    private func formattedCaptionEntries() -> [CaptionEntry] {
        var cursor: TimeInterval = 0
        return zip(transcript.segments, formatter.captionLines()).compactMap { segment, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let start = segment.start ?? cursor
            let duration: TimeInterval
            if let explicitEnd = segment.end {
                duration = max(explicitEnd - start, 0.5)
            } else {
                duration = max(estimateDuration(for: trimmed), 0.5)
            }
            let end = segment.end ?? (start + duration)
            cursor = end
            return (start: start, end: end, text: trimmed)
        }
    }

    private func estimateDuration(for text: String) -> TimeInterval {
        let words = text.split { $0.isWhitespace }
        // Assume an average speech rate of 180 wpm (~3 words per second)
        let seconds = Double(words.count) / 3.0
        return max(seconds, 1.0)
    }

    private func formatTimestamp(_ time: TimeInterval, separator: String) -> String {
        let totalMilliseconds = Int((time * 1000.0).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, milliseconds)
    }
}
