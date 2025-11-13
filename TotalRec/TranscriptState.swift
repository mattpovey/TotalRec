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

    mutating func updateSegments(_ segments: [TranscriptSegment]) {
        self.segments = segments
        ensureAliases()
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
