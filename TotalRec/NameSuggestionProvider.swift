import Foundation

enum NameSuggestionProvider: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case openAI = "openai"

    static var allCases: [NameSuggestionProvider] {
        if BuildFeatures.nameSuggestionsEnabled {
            return [.disabled, .openAI]
        }
        return [.disabled]
    }

    static var buildDefault: NameSuggestionProvider {
        BuildFeatures.nameSuggestionsEnabled ? .openAI : .disabled
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .openAI:
            return "OpenAI"
        }
    }
}
