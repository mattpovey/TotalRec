import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id: UUID
    var speakerLabel: String?
    var text: String
    var start: TimeInterval?
    var end: TimeInterval?

    init(id: UUID = UUID(), speakerLabel: String?, text: String, start: TimeInterval? = nil, end: TimeInterval? = nil) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.text = text
        self.start = start
        self.end = end
    }
}

struct TranscriptState: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case segments
        case speakerAliases
        case rawText
    }
    private static let aliasAlphabet: [String] = {
        let scalars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return scalars.map { String($0) }
    }()

    var segments: [TranscriptSegment]
    var speakerAliases: [String: String]
    var rawText: String

    init(segments: [TranscriptSegment] = [], rawText: String = "", speakerAliases: [String: String] = [:]) {
        self.segments = segments
        self.rawText = rawText
        self.speakerAliases = speakerAliases
        ensureAliases()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        let speakerAliases = try container.decodeIfPresent([String: String].self, forKey: .speakerAliases) ?? [:]
        let rawText = try container.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        self.init(segments: segments, rawText: rawText, speakerAliases: speakerAliases)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(speakerAliases, forKey: .speakerAliases)
        try container.encode(rawText, forKey: .rawText)
    }

    var isEmpty: Bool { segments.isEmpty && rawText.isEmpty }

    var hasSpeakerLabels: Bool { !orderedSpeakerLabels.isEmpty }

    var orderedSpeakerLabels: [String] {
        var order: [String] = []
        for segment in segments {
            guard let label = segment.speakerLabel, !label.isEmpty else { continue }
            if !order.contains(label) { order.append(label) }
        }
        for key in speakerAliases.keys.sorted() {
            if !order.contains(key) { order.append(key) }
        }
        return order
    }

    func alias(for label: String) -> String {
        speakerAliases[label] ?? label
    }

    mutating func setAlias(_ alias: String, for label: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerAliases[label] = trimmed
        ensureAliases()
    }

    mutating func resetAliases() {
        speakerAliases = [:]
        ensureAliases()
    }


    mutating func updateSegments(_ segments: [TranscriptSegment]) {
        self.segments = segments
        ensureAliases()
    }

    var hasConsecutiveSpeakerRuns: Bool {
        guard segments.count > 1 else { return false }
        for index in 1..<segments.count {
            let prev = segments[index - 1]
            let current = segments[index]
            if let prevLabel = prev.speakerLabel,
               let currentLabel = current.speakerLabel,
               !prevLabel.isEmpty,
               prevLabel == currentLabel {
                return true
            }
        }
        return false
    }

    @discardableResult
    mutating func consolidateConsecutiveSpeakers() -> Bool {
        guard segments.count > 1 else { return false }
        var merged: [TranscriptSegment] = []
        var changed = false

        for segment in segments {
            if var last = merged.last,
               let lastLabel = last.speakerLabel,
               let currentLabel = segment.speakerLabel,
               !lastLabel.isEmpty,
               lastLabel == currentLabel {
                changed = true
                last.text = combineText(last.text, segment.text)
                if last.start == nil { last.start = segment.start }
                if let newEnd = segment.end { last.end = newEnd }
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }

        guard changed else { return false }
        segments = merged
        ensureAliases()
        rawText = TranscriptFormatter(transcript: self).joinedPlainText()
        return true
    }

    mutating func append(_ other: TranscriptState, timeOffset: TimeInterval) {
        if !other.segments.isEmpty {
            let adjusted = other.segments.map { segment -> TranscriptSegment in
                var next = segment
                if let start = segment.start { next.start = start + timeOffset }
                if let end = segment.end { next.end = end + timeOffset }
                return next
            }
            segments.append(contentsOf: adjusted)
        }

        if rawText.isEmpty {
            rawText = other.rawText
        } else if !other.rawText.isEmpty {
            rawText += "\n" + other.rawText
        }

        for (label, alias) in other.speakerAliases {
            if speakerAliases[label] == nil {
                speakerAliases[label] = alias
            }
        }

        ensureAliases()
        if !segments.isEmpty {
            rawText = TranscriptFormatter(transcript: self).joinedPlainText()
        }
    }

    private func combineText(_ existing: String, _ addition: String) -> String {
        if existing.isEmpty { return addition }
        if addition.isEmpty { return existing }
        if existing.hasSuffix(" ") || addition.hasPrefix(" ") {
            return existing + addition
        }
        return existing + " " + addition
    }

    mutating func updateRawText(_ text: String) {
        rawText = text
    }

    mutating func appendToRawText(_ text: String) {
        rawText += text
    }

    mutating func reset() {
        segments = []
        speakerAliases = [:]
        rawText = ""
    }

    var displayText: String {
        if !segments.isEmpty {
            return segments.map { segment in
                if let label = segment.speakerLabel, !label.isEmpty {
                    let aliasValue = alias(for: label)
                    return "\(aliasValue): \(segment.text)"
                } else {
                    return segment.text
                }
            }.joined(separator: "\n")
        }
        return rawText
    }

    var attributedDisplayText: AttributedString {
        if segments.isEmpty {
            return AttributedString(rawText)
        }

        var combined = AttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                combined.append(AttributedString("\n"))
            }

            if let label = segment.speakerLabel, !label.isEmpty {
                var speaker = AttributedString("\(alias(for: label)):")
                speaker.inlinePresentationIntent = .stronglyEmphasized
                combined.append(speaker)
                combined.append(AttributedString(" \(segment.text)"))
            } else {
                combined.append(AttributedString(segment.text))
            }
        }
        return combined
    }

    var plainTextExport: String {
        var lines: [String] = []
        if hasSpeakerLabels {
            lines.append("# Speaker Aliases")
            for label in orderedSpeakerLabels {
                lines.append("\(label): \(alias(for: label))")
            }
            lines.append("")
        }
        if !displayText.isEmpty {
            lines.append(displayText)
        }
        return lines.joined(separator: "\n")
    }

    private mutating func ensureAliases() {
        var order: [String] = []
        for segment in segments {
            guard let label = segment.speakerLabel, !label.isEmpty else { continue }
            if !order.contains(label) { order.append(label) }
        }
        for key in speakerAliases.keys.sorted() {
            if !order.contains(key) { order.append(key) }
        }
        var newMap: [String: String] = [:]
        for (index, label) in order.enumerated() {
            let trimmed = speakerAliases[label]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                newMap[label] = trimmed
            } else {
                newMap[label] = TranscriptState.defaultAlias(for: index)
            }
        }
        speakerAliases = newMap
    }

    private static func defaultAlias(for index: Int) -> String {
        if index < aliasAlphabet.count {
            return aliasAlphabet[index]
        }
        return "Speaker \(index + 1)"
    }
}
