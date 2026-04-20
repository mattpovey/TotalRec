import Foundation

struct TranscriptFormatter {
    let transcript: TranscriptState

    init(transcript: TranscriptState) {
        self.transcript = transcript
    }

    func joinedPlainText() -> String {
        transcript.segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            if let speaker = displaySpeaker(for: segment) {
                return "\(speaker): \(text)"
            }
            return text
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Joins transcript text while preserving the raw diarization labels (e.g., SPEAKER_00).
    /// Downstream AI prompts need these IDs to match the `labels` array they receive.
    func joinedRawSpeakerText() -> String {
        transcript.segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            if let raw = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) {
                return "\(raw): \(text)"
            }
            return text
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    func captionLines() -> [String] {
        transcript.segments.map { segment in
            let base = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { return "" }
            if let speaker = displaySpeaker(for: segment) {
                return "\(speaker): \(base)"
            }
            return base
        }
    }

    private func displaySpeaker(for segment: TranscriptSegment) -> String? {
        guard let raw = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) else {
            return nil
        }
        return transcript.alias(for: raw)
    }
}

enum CaptionFormat {
    case webVTT
    case srt
}

struct TranscriptRenderer {
    let transcript: TranscriptState
    private let formatter: TranscriptFormatter

    init(transcript: TranscriptState) {
        self.transcript = transcript
        self.formatter = TranscriptFormatter(transcript: transcript)
    }

    func plainText() -> String {
        formatter.joinedPlainText()
    }

    func markdown() -> String {
        var sections: [String] = []

        if transcript.hasSpeakerLabels {
            let aliasLines = transcript.orderedSpeakerLabels.map { label in
                let alias = transcript.alias(for: label)
                return "- `\(label)`: \(alias)"
            }
            if !aliasLines.isEmpty {
                sections.append(
                    [
                        "# Speaker Aliases",
                        aliasLines.joined(separator: "\n")
                    ].joined(separator: "\n\n")
                )
            }
        }

        let transcriptLines = transcript.segments.compactMap { segment -> String? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let speaker = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) {
                return "**\(transcript.alias(for: speaker)):** \(text)"
            }
            return text
        }

        let transcriptBody: String
        if transcriptLines.isEmpty {
            transcriptBody = transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            transcriptBody = transcriptLines.joined(separator: "\n\n")
        }

        if !transcriptBody.isEmpty {
            sections.append(
                [
                    "# Transcript",
                    transcriptBody
                ].joined(separator: "\n\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }

    func json(pretty: Bool = true) throws -> Data {
        struct JSONSpeaker: Codable {
            let id: String
            let displayName: String
        }

        struct JSONTimecode: Codable {
            let start: TimeInterval?
            let end: TimeInterval?
        }

        struct JSONSegment: Codable {
            let id: UUID?
            let speaker: JSONSpeaker?
            let timecode: JSONTimecode?
            let text: String
        }

        struct Payload: Codable {
            let schemaVersion: Int
            let speakers: [JSONSpeaker]
            let segments: [JSONSegment]
        }

        let speakers = transcript.orderedSpeakerLabels.map { label in
            JSONSpeaker(id: label, displayName: transcript.alias(for: label))
        }

        let segments: [JSONSegment]
        if transcript.segments.isEmpty {
            let rawText = transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawText.isEmpty {
                segments = []
            } else {
                segments = [
                    JSONSegment(
                        id: nil,
                        speaker: nil,
                        timecode: nil,
                        text: rawText
                    )
                ]
            }
        } else {
            segments = transcript.segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                let speaker = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel).map {
                    JSONSpeaker(id: $0, displayName: transcript.alias(for: $0))
                }
                let timecode = (segment.start != nil || segment.end != nil)
                    ? JSONTimecode(start: segment.start, end: segment.end)
                    : nil

                return JSONSegment(
                    id: segment.id,
                    speaker: speaker,
                    timecode: timecode,
                    text: text
                )
            }
        }

        let payload = Payload(
            schemaVersion: 2,
            speakers: speakers,
            segments: segments
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
