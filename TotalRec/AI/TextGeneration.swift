import Foundation

struct TextGenerationRequest {
    let provider: LLMProvider
    let baseURL: URL
    let apiKey: String
    let systemInstruction: String?
    let prompt: String
    let inputText: String
    let modelID: String
    let preferStreaming: Bool
    let outputExpectations: String?
}

enum TextGenerationEvent: Equatable {
    case started
    case textDelta(String)
    case completed(String)
    case failed(String)
}

protocol TextGeneratingTransport {
    var kind: TextGenerationTransportKind { get }
    func generateText(
        _ request: TextGenerationRequest,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> String
}
