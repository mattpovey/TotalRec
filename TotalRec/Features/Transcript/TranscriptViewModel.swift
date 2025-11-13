import Foundation
import SwiftUI

@MainActor
final class TranscriptViewModel: ObservableObject {
    struct SpeakerState: Identifiable, Equatable {
        let id: UUID
        let label: String
        var alias: String
        var excerpt: String

        init(id: UUID = UUID(), label: String, alias: String, excerpt: String) {
            self.id = id
            self.label = label
            self.alias = alias
            self.excerpt = excerpt
        }
    }

    struct SuggestedAlias: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let name: String
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
    @Published private(set) var suggestions: [SuggestedAlias] = []
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

    func requestSuggestions() {
        guard !isRequestInFlight else { return }
        inFlightTask?.cancel()
        requestError = nil
        isRequestInFlight = true

        let payload = speakers.map { speaker in
            NameSuggestionService.SpeakerExcerpt(label: speaker.label, alias: speaker.alias, excerpt: speaker.excerpt)
        }

        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rawSuggestions = try await suggestionService.suggestAliases(for: payload)
                let mapped = rawSuggestions.map { SuggestedAlias(label: $0.label, name: $0.name) }
                self.suggestions = mapped
                self.showSuggestionSheet = !mapped.isEmpty
            } catch is CancellationError {
                // Ignore cancellation
            } catch {
                self.requestError = RequestError(error: error)
            }
            self.isRequestInFlight = false
            self.inFlightTask = nil
        }
    }

    func applySuggestions() {
        guard !suggestions.isEmpty else {
            showSuggestionSheet = false
            return
        }
        for suggestion in suggestions {
            if let index = speakers.firstIndex(where: { $0.label == suggestion.label }) {
                speakers[index].alias = suggestion.name
            }
        }
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
        for index in speakers.indices {
            speakers[index].alias = speakers[index].label
        }
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
