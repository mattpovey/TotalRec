import Foundation

struct OpenAITranscriber {
    struct Response: Decodable {
        struct Segment: Decodable {
            let speaker: String?
            let text: String
        }
        let text: String?
        let segments: [Segment]?
    }

    enum OpenAIError: Error, LocalizedError {
        case missingAPIKey
        case invalidResponse
        case httpError(Int, String)
        case encodingError

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "OpenAI API key is missing."
            case .invalidResponse: return "Invalid response from OpenAI."
            case .httpError(let code, let body): return "OpenAI HTTP error (\(code)): \(body)"
            case .encodingError: return "Failed to encode request."
            }
        }
    }

    func transcribeDiarized(
        audioURL: URL,
        apiKey: String,
        onProgress: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(OpenAIError.missingAPIKey)); return
        }

        // Prepare multipart/form-data
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        func appendFileField(name: String, filename: String, mimeType: String, fileData: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        // Required fields
        appendFormField(name: "model", value: "gpt-4o-transcribe-diarize")
        // Some diarization models auto-detect; if an explicit flag is needed, uncomment:
        // appendFormField(name: "diarize", value: "true")

        // File data
        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(.failure(OpenAIError.encodingError)); return
        }
        appendFileField(name: "file", filename: audioURL.lastPathComponent, mimeType: "audio/m4a", fileData: audioData)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error)); return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                completion(.failure(OpenAIError.invalidResponse)); return
            }
            guard 200..<300 ~= http.statusCode else {
                let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
                completion(.failure(OpenAIError.httpError(http.statusCode, bodyString)))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                if let segments = decoded.segments, !segments.isEmpty {
                    // Build a diarized transcript
                    let combined = segments.map { seg in
                        if let spk = seg.speaker, !spk.isEmpty {
                            return "\(spk): \(seg.text)"
                        } else {
                            return seg.text
                        }
                    }.joined(separator: "\n")
                    completion(.success(combined))
                } else if let text = decoded.text {
                    completion(.success(text))
                } else {
                    completion(.failure(OpenAIError.invalidResponse))
                }
            } catch {
                // Try to fallback to raw text body if API returns plain text
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(error))
                }
            }
        }
        task.resume()
    }

    func transcribeDiarized(
        audioURL: URL,
        apiKey: String,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            transcribeDiarized(audioURL: audioURL, apiKey: apiKey, onProgress: onProgress) { result in
                continuation.resume(with: result)
            }
        }
    }
}
