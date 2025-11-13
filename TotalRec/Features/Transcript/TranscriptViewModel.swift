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

    convenience init(numberOfSpeakers: Int, suggestionService: NameSuggestionService = NameSuggestionService()) {
        let labels = Self.defaultLabels(count: numberOfSpeakers)
        let states = labels.enumerated().map { index, label in
            SpeakerState(label: label, alias: label, excerpt: "Speaker \(label) sample excerpt #\(index + 1).")
        }
        self.init(speakers: states, suggestionService: suggestionService)
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

    private static func defaultLabels(count: Int) -> [String] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard count <= alphabet.count else {
            return (0..<count).map { "S\($0 + 1)" }
        }
        return (0..<count).map { String(alphabet[$0]) }
    }
}
