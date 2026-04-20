import Foundation

enum NameSuggestionProvider: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case openAI = "openai"
    case sambaNova = "sambanova"

    static var allCases: [NameSuggestionProvider] {
        if BuildFeatures.nameSuggestionsEnabled {
            return [.disabled, .openAI, .sambaNova]
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
        case .sambaNova:
            return "SambaNova"
        }
    }

    var llmProvider: LLMProvider? {
        switch self {
        case .disabled:
            return nil
        case .openAI:
            return .openAI
        case .sambaNova:
            return .sambaNova
        }
    }
}
