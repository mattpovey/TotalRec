import Foundation

// MARK: - OpenAI Key Storage Helpers
private extension OpenAITranscriber {
    func savedAPIKey() -> String? {
        return AIConfigManager.shared.openAIKey()
    }

    func saveAPIKey(_ key: String) {
        do {
            try AIConfigManager.shared.updateOpenAIKey(key)
        } catch {
            print("[OpenAITranscriber] ERROR: Failed to persist OpenAI key: \(error)")
        }
    }
}

struct OpenAITranscriber {
    struct KnownSpeaker {
        let name: String
        let reference: String?
        init(name: String, reference: String? = nil) {
            self.name = name
            self.reference = reference
        }
    }

    struct Response: Decodable {
        struct Segment: Decodable {
            let speaker: String?
            let text: String
            let id: String?
            let type: String?
            let start: Double?
            let end: Double?

            enum CodingKeys: String, CodingKey { case speaker, speaker_label, text, id, type, start, end }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.text = try c.decode(String.self, forKey: .text)
                if let spk = try? c.decode(String.self, forKey: .speaker) {
                    self.speaker = spk
                } else if let spk2 = try? c.decode(String.self, forKey: .speaker_label) {
                    self.speaker = spk2
                } else {
                    self.speaker = nil
                }
                self.id = try? c.decode(String.self, forKey: .id)
                self.type = try? c.decode(String.self, forKey: .type)
                self.start = try? c.decode(Double.self, forKey: .start)
                self.end = try? c.decode(Double.self, forKey: .end)
            }
        }
        struct Diarization: Decodable { let segments: [Segment]? }
        let text: String?
        let segments: [Segment]?
        let diarization: Diarization?
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
    
    private func logError(_ message: String) {
        print("[OpenAITranscriber] ERROR: \(message)")
    }
    
    private func normalizeReferenceToDataURL(_ ref: String, onProgress: ((String) -> Void)?) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // If already a data URL, pass through
        if trimmed.lowercased().hasPrefix("data:audio/") && trimmed.contains(";base64,") {
            return trimmed
        }
        // If it's a file URL string or a local path, try to read and base64-encode
        if let url = URL(string: trimmed), url.isFileURL {
            do {
                let data = try Data(contentsOf: url)
                let b64 = data.base64EncodedString()
                // Attempt to infer mime type from extension
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "wav": mime = "audio/wav"
                case "m4a": mime = "audio/m4a"
                case "mp3": mime = "audio/mpeg"
                case "aac": mime = "audio/aac"
                default: mime = "audio/wav"
                }
                return "data:\(mime);base64,\(b64)"
            } catch {
                onProgress?("Failed to read reference file: \(url.lastPathComponent)")
                return nil
            }
        }
        // If it's a bare path (no scheme), try to read it as a local file
        if !trimmed.contains("://") {
            let url = URL(fileURLWithPath: trimmed)
            do {
                let data = try Data(contentsOf: url)
                let b64 = data.base64EncodedString()
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "wav": mime = "audio/wav"
                case "m4a": mime = "audio/m4a"
                case "mp3": mime = "audio/mpeg"
                case "aac": mime = "audio/aac"
                default: mime = "audio/wav"
                }
                return "data:\(mime);base64,\(b64)"
            } catch {
                onProgress?("Failed to read reference path: \(url.lastPathComponent)")
                return nil
            }
        }
        // Unsupported (e.g., http/https). The API requires base64-encoded audio data.
        onProgress?("Known speaker reference must be a base64 data URL or local file path. Ignoring: \(trimmed)")
        return nil
    }

    func transcribeDiarized(
        audioURL: URL,
        apiKey: String,
        baseURL: String = "https://api.openai.com",
        chunkingStrategy: String = "auto", // "auto" or "none"
        knownSpeakerNames: [String]? = nil,
        knownSpeakerReferences: [String]? = nil,
        knownSpeakers: [KnownSpeaker]? = nil,
        onProgress: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Use provided key if present; otherwise fall back to saved key
        var effectiveAPIKey = apiKey
        if effectiveAPIKey.isEmpty, let stored = savedAPIKey(), !stored.isEmpty {
            effectiveAPIKey = stored
        }
        // If a new key is provided, persist it
        if !apiKey.isEmpty && apiKey != savedAPIKey() {
            saveAPIKey(apiKey)
        }

        guard !effectiveAPIKey.isEmpty else {
            logError("API key is missing")
            completion(.failure(OpenAIError.missingAPIKey)); return
        }

        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/audio/transcriptions") else {
            logError("Invalid base URL: \(baseURL)")
            completion(.failure(OpenAIError.invalidResponse)); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(effectiveAPIKey)", forHTTPHeaderField: "Authorization")
        // Deleted the line that set Content-Type with a new UUID boundary early to avoid mismatch

        // Ensure OpenAI is set as the default provider in the configuration
        if AIConfigManager.shared.configuration.defaultProvider.lowercased() != "openai" {
            do { try AIConfigManager.shared.setDefaultProvider("openai") } catch {
                self.logError("Failed to set default provider to OpenAI: \(error)")
            }
        }

        let boundary = "Boundary-\(UUID().uuidString)"
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
        func appendArrayField(name: String, values: [String]) {
            for v in values {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)[]\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(v)\r\n".data(using: .utf8)!)
            }
        }

        // Required fields
        appendFormField(name: "model", value: "gpt-4o-transcribe-diarize")
        appendFormField(name: "chunking_strategy", value: chunkingStrategy)
        // Removed diarize and speaker_labels fields
        appendFormField(name: "response_format", value: "diarized_json")

        // Known speakers: prefer structured `knownSpeakers`, else fall back to separate arrays. Cap at 4.
        if let speakers = knownSpeakers, !speakers.isEmpty {
            let limited = Array(speakers.prefix(4))
            if speakers.count > 4 {
                onProgress?("Known speakers limited to 4; truncating to first 4.")
            }
            // Names from all provided speakers (non-empty names assumed by caller)
            let names = limited.map { $0.name }
            // Try to normalize each reference; keep nil when not provided/convertible
            let normalizedOptionals: [String?] = limited.map { spk in
                if let r = spk.reference, let norm = normalizeReferenceToDataURL(r, onProgress: onProgress) { return norm }
                return nil
            }
            // If every speaker has a valid reference (equal count), include references; else omit references entirely
            let allHaveRefs = normalizedOptionals.allSatisfy { $0 != nil }
            if !names.isEmpty { appendArrayField(name: "known_speaker_names", values: names) }
            if allHaveRefs {
                let refs = normalizedOptionals.compactMap { $0 }
                appendArrayField(name: "known_speaker_references", values: refs)
            } else if normalizedOptionals.contains(where: { $0 != nil }) {
                onProgress?("Some known speaker references were provided but not all; omitting references to satisfy API requirements.")
            }
        } else {
            let namesRaw = (knownSpeakerNames ?? [])
            let refsRaw = (knownSpeakerReferences ?? [])
            if !namesRaw.isEmpty || !refsRaw.isEmpty {
                let limitedNames = Array(namesRaw.prefix(4))
                let limitedRefsRaw = Array(refsRaw.prefix(4))
                // Normalize any provided refs; entries that cannot be normalized become nil
                let normalizedRefs: [String?] = limitedRefsRaw.map { normalizeReferenceToDataURL($0, onProgress: onProgress) }
                // Only include references if we have exactly one per name and none are nil
                if !limitedNames.isEmpty { appendArrayField(name: "known_speaker_names", values: limitedNames) }
                if normalizedRefs.count == limitedNames.count && normalizedRefs.allSatisfy({ $0 != nil }) {
                    appendArrayField(name: "known_speaker_references", values: normalizedRefs.compactMap { $0 })
                } else if normalizedRefs.contains(where: { $0 != nil }) {
                    onProgress?("Known speaker references are optional; since not all were provided/valid, they were omitted to avoid API errors.")
                }
            }
        }

        // File data
        guard let audioData = try? Data(contentsOf: audioURL) else {
            logError("Failed to read audio data from: \(audioURL.path)")
            completion(.failure(OpenAIError.encodingError)); return
        }
        appendFileField(name: "file", filename: audioURL.lastPathComponent, mimeType: "audio/m4a", fileData: audioData)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError? {
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotFindHost {
                    self.logError("Cannot resolve host: \(url.host ?? "<unknown>")")
                    completion(.failure(OpenAIError.httpError(error.code, "Cannot resolve host: \(url.host ?? "<unknown>")")))
                    return
                }
                self.logError("Network error: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                self.logError("No HTTP response or no data returned")
                completion(.failure(OpenAIError.invalidResponse)); return
            }
            guard 200..<300 ~= http.statusCode else {
                let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
                self.logError("HTTP \(http.statusCode) response: \(bodyString)")
                completion(.failure(OpenAIError.httpError(http.statusCode, bodyString)))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                let diarizedSegments = decoded.segments ?? decoded.diarization?.segments
                if let segments = diarizedSegments, !segments.isEmpty {
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
                    self.logError("No text or segments found in response JSON")
                    completion(.failure(OpenAIError.invalidResponse))
                }
            } catch {
                self.logError("JSON decode failed: \(error.localizedDescription)")
                // Try to fallback to raw text body if API returns plain text
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    self.logError("Falling back to raw text body due to decode failure")
                    completion(.success(text))
                } else {
                    self.logError("No decodable JSON and empty body; failing with decode error")
                    completion(.failure(error))
                }
            }
        }
        task.resume()
    }

    func transcribeDiarized(
        audioURL: URL,
        apiKey: String,
        knownSpeakerNames: [String]? = nil,
        knownSpeakerReferences: [String]? = nil,
        knownSpeakers: [KnownSpeaker]? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            transcribeDiarized(
                audioURL: audioURL,
                apiKey: apiKey,
                knownSpeakerNames: knownSpeakerNames,
                knownSpeakerReferences: knownSpeakerReferences,
                knownSpeakers: knownSpeakers,
                onProgress: onProgress
            ) { result in
                continuation.resume(with: result)
            }
        }
    }
}

