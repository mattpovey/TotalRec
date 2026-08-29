import Foundation

struct ConversationTransport: TextGeneratingTransport {
    enum TransportError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        case missingCompletion

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The conversation transport returned an unexpected response."
            case let .httpError(statusCode, body):
                return "Conversation transport failed (HTTP \(statusCode)): \(body)"
            case .missingCompletion:
                return "The conversation stream ended before completion."
            }
        }
    }

    struct StreamParser {
        enum ParsedEvent: Equatable {
            case started
            case textDelta(String)
            case completed
            case failed(String)
        }

        private var dataLines: [String] = []

        mutating func push(line: String) throws -> [ParsedEvent] {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty {
                return try flushCurrentEvent()
            }

            if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix(":") {
                if !dataLines.isEmpty {
                    return try flushCurrentEvent()
                }
                return []
            }

            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") {
                    value.removeFirst()
                }
                return try appendPayloadLine(value)
            }

            if trimmedLine == "[DONE]" || trimmedLine.first == "{" || trimmedLine.first == "[" {
                return try appendPayloadLine(trimmedLine)
            }

            if !dataLines.isEmpty {
                return try flushCurrentEvent()
            }

            return []
        }

        mutating func finish() throws -> [ParsedEvent] {
            try flushCurrentEvent()
        }

        private mutating func appendPayloadLine(_ value: String) throws -> [ParsedEvent] {
            if shouldFlushBeforeAppending(value) {
                let events = try flushCurrentEvent()
                dataLines.append(value)
                return events
            }

            dataLines.append(value)
            return []
        }

        private func shouldFlushBeforeAppending(_ value: String) -> Bool {
            guard !dataLines.isEmpty else { return false }

            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedValue == "[DONE]" || trimmedValue.first == "{" || trimmedValue.first == "[" else {
                return false
            }

            return Self.canDecodePayload(dataLines.joined(separator: "\n"))
        }

        private mutating func flushCurrentEvent() throws -> [ParsedEvent] {
            guard !dataLines.isEmpty else { return [] }
            defer { dataLines.removeAll(keepingCapacity: true) }

            let payload = dataLines.joined(separator: "\n")
            if payload == "[DONE]" {
                return [.completed]
            }

            let envelope: [String: Any]
            do {
                let data = Data(payload.utf8)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let parsed = object as? [String: Any] else {
                    throw TransportError.invalidResponse
                }
                envelope = parsed
            } catch {
                DiagnosticsLogger.logError(
                    category: "ConversationTransport",
                    message: "Failed to decode SSE payload as JSON.",
                    error: error,
                    metadata: ["payload": DiagnosticsLogger.preview(payload)]
                )
                throw error
            }

            if let error = envelope["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [.failed(message)]
            }

            guard let choices = envelope["choices"] as? [[String: Any]] else {
                return []
            }

            var events: [ParsedEvent] = []
            for choice in choices {
                if let finishReason = choice["finish_reason"] as? String,
                   !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append(.completed)
                }

                if let delta = choice["delta"] as? [String: Any] {
                    if let content = delta["content"] as? String, !content.isEmpty {
                        events.append(.textDelta(content))
                    } else if let parts = delta["content"] as? [[String: Any]] {
                        let joined = parts.compactMap { $0["text"] as? String }.joined()
                        if !joined.isEmpty {
                            events.append(.textDelta(joined))
                        }
                    } else if delta["role"] != nil {
                        events.append(.started)
                    }
                }
            }

            if events.isEmpty, envelope["id"] != nil {
                events.append(.started)
            }

            return events
        }

        private static func canDecodePayload(_ payload: String) -> Bool {
            guard payload != "[DONE]" else { return true }
            guard let data = payload.data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) != nil
        }
    }

    private struct ChatCompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
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

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var kind: TextGenerationTransportKind { .conversation }

    func generateText(
        _ request: TextGenerationRequest,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        onEvent(.started)
        DiagnosticsLogger.log(
            category: "ConversationTransport",
            message: "Starting conversation text generation request.",
            metadata: [
                "provider": request.provider.displayName,
                "url": endpoint(for: request).absoluteString,
                "model": request.modelID,
                "stream": request.preferStreaming ? "true" : "false",
                "promptChars": "\(request.prompt.count)"
            ]
        )

        do {
            return try await generateText(
                request,
                preferStreaming: request.preferStreaming,
                onEvent: onEvent
            )
        } catch is CancellationError {
            DiagnosticsLogger.log(
                category: "ConversationTransport",
                message: "Conversation text generation cancelled.",
                metadata: [
                    "provider": request.provider.displayName,
                    "model": request.modelID
                ]
            )
            throw CancellationError()
        } catch let TransportError.httpError(statusCode, body)
            where request.provider == .sambaNova && request.preferStreaming && statusCode == 401 {
            DiagnosticsLogger.log(
                category: "ConversationTransport",
                message: "Retrying SambaNova request without streaming after 401 response.",
                metadata: [
                    "model": request.modelID,
                    "body": DiagnosticsLogger.preview(body)
                ]
            )

            do {
                return try await generateText(
                    request,
                    preferStreaming: false,
                    onEvent: onEvent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DiagnosticsLogger.logError(
                    category: "ConversationTransport",
                    message: "SambaNova retry without streaming failed.",
                    error: error,
                    metadata: [
                        "model": request.modelID
                    ]
                )
                onEvent(.failed(error.localizedDescription))
                throw error
            }
        } catch {
            DiagnosticsLogger.logError(
                category: "ConversationTransport",
                message: "Conversation text generation failed.",
                error: error,
                metadata: [
                    "provider": request.provider.displayName,
                    "model": request.modelID,
                    "stream": request.preferStreaming ? "true" : "false"
                ]
            )
            onEvent(.failed(error.localizedDescription))
            throw error
        }
    }

    private func endpoint(for request: TextGenerationRequest) -> URL {
        request.baseURL.appendingPathComponent("chat/completions")
    }

    private func generateText(
        _ request: TextGenerationRequest,
        preferStreaming: Bool,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> String {
        let urlRequest = try makeURLRequest(for: request, preferStreaming: preferStreaming)

        if preferStreaming {
            return try await generateStreamingText(with: urlRequest, onEvent: onEvent)
        }

        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            DiagnosticsLogger.log(
                category: "ConversationTransport",
                message: "Conversation request failed with non-success HTTP status.",
                metadata: [
                    "provider": request.provider.displayName,
                    "statusCode": "\(http.statusCode)",
                    "body": DiagnosticsLogger.preview(body, limit: 4_000)
                ]
            )
            throw TransportError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw TransportError.invalidResponse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        onEvent(.textDelta(trimmed))
        onEvent(.completed(trimmed))
        DiagnosticsLogger.log(
            category: "ConversationTransport",
            message: "Conversation text generation completed successfully.",
            metadata: [
                "provider": request.provider.displayName,
                "model": request.modelID,
                "stream": "false",
                "outputChars": "\(trimmed.count)"
            ]
        )
        return trimmed
    }

    private func makeURLRequest(
        for request: TextGenerationRequest,
        preferStreaming: Bool
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint(for: request))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue(preferStreaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [ChatCompletionRequest.Message] = []
        if let systemInstruction = request.systemInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemInstruction.isEmpty {
            messages.append(.init(role: "system", content: systemInstruction))
        }
        messages.append(.init(role: "user", content: request.prompt))

        let payload = ChatCompletionRequest(
            model: request.modelID,
            messages: messages,
            stream: preferStreaming
        )
        urlRequest.httpBody = try JSONEncoder().encode(payload)
        return urlRequest
    }

    private func generateStreamingText(
        with request: URLRequest,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> String {
        var parser = StreamParser()
        var collectedText = ""
        var didComplete = false
        var didEmitFailure = false

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let body = try await readBody(from: bytes)
            DiagnosticsLogger.log(
                category: "ConversationTransport",
                message: "Streaming conversation request failed with non-success HTTP status.",
                metadata: [
                    "statusCode": "\(http.statusCode)",
                    "body": DiagnosticsLogger.preview(body, limit: 4_000)
                ]
            )
            throw TransportError.httpError(http.statusCode, body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = try parser.push(line: line)
            try apply(
                events,
                collectedText: &collectedText,
                didComplete: &didComplete,
                didEmitFailure: &didEmitFailure,
                onEvent: onEvent
            )
        }

        let trailingEvents = try parser.finish()
        try apply(
            trailingEvents,
            collectedText: &collectedText,
            didComplete: &didComplete,
            didEmitFailure: &didEmitFailure,
            onEvent: onEvent
        )

        let finalText = collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard didComplete || !finalText.isEmpty else {
            throw TransportError.missingCompletion
        }

        if !didComplete {
            onEvent(.completed(finalText))
        }

        DiagnosticsLogger.log(
            category: "ConversationTransport",
            message: "Streaming conversation text generation completed successfully.",
            metadata: [
                "outputChars": "\(finalText.count)"
            ]
        )

        return finalText
    }

    private func apply(
        _ events: [StreamParser.ParsedEvent],
        collectedText: inout String,
        didComplete: inout Bool,
        didEmitFailure: inout Bool,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) throws {
        for event in events {
            switch event {
            case .started:
                onEvent(.started)
            case let .textDelta(delta):
                collectedText.append(delta)
                onEvent(.textDelta(delta))
            case .completed:
                didComplete = true
                let finalText = collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                onEvent(.completed(finalText))
            case let .failed(message):
                didEmitFailure = true
                onEvent(.failed(message))
                throw NSError(
                    domain: "TotalRec.ConversationTransport",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }
    }

    private func readBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? "<no body>"
    }
}
