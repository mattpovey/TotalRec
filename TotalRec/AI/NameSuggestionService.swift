import Foundation

struct NameSuggestionService {
    struct SpeakerExcerpt: Identifiable {
        let id: UUID
        let label: String
        let alias: String
        let excerpt: String

        init(id: UUID = UUID(), label: String, alias: String, excerpt: String) {
            self.id = id
            self.label = label
            self.alias = alias
            self.excerpt = excerpt
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let name: String
    }

    enum ServiceError: LocalizedError {
        case excerptTooLong(labels: [String], limit: Int)
        case noSpeakers
        case missingAPIKey
        case invalidResponse
        case httpError(Int, String)
        case unsupportedProvider(String)

        var errorDescription: String? {
            switch self {
            case let .excerptTooLong(labels, limit):
                let joined = labels.joined(separator: ", ")
                return "Speaker excerpts for \(joined) exceed the \(limit)-character limit."
            case .noSpeakers:
                return "No speakers are available for name suggestions."
            case .missingAPIKey:
                return "API key is required for generating name suggestions."
            case .invalidResponse:
                return "The AI service returned an unexpected response."
            case let .httpError(code, body):
                return "AI service error (\(code)): \(body)"
            case let .unsupportedProvider(provider):
                return "Provider \(provider) is not supported for name suggestions."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .excerptTooLong:
                return "Trim the excerpts and try again."
            case .noSpeakers:
                return "Record or import a transcript before requesting suggestions."
            case .missingAPIKey:
                return "Add an API key in Settings and try again."
            case .invalidResponse, .httpError:
                return "Please try again in a moment."
            case .unsupportedProvider:
                return nil
            }
        }

        var userFacingMessage: String {
            let base = errorDescription ?? "An unknown error occurred."
            if let recovery = recoverySuggestion {
                return "\(base) \(recovery)"
            }
            return base
        }
    }

    let maxExcerptLength: Int

    init(maxExcerptLength: Int = 480) {
        self.maxExcerptLength = maxExcerptLength
    }

    func suggestAliases(for speakers: [SpeakerExcerpt]) async throws -> [Suggestion] {
        guard !speakers.isEmpty else {
            throw ServiceError.noSpeakers
        }

        let truncatedLabels = speakers
            .filter { $0.excerpt.count > maxExcerptLength }
            .map { $0.label }

        if !truncatedLabels.isEmpty {
            throw ServiceError.excerptTooLong(labels: truncatedLabels, limit: maxExcerptLength)
        }

        let provider = NameSuggestionProvider(
            rawValue: AIConfigManager.shared.configuration.nameSuggestionProvider.lowercased()
        ) ?? .openAI

        switch provider {
        case .disabled:
            print("[NameSuggestions][Service] Provider disabled. Using heuristic aliases for labels: \(speakers.map { $0.label })")
            return heuristicallySuggestAliases(for: speakers)
        case .openAI:
            print("[NameSuggestions][Service] Requesting OpenAI alias suggestions for labels: \(speakers.map { $0.label })")
            let labels = speakers.map { $0.label }
            let transcript = makeTranscript(from: speakers)
            let response: [String: String]
            do {
                response = try await suggestWithOpenAI(labels: labels, transcript: transcript)
            } catch {
                print("[NameSuggestions][Service] ERROR: \(error.localizedDescription)")
                throw error
            }

            guard !response.isEmpty else {
                print("[NameSuggestions][Service] OpenAI returned empty alias response; falling back to heuristics.")
                return heuristicallySuggestAliases(for: speakers)
            }

            return labels.map { label in
                let raw = response[label]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallback = speakers.first(where: { $0.label == label })?.alias ?? label
                let value = raw.isEmpty ? fallback : raw
                return Suggestion(label: label, name: value)
            }
        }
    }

    private func heuristicallySuggestAliases(for speakers: [SpeakerExcerpt]) -> [Suggestion] {
        return speakers.map { speaker in
            let sourceAlias = speaker.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerptWords = speaker.excerpt
                .split { $0.isWhitespace || $0.isNewline }
                .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
                .filter { !$0.isEmpty }

            let candidate = excerptWords.first ?? sourceAlias
            let fallback = sourceAlias.isEmpty ? speaker.label : sourceAlias
            let name = candidate.isEmpty ? fallback : candidate.prefix(1).uppercased() + candidate.dropFirst()
            return Suggestion(label: speaker.label, name: String(name))
        }
    }

    private func makeTranscript(from speakers: [SpeakerExcerpt]) -> String {
        speakers.map { speaker in
            let sanitized = sanitizeUtterance(speaker.excerpt)
            return "\(speaker.label): \(sanitized)"
        }
        .joined(separator: "\n")
    }

    func suggestNames(labels: [String], transcript: String) async throws -> [String: String] {
        guard !labels.isEmpty else { return [:] }

        let provider = NameSuggestionProvider(
            rawValue: AIConfigManager.shared.configuration.nameSuggestionProvider.lowercased()
        ) ?? .openAI
        print("[NameSuggestions][Service] suggestNames provider=\(provider.rawValue) labels=\(labels.count) transcriptChars=\(transcript.count)")

        switch provider {
        case .disabled:
            print("[NameSuggestions][Service] Provider disabled; returning empty suggestions.")
            return [:]
        case .openAI:
            let result = try await suggestWithOpenAI(labels: labels, transcript: transcript)
            print("[NameSuggestions][Service] OpenAI returned \(result.count) name suggestions.")
            return result
        }
    }

    // MARK: - OpenAI

    private struct ChatCompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct APISuggestion: Decodable {
        let label: String
        let name: String
    }

    private func suggestWithOpenAI(labels: [String], transcript: String) async throws -> [String: String] {
        guard let apiKey = AIConfigManager.shared.openAIKey(), !apiKey.isEmpty else {
            print("[NameSuggestions][Service] ERROR: Missing OpenAI API key")
            throw ServiceError.missingAPIKey
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw ServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let model = "gpt-5-mini"
        let prompt = buildPrompt(labels: labels, transcript: transcript)
        print("[NameSuggestions][Service] OpenAI prompt length: \(prompt.count) characters for labels: \(labels)")
        let systemMessage = ChatCompletionRequest.Message(
            role: "system",
            content: "You rename diarized speaker labels to human-friendly names. Return only JSON as instructed."
        )
        let userMessage = ChatCompletionRequest.Message(role: "user", content: prompt)
        let body = ChatCompletionRequest(
            model: model,
            messages: [systemMessage, userMessage]
        )
        request.httpBody = try JSONEncoder().encode(body)
        print("[NameSuggestions][Service] POST \(url.absoluteString) model=\(model) labels=\(labels.count)")

        let dataResponse: (Data, URLResponse)
        do {
            dataResponse = try await URLSession.shared.data(for: request)
        } catch {
            print("[NameSuggestions][Service] ERROR: \(error.localizedDescription)")
            throw error
        }
        let (data, response) = dataResponse
        guard let http = response as? HTTPURLResponse else {
            print("[NameSuggestions][Service] ERROR: Missing HTTPURLResponse")
            throw ServiceError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            print("[NameSuggestions][Service] OpenAI HTTP error \(http.statusCode): \(bodyString)")
            throw ServiceError.httpError(http.statusCode, bodyString)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let message = decoded.choices.first?.message.content else {
            print("[NameSuggestions][Service] ERROR: Empty choices in response")
            throw ServiceError.invalidResponse
        }
        print("[NameSuggestions][Service] OpenAI response body length: \(message.count)")

        return try parseSuggestions(from: message)
    }

    // MARK: - Prompt helpers

    private func buildPrompt(labels: [String], transcript: String) -> String {
        var excerptsByLabel: [String: [String]] = [:]
        let labelSet = Set(labels)
        let lines = transcript.components(separatedBy: CharacterSet.newlines)
        for rawLine in lines {
            guard let colonIndex = rawLine.firstIndex(of: ":") else { continue }
            let prefix = String(rawLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let normalizedLabel = normalizeLabel(prefix)
            guard labelSet.contains(normalizedLabel) else { continue }
            let remainderStart = rawLine.index(after: colonIndex)
            let utterance = rawLine[remainderStart...].trimmingCharacters(in: .whitespaces)
            guard !utterance.isEmpty else { continue }
            let cleaned = sanitizeUtterance(String(utterance))
            excerptsByLabel[normalizedLabel, default: []].append(cleaned)
        }

        var prompt = "Generate friendly names for diarized speakers. If a real name is mentioned, use it; otherwise suggest a concise role. Return JSON array: [{\"label\":\"SPEAKER_00\",\"name\":\"Alice\"}].\n\nTranscript excerpts by speaker:\n"

        for label in labels {
            let snippets = excerptsByLabel[label]?.prefix(5) ?? []
            prompt.append("Speaker \(label):\n")
            if snippets.isEmpty {
                prompt.append("- (no notable excerpts)\n")
            } else {
                for snippet in snippets {
                    prompt.append("- \(snippet)\n")
                }
            }
            prompt.append("\n")
        }

        prompt.append("Respond with only the JSON array and keep suggested names to 1-3 words.")
        return prompt
    }

    private func normalizeLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let parenIndex = trimmed.firstIndex(of: "(") {
            let base = trimmed[..<parenIndex]
            return base.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private func sanitizeUtterance(_ string: String) -> String {
        let condensedWhitespace = string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if condensedWhitespace.count > 160 {
            let index = condensedWhitespace.index(condensedWhitespace.startIndex, offsetBy: 160)
            return String(condensedWhitespace[..<index]) + "…"
        }
        return condensedWhitespace
    }

    private func parseSuggestions(from message: String) throws -> [String: String] {
        guard let jsonString = extractJSONString(from: message),
              let data = jsonString.data(using: .utf8) else {
            throw ServiceError.invalidResponse
        }

        if let array = try? JSONDecoder().decode([APISuggestion].self, from: data) {
            return Dictionary(uniqueKeysWithValues: array.map { ($0.label, $0.name) })
        }

        if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }

        print("[NameSuggestions][Service] ERROR: Suggestions returned in unexpected format")
        throw ServiceError.invalidResponse
    }

    private func extractJSONString(from message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "[", let endIndex = trimmed.lastIndex(of: "]"), endIndex >= trimmed.startIndex {
            return String(trimmed[trimmed.startIndex...endIndex])
        }
        if trimmed.first == "{", let endIndex = trimmed.lastIndex(of: "}"), endIndex >= trimmed.startIndex {
            return String(trimmed[trimmed.startIndex...endIndex])
        }
        if let startIndex = trimmed.firstIndex(of: "["), let endIndex = trimmed.lastIndex(of: "]"), endIndex > startIndex {
            return String(trimmed[startIndex...endIndex])
        }
        if let startIndex = trimmed.firstIndex(of: "{"), let endIndex = trimmed.lastIndex(of: "}"), endIndex > startIndex {
            return String(trimmed[startIndex...endIndex])
        }
        return nil
    }
}
