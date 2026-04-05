import Foundation

struct ResponsesTransport: TextGeneratingTransport {
    enum TransportError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        case missingCompletion

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The Responses transport returned an unexpected response."
            case let .httpError(statusCode, body):
                return "Responses transport failed (HTTP \(statusCode)): \(body)"
            case .missingCompletion:
                return "The Responses stream ended before completion."
            }
        }
    }

    struct StreamParser {
        enum ParsedEvent: Equatable {
            case started
            case textDelta(String)
            case completed(String?)
            case failed(String)
        }

        private var dataLines: [String] = []

        mutating func push(line: String) throws -> [ParsedEvent] {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                dataLines.append(value)
                return []
            }

            if !dataLines.isEmpty {
                return try flushCurrentEvent()
            }

            return []
        }

        mutating func finish() throws -> [ParsedEvent] {
            try flushCurrentEvent()
        }

        private mutating func flushCurrentEvent() throws -> [ParsedEvent] {
            guard !dataLines.isEmpty else { return [] }
            defer { dataLines.removeAll(keepingCapacity: true) }

            let payload = dataLines.joined(separator: "\n")
            if payload == "[DONE]" {
                return []
            }

            let envelope: [String: Any]
            do {
                let data = Data(payload.utf8)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let parsed = object as? [String: Any] else {
                    DiagnosticsLogger.log(
                        category: "ResponsesTransport",
                        message: "Received non-dictionary SSE payload.",
                        metadata: ["payload": DiagnosticsLogger.preview(payload)]
                    )
                    throw NSError(
                        domain: "TotalRec.ResponsesTransport",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Responses stream parse failed. See diagnostics log for details."]
                    )
                }
                envelope = parsed
            } catch {
                DiagnosticsLogger.logError(
                    category: "ResponsesTransport",
                    message: "Failed to decode SSE payload as JSON.",
                    error: error,
                    metadata: ["payload": DiagnosticsLogger.preview(payload)]
                )
                throw NSError(
                    domain: "TotalRec.ResponsesTransport",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Responses stream parse failed. See diagnostics log for details."]
                )
            }

            guard let type = envelope["type"] as? String else {
                DiagnosticsLogger.log(
                    category: "ResponsesTransport",
                    message: "Received SSE payload without a type field.",
                    metadata: ["payload": DiagnosticsLogger.preview(payload)]
                )
                throw NSError(
                    domain: "TotalRec.ResponsesTransport",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Responses stream parse failed. See diagnostics log for details."]
                )
            }

            switch type {
            case "response.created", "response.in_progress":
                return [.started]
            case "response.output_text.delta":
                guard let delta = envelope["delta"] as? String, !delta.isEmpty else { return [] }
                return [.textDelta(delta)]
            case "response.output_text.done":
                guard let text = envelope["text"] as? String else { return [] }
                return [.completed(text)]
            case "response.completed", "response.done":
                return [.completed(Self.outputText(from: envelope["response"]))]
            case "response.failed", "error":
                let message = Self.errorMessage(from: envelope) ?? "The response stream failed."
                DiagnosticsLogger.log(
                    category: "ResponsesTransport",
                    message: "Received failure event from Responses stream.",
                    metadata: [
                        "eventType": type,
                        "message": message
                    ]
                )
                return [.failed(message)]
            default:
                return []
            }
        }

        private static func outputText(from response: Any?) -> String? {
            guard let response = response as? [String: Any],
                  let output = response["output"] as? [Any] else {
                return nil
            }

            return output
                .compactMap { item in
                    guard let item = item as? [String: Any],
                          (item["type"] as? String) == "message",
                          let content = item["content"] as? [Any] else {
                        return nil
                    }
                    return content
                        .compactMap { part in
                            guard let part = part as? [String: Any],
                                  (part["type"] as? String) == "output_text" else {
                                return nil
                            }
                            return part["text"] as? String
                        }
                        .joined()
                }
                .joined()
        }

        private static func errorMessage(from envelope: [String: Any]) -> String? {
            if let error = envelope["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }

            if let response = envelope["response"] as? [String: Any],
               let error = response["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }

            if let message = envelope["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }

            return nil
        }
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var kind: TextGenerationTransportKind { .responses }

    func generateText(
        _ request: TextGenerationRequest,
        onEvent: @escaping (TextGenerationEvent) -> Void
    ) async throws -> String {
        try Task.checkCancellation()

        DiagnosticsLogger.log(
            category: "ResponsesTransport",
            message: "Starting Responses text generation request.",
            metadata: [
                "model": request.modelID,
                "stream": request.preferStreaming ? "true" : "false",
                "promptChars": "\(request.prompt.count)",
                "inputChars": "\(request.inputText.count)"
            ]
        )

        var urlRequest = URLRequest(url: request.baseURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: request))

        var parser = StreamParser()
        var collectedText = ""
        var completedText: String?
        var didEmitFailure = false

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.invalidResponse
            }
            guard 200..<300 ~= http.statusCode else {
                let body = try await readBody(from: bytes)
                DiagnosticsLogger.log(
                    category: "ResponsesTransport",
                    message: "Responses request failed with non-success HTTP status.",
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
                    completedText: &completedText,
                    didEmitFailure: &didEmitFailure,
                    onEvent: onEvent
                )
            }

            try Task.checkCancellation()
            let trailingEvents = try parser.finish()
            try apply(
                trailingEvents,
                collectedText: &collectedText,
                completedText: &completedText,
                didEmitFailure: &didEmitFailure,
                onEvent: onEvent
            )

            let finalText = completedText ?? collectedText
            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransportError.missingCompletion
            }
            DiagnosticsLogger.log(
                category: "ResponsesTransport",
                message: "Responses text generation completed successfully.",
                metadata: ["outputChars": "\(finalText.count)"]
            )
            return finalText
        } catch is CancellationError {
            DiagnosticsLogger.log(
                category: "ResponsesTransport",
                message: "Responses text generation cancelled."
            )
            throw CancellationError()
        } catch {
            DiagnosticsLogger.logError(
                category: "ResponsesTransport",
                message: "Responses text generation failed.",
                error: error
            )
            if !didEmitFailure {
                onEvent(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    private func requestBody(for request: TextGenerationRequest) -> [String: Any] {
        var payload: [String: Any] = [
            "model": request.modelID,
            "input": request.prompt,
            "stream": request.preferStreaming,
            "text": [
                "format": [
                    "type": "text"
                ]
            ]
        ]

        if let systemInstruction = request.systemInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemInstruction.isEmpty {
            payload["instructions"] = systemInstruction
        }

        return payload
    }

    private func apply(
        _ events: [StreamParser.ParsedEvent],
        collectedText: inout String,
        completedText: inout String?,
        didEmitFailure: inout Bool,
        onEvent: @escaping (TextGenerationEvent) -> Void
    ) throws {
        for event in events {
            switch event {
            case .started:
                onEvent(.started)
            case let .textDelta(delta):
                collectedText.append(delta)
                onEvent(.textDelta(delta))
            case let .completed(serverText):
                let finalText = serverText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? serverText!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                completedText = finalText
                onEvent(.completed(finalText))
            case let .failed(message):
                didEmitFailure = true
                onEvent(.failed(message))
                throw NSError(
                    domain: "TotalRec.ResponsesTransport",
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
