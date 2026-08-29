import Foundation
import SwiftUI
import Combine

@MainActor
final class TranscriptViewModel: ObservableObject {
    struct SpeakerState: Identifiable, Equatable {
        var id: String { label }
        let label: String
        var alias: String
        var excerpt: String

        init(label: String, alias: String, excerpt: String) {
            self.label = label
            self.alias = alias
            self.excerpt = excerpt
        }
    }

    struct SuggestedAlias: Identifiable, Equatable {
        let id = UUID()
        let label: String
        var name: String
    }

    struct RequestError: Identifiable {
        let id = UUID()
        let message: String

        init(message: String) {
            self.message = message
        }

        init(error: Error) {
            if let serviceError = error as? NameSuggestionService.ServiceError {
                self.message = serviceError.userFacingMessage
            } else {
                self.message = error.localizedDescription
            }
        }
    }

    @Published var speakers: [SpeakerState]
    @Published var suggestions: [SuggestedAlias] = []
    @Published var isRequestInFlight = false
    @Published var requestError: RequestError?
    @Published var showSuggestionSheet = false

    private let suggestionService: NameSuggestionService
    private var inFlightTask: Task<Void, Never>?

    init(speakers: [SpeakerState], suggestionService: NameSuggestionService = NameSuggestionService()) {
        self.speakers = speakers
        self.suggestionService = suggestionService
    }

    init(transcript: TranscriptState, suggestionService: NameSuggestionService = NameSuggestionService()) {
        self.suggestionService = suggestionService
        self.speakers = TranscriptViewModel.makeSpeakerStates(
            from: transcript,
            maxExcerptLength: suggestionService.maxExcerptLength
        )
    }

    convenience init(numberOfSpeakers: Int, suggestionService: NameSuggestionService = NameSuggestionService()) {
        let labels = Self.defaultLabels(count: numberOfSpeakers)
        let states = labels.enumerated().map { index, label in
            SpeakerState(label: label, alias: label, excerpt: "Speaker \(label) sample excerpt #\(index + 1).")
        }
        self.init(speakers: states, suggestionService: suggestionService)
    }

    func update(from transcript: TranscriptState) {
        let newStates = TranscriptViewModel.makeSpeakerStates(
            from: transcript,
            maxExcerptLength: suggestionService.maxExcerptLength
        )

        if newStates != speakers {
            speakers = newStates
            suggestions = []
            showSuggestionSheet = false
            inFlightTask?.cancel()
            inFlightTask = nil
            isRequestInFlight = false
            requestError = nil
        }

        if newStates.isEmpty {
            requestError = nil
        }
    }

    @discardableResult
    func applyAliases(to transcript: inout TranscriptState) -> Bool {
        var updated = false

        for speaker in speakers {
            let current = transcript.alias(for: speaker.label)
            if current != speaker.alias {
                transcript.setAlias(speaker.alias, for: speaker.label)
                updated = true
            }
        }

        return updated
    }

    func updateAlias(_ alias: String, for label: String) {
        guard let index = speakers.firstIndex(where: { $0.label == label }) else {
            return
        }

        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAlias = trimmed.isEmpty ? label : trimmed
        guard speakers[index].alias != resolvedAlias else {
            return
        }

        var updated = speakers
        updated[index].alias = resolvedAlias
        speakers = updated
    }

    func updateExcerpt(_ excerpt: String, for label: String) {
        guard let index = speakers.firstIndex(where: { $0.label == label }) else {
            return
        }

        guard speakers[index].excerpt != excerpt else {
            return
        }

        var updated = speakers
        updated[index].excerpt = excerpt
        speakers = updated
    }

    func requestSuggestions() {
        guard !isRequestInFlight else { return }
        inFlightTask?.cancel()
        requestError = nil
        isRequestInFlight = true

        let payload = speakers.map { speaker in
            NameSuggestionService.SpeakerExcerpt(label: speaker.label, alias: speaker.alias, excerpt: speaker.excerpt)
        }
        print("[NameSuggestions][TranscriptViewModel] Requesting alias suggestions for labels: \(payload.map { $0.label })")

        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rawSuggestions = try await suggestionService.suggestAliases(for: payload)
                print("[NameSuggestions][TranscriptViewModel] Received alias suggestions: \(rawSuggestions)")
                let mapped = rawSuggestions.map { SuggestedAlias(label: $0.label, name: $0.name) }
                self.suggestions = mapped
                self.showSuggestionSheet = !mapped.isEmpty
            } catch is CancellationError {
                // Ignore cancellation
            } catch {
                self.requestError = RequestError(error: error)
                print("[NameSuggestions][TranscriptViewModel] Alias suggestion failed: \(error.localizedDescription)")
            }
            self.isRequestInFlight = false
            self.inFlightTask = nil
        }
    }

    func requestSuggestions(using transcript: TranscriptState) {
        guard !isRequestInFlight else { return }
        inFlightTask?.cancel()
        requestError = nil
        isRequestInFlight = true

        // Use the same approach as the top-level button: labels from transcript and full transcript text
        let labels = transcript.orderedSpeakerLabels
        let formatter = TranscriptFormatter(transcript: transcript)
        let rawText = formatter.joinedRawSpeakerText()
        let fullText = rawText.isEmpty ? formatter.joinedPlainText() : rawText
        print("[NameSuggestions][TranscriptViewModel] Requesting provider suggestions for labels: \(labels). Raw text length: \(rawText.count)")

        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Prefer provider-backed suggestions by full transcript
                let dict = try await suggestionService.suggestNames(labels: labels, transcript: fullText)
                var mapped: [SuggestedAlias] = []
                if !dict.isEmpty {
                    print("[NameSuggestions][TranscriptViewModel] Provider returned dict: \(dict)")
                    let normalized = self.normalizeSuggestionDictionary(dict)
                    print("[NameSuggestions][TranscriptViewModel] Normalized suggestion keys: \(normalized.keys.sorted())")
                    mapped = labels.enumerated().map { index, label in
                        let value = self.candidateValue(for: label, index: index, normalized: normalized)
                        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let fallback = self.speakers.first(where: { $0.label == label })?.alias ?? label
                        let final = trimmedValue.isEmpty ? fallback : trimmedValue
                        return SuggestedAlias(label: label, name: final)
                    }
                } else {
                    // Fallback to heuristic/local suggestion using existing speaker excerpts
                    print("[NameSuggestions][TranscriptViewModel] Provider returned empty dict; falling back to heuristics.")
                    let payload = self.speakers.map { s in
                        NameSuggestionService.SpeakerExcerpt(label: s.label, alias: s.alias, excerpt: s.excerpt)
                    }
                    let raw = try await suggestionService.suggestAliases(for: payload)
                    print("[NameSuggestions][TranscriptViewModel] Heuristic suggestions: \(raw)")
                    mapped = raw.map { SuggestedAlias(label: $0.label, name: $0.name) }
                }
                print("[NameSuggestions][TranscriptViewModel] Final mapped suggestions: \(mapped)")
                self.suggestions = mapped
                self.showSuggestionSheet = !mapped.isEmpty
            } catch is CancellationError {
                // Ignore cancellation
            } catch {
                self.requestError = RequestError(error: error)
                print("[NameSuggestions][TranscriptViewModel] Provider suggestion failed: \(error.localizedDescription)")
            }
            self.isRequestInFlight = false
            self.inFlightTask = nil
        }
    }

    private func normalizeSuggestionDictionary(_ dict: [String: String]) -> [String: String] {
        return dict.reduce(into: [String: String]()) { result, entry in
            let value = entry.value
            let rawKey = entry.key

            func store(_ key: String) {
                guard !key.isEmpty else { return }
                result[key] = value
            }

            store(rawKey)

            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            store(trimmed)
            store(trimmed.uppercased())

            let base = trimmed.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
            store(base)
            store(base.uppercased())

            if trimmed.uppercased().hasPrefix("SPEAKER") {
                let suffix = trimmed.dropFirst("SPEAKER".count)
                let cleanedSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "_ -:"))
                if !cleanedSuffix.isEmpty {
                    store(cleanedSuffix)
                    store(cleanedSuffix.uppercased())
                }
                let numericPortion = cleanedSuffix.trimmingCharacters(in: CharacterSet.letters)
                if !numericPortion.isEmpty {
                    store("__index_\(numericPortion)")
                    if let digits = Int(numericPortion) {
                        store("__index_\(digits)")
                    }
                }
            }

            let numericOnly = trimmed.filter { $0.isNumber }
            if !numericOnly.isEmpty {
                store("__index_\(numericOnly)")
                if let number = Int(numericOnly) {
                    store("__index_\(number)")
                }
            }
        }
    }

    private func candidateValue(for label: String, index: Int, normalized: [String: String]) -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercaseLabel = trimmedLabel.uppercased()

        let formattedIndex = String(format: "%02d", index)
        let indexCandidates = ["__index_\(index)", "__index_\(formattedIndex)", formattedIndex]

        let labelCandidates = [label, trimmedLabel, uppercaseLabel, "SPEAKER_\(trimmedLabel)", "SPEAKER_\(uppercaseLabel)"]

        for key in labelCandidates + indexCandidates {
            if let value = normalized[key] { return value }
        }

        return nil
    }

    func applySuggestions() {
        guard !suggestions.isEmpty else {
            showSuggestionSheet = false
            return
        }
        var updated = speakers
        for suggestion in suggestions {
            if let index = updated.firstIndex(where: { $0.label == suggestion.label }) {
                let trimmed = suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated[index].alias = trimmed.isEmpty ? updated[index].label : trimmed
            }
        }
        speakers = updated // trigger @Published update
        showSuggestionSheet = false
    }

    func chooseManualEditing() {
        showSuggestionSheet = false
    }

    func retrySuggestions() {
        showSuggestionSheet = false
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.requestSuggestions()
        }
    }

    func resetAliases() {
        var updated = speakers
        for index in updated.indices {
            updated[index].alias = updated[index].label
        }
        speakers = updated // trigger @Published update
    }

    func dismissError() {
        requestError = nil
    }

    func dismissSuggestions() {
        showSuggestionSheet = false
    }

    private static func makeSpeakerStates(from transcript: TranscriptState, maxExcerptLength: Int) -> [SpeakerState] {
        let limit = max(maxExcerptLength, 1)

        let groupedSegments = transcript.segments.reduce(into: [String: [TranscriptSegment]]()) { partialResult, segment in
            guard let label = segment.speakerLabel, !label.isEmpty else { return }
            partialResult[label, default: []].append(segment)
        }

        return transcript.orderedSpeakerLabels.map { label in
            let alias = transcript.alias(for: label)
            let segments = groupedSegments[label] ?? []
            let texts = segments.map { $0.text }
            let excerpt = makeExcerpt(from: texts, fallback: alias, maxLength: limit)
            return SpeakerState(label: label, alias: alias, excerpt: excerpt)
        }
    }

    private static func makeExcerpt(from texts: [String], fallback: String, maxLength: Int) -> String {
        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return fallback }

        if joined.count <= maxLength {
            return joined
        }

        let index = joined.index(joined.startIndex, offsetBy: maxLength)
        var truncated = String(joined[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        if truncated.isEmpty { return fallback }
        if truncated.count < joined.count {
            truncated.append("…")
        }
        return truncated
    }

    private static func defaultLabels(count: Int) -> [String] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard count <= alphabet.count else {
            return (0..<count).map { "S\($0 + 1)" }
        }
        return (0..<count).map { String(alphabet[$0]) }
    }
}
