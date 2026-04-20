import Foundation

enum LLMProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI = "openai"
    case sambaNova = "sambanova"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .sambaNova:
            return "SambaNova"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .sambaNova:
            return "https://api.sambanova.ai/v1"
        }
    }

    func defaultModelID(for feature: LLMFeature) -> String {
        switch (self, feature) {
        case (.openAI, .insights), (.openAI, .nameSuggestions):
            return "gpt-5-mini"
        case (.sambaNova, .insights), (.sambaNova, .nameSuggestions):
            return "Meta-Llama-3.3-70B-Instruct"
        }
    }
}

enum LLMFeature: String, Codable, Sendable {
    case insights
    case nameSuggestions
}

struct ProviderModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    enum Lifecycle: String, Codable, Sendable {
        case production
        case preview
        case deprecated
        case unknown
    }

    var id: String
    var displayName: String
    var provider: LLMProvider
    var contextWindow: Int?
    var supportsStreaming: Bool
    var supportsJSONMode: Bool
    var lifecycle: Lifecycle

    var isPreview: Bool {
        lifecycle == .preview
    }

    func supports(feature: LLMFeature) -> Bool {
        guard isTextGenerationModel else { return false }

        switch feature {
        case .insights:
            return supportsStreaming
        case .nameSuggestions:
            return true
        }
    }

    private var isTextGenerationModel: Bool {
        let normalized = id.lowercased()
        let blockedTokens = [
            "whisper",
            "tts",
            "embedding",
            "embeddings",
            "text-embedding",
            "omni-moderation",
            "moderation",
            "e5-",
            "asr"
        ]
        return blockedTokens.allSatisfy { !normalized.contains($0) }
    }
}

struct LLMProviderConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var cachedModels: [ProviderModelDescriptor]
    var modelsUpdatedAt: Date?

    init(
        baseURL: String,
        cachedModels: [ProviderModelDescriptor] = [],
        modelsUpdatedAt: Date? = nil
    ) {
        self.baseURL = baseURL
        self.cachedModels = cachedModels
        self.modelsUpdatedAt = modelsUpdatedAt
    }
}

struct LLMResolvedConfiguration {
    let provider: LLMProvider
    let baseURL: URL
    let apiKey: String
    let modelID: String
}
