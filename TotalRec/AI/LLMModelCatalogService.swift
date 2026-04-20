import Foundation

struct LLMModelCatalogService {
    enum ServiceError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The model catalog returned an unexpected response."
            case let .httpError(statusCode, body):
                return "Model catalog request failed (HTTP \(statusCode)): \(body)"
            }
        }
    }

    private struct ModelListResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let created: TimeInterval?
            let ownedBy: String?

            enum CodingKeys: String, CodingKey {
                case id
                case created
                case ownedBy = "owned_by"
            }
        }

        let data: [Model]
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(for provider: LLMProvider) async throws -> [ProviderModelDescriptor] {
        let access = try AIConfigManager.shared.resolvedProviderAccess(for: provider)
        var request = URLRequest(url: access.baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(access.apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw ServiceError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return decoded.data
            .map { model in
                ProviderModelDescriptor(
                    id: model.id,
                    displayName: model.id,
                    provider: provider,
                    contextWindow: nil,
                    supportsStreaming: true,
                    supportsJSONMode: provider == .openAI || provider == .sambaNova,
                    lifecycle: .unknown
                )
            }
            .filter { $0.supports(feature: .insights) || $0.supports(feature: .nameSuggestions) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
