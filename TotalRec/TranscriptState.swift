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
    struct PlaybackRange: Equatable {
        let start: TimeInterval
        let end: TimeInterval
    }

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

    var hasTimedSegments: Bool {
        segments.contains { $0.start != nil }
    }

    static func canonicalSpeakerLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let simplified = trimmed
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch simplified {
        case "?", "unknown", "speakerunknown", "none", "unspecified":
            return nil
        default:
            return trimmed
        }
    }

    var orderedSpeakerLabels: [String] {
        var order: [String] = []
        for segment in segments {
            guard let label = Self.canonicalSpeakerLabel(segment.speakerLabel) else { continue }
            if !order.contains(label) { order.append(label) }
        }
        return order
    }

    func alias(for label: String) -> String {
        let canonical = Self.canonicalSpeakerLabel(label) ?? label.trimmingCharacters(in: .whitespacesAndNewlines)
        return speakerAliases[canonical] ?? canonical
    }

    mutating func setAlias(_ alias: String, for label: String) {
        guard let canonical = Self.canonicalSpeakerLabel(label) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerAliases[canonical] = trimmed
        ensureAliases()
    }

    func speakerLabel(matchingAlias alias: String, excluding excludedLabel: String? = nil) -> String? {
        let normalizedAlias = Self.normalizedAliasKey(alias)
        guard !normalizedAlias.isEmpty else { return nil }

        let excluded = Self.canonicalSpeakerLabel(excludedLabel)
        return orderedSpeakerLabels.first { label in
            guard label != excluded else { return false }
            return Self.normalizedAliasKey(self.alias(for: label)) == normalizedAlias
        }
    }

    mutating func resetAliases() {
        speakerAliases = [:]
        ensureAliases()
    }


    mutating func updateSegments(_ segments: [TranscriptSegment]) {
        self.segments = segments
        ensureAliases()
    }

    func segment(withID id: UUID) -> TranscriptSegment? {
        segments.first(where: { $0.id == id })
    }

    func playbackRange(forSegmentID id: UUID, audioDuration: TimeInterval?) -> PlaybackRange? {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        return playbackRange(forSegmentAt: index, audioDuration: audioDuration)
    }

    func segmentID(at time: TimeInterval, audioDuration: TimeInterval?) -> UUID? {
        for index in segments.indices {
            guard let range = playbackRange(forSegmentAt: index, audioDuration: audioDuration) else { continue }
            if time >= range.start && time < range.end {
                return segments[index].id
            }
        }
        return nil
    }

    @discardableResult
    mutating func updateText(_ text: String, forSegmentID id: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return false }
        guard segments[index].text != trimmed else { return false }

        segments[index].text = trimmed
        rawText = TranscriptFormatter(transcript: self).joinedPlainText()
        return true
    }

    @discardableResult
    mutating func updateSpeakerLabel(_ speakerLabel: String?, forSegmentID id: UUID) -> Bool {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return false }

        let normalized = Self.canonicalSpeakerLabel(speakerLabel)
        let current = Self.canonicalSpeakerLabel(segments[index].speakerLabel)
        guard current != normalized else { return false }

        segments[index].speakerLabel = normalized
        ensureAliases()
        return true
    }

    @discardableResult
    mutating func mergeSpeakerLabel(_ sourceLabel: String, into targetLabel: String) -> Bool {
        guard let source = Self.canonicalSpeakerLabel(sourceLabel),
              let target = Self.canonicalSpeakerLabel(targetLabel),
              source != target else {
            return false
        }

        var changed = false
        for index in segments.indices {
            guard Self.canonicalSpeakerLabel(segments[index].speakerLabel) == source else { continue }
            segments[index].speakerLabel = target
            changed = true
        }

        guard changed else { return false }

        ensureAliases()
        rawText = TranscriptFormatter(transcript: self).joinedPlainText()
        return true
    }

    var hasConsecutiveSpeakerRuns: Bool {
        guard segments.count > 1 else { return false }
        for index in 1..<segments.count {
            let prev = segments[index - 1]
            let current = segments[index]
            if let prevLabel = Self.canonicalSpeakerLabel(prev.speakerLabel),
               let currentLabel = Self.canonicalSpeakerLabel(current.speakerLabel),
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
               let lastLabel = Self.canonicalSpeakerLabel(last.speakerLabel),
               let currentLabel = Self.canonicalSpeakerLabel(segment.speakerLabel),
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
            guard let canonical = Self.canonicalSpeakerLabel(label) else { continue }
            if speakerAliases[canonical] == nil {
                speakerAliases[canonical] = alias
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

    func literalMatchCount(for searchText: String) -> Int {
        guard !searchText.isEmpty else { return 0 }

        if !segments.isEmpty {
            return segments.reduce(into: 0) { count, segment in
                count += Self.literalMatchCount(in: segment.text, for: searchText)
            }
        }

        return Self.literalMatchCount(in: rawText, for: searchText)
    }

    @discardableResult
    mutating func replaceAllLiteralMatches(of searchText: String, with replacement: String) -> Int {
        guard !searchText.isEmpty else { return 0 }

        var totalReplacements = 0

        if !segments.isEmpty {
            for index in segments.indices {
                let replacements = Self.literalMatchCount(in: segments[index].text, for: searchText)
                guard replacements > 0 else { continue }
                totalReplacements += replacements
                segments[index].text = segments[index].text.replacingOccurrences(of: searchText, with: replacement)
            }

            if totalReplacements > 0 {
                rawText = TranscriptFormatter(transcript: self).joinedPlainText()
            }
            return totalReplacements
        }

        totalReplacements = Self.literalMatchCount(in: rawText, for: searchText)
        guard totalReplacements > 0 else { return 0 }

        rawText = rawText.replacingOccurrences(of: searchText, with: replacement)
        return totalReplacements
    }

    mutating func reset() {
        segments = []
        speakerAliases = [:]
        rawText = ""
    }

    var hasDisplayText: Bool {
        if !segments.isEmpty {
            return segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayText: String {
        if !segments.isEmpty {
            return segments.map { segment in
                if let label = Self.canonicalSpeakerLabel(segment.speakerLabel) {
                    let aliasValue = alias(for: label)
                    return "\(aliasValue): \(segment.text)"
                } else {
                    return segment.text
                }
            }.joined(separator: "\n")
        }
        return rawText
    }

    func previewText(maxSegments: Int = 8, maxCharacters: Int = 900) -> String {
        guard maxSegments > 0, maxCharacters > 0 else { return "" }

        if !segments.isEmpty {
            var previewLines: [String] = []
            var characterCount = 0
            var wasTruncated = false

            for segment in segments.prefix(maxSegments) {
                let line: String
                if let label = Self.canonicalSpeakerLabel(segment.speakerLabel) {
                    line = "\(alias(for: label)): \(segment.text)"
                } else {
                    line = segment.text
                }

                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else { continue }

                let separatorCost = previewLines.isEmpty ? 0 : 1
                let available = maxCharacters - characterCount - separatorCost
                guard available > 0 else {
                    wasTruncated = true
                    break
                }

                if trimmedLine.count > available {
                    let endIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: available)
                    let truncatedLine = String(trimmedLine[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !truncatedLine.isEmpty {
                        previewLines.append(truncatedLine + "…")
                    }
                    wasTruncated = true
                    break
                }

                previewLines.append(trimmedLine)
                characterCount += trimmedLine.count + separatorCost
            }

            if segments.count > maxSegments {
                wasTruncated = true
            }

            let preview = previewLines.joined(separator: "\n")
            if wasTruncated, !preview.hasSuffix("…") {
                return preview + "\n…"
            }
            return preview
        }

        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawText.isEmpty else { return "" }
        if trimmedRawText.count <= maxCharacters {
            return trimmedRawText
        }

        let endIndex = trimmedRawText.index(trimmedRawText.startIndex, offsetBy: maxCharacters)
        return String(trimmedRawText[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
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

            if let label = Self.canonicalSpeakerLabel(segment.speakerLabel) {
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
        if hasDisplayText {
            lines.append(displayText)
        }
        return lines.joined(separator: "\n")
    }

    private mutating func ensureAliases() {
        let order = orderedSpeakerLabels
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

    private static func literalMatchCount(in text: String, for searchText: String) -> Int {
        guard !text.isEmpty, !searchText.isEmpty else { return 0 }

        var searchStart = text.startIndex
        var total = 0

        while searchStart < text.endIndex,
              let range = text.range(of: searchText, range: searchStart..<text.endIndex) {
            total += 1
            searchStart = range.upperBound
        }

        return total
    }

    private static func normalizedAliasKey(_ alias: String) -> String {
        alias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func playbackRange(forSegmentAt index: Int, audioDuration: TimeInterval?) -> PlaybackRange? {
        guard segments.indices.contains(index),
              let start = segments[index].start else {
            return nil
        }

        let explicitEnd = segments[index].end.flatMap { $0 > start ? $0 : nil }
        let nextStart: TimeInterval?
        if index + 1 < segments.count {
            nextStart = segments[(index + 1)...].compactMap(\.start).first.flatMap { $0 > start ? $0 : nil }
        } else {
            nextStart = nil
        }
        let fallbackEnd = min(start + 2.0, max(audioDuration ?? (start + 2.0), start + 0.5))
        let end = explicitEnd ?? nextStart ?? fallbackEnd
        guard end > start else { return nil }

        return PlaybackRange(start: start, end: end)
    }
}
