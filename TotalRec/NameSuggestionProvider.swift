import Foundation

enum NameSuggestionProvider: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case openAI = "openai"

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
