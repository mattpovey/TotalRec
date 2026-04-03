import Foundation

private final class TScriptSessionDelegate: NSObject, URLSessionDelegate {
    private let allowedHost: String?
    private let allowInvalidTLSCertificates: Bool

    init(allowedHost: String?, allowInvalidTLSCertificates: Bool) {
        self.allowedHost = allowedHost?.lowercased()
        self.allowInvalidTLSCertificates = allowInvalidTLSCertificates
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard allowInvalidTLSCertificates,
              let allowedHost,
              challenge.protectionSpace.host.lowercased() == allowedHost,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct TScriptTranscriber {
    struct TranscriptionResult {
        let transcriptState: TranscriptState
        let warning: String?
    }

    struct APIResponse: Decodable {
        struct TimestampWord: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
        }

        struct TimestampPayload: Decodable {
            let word: [TimestampWord]?
        }

        let transcript: String?
        let modelID: String?
        let engine: String?
        let processingSeconds: Double?
        let warning: String?
        let diarizationBackend: String?
        let speakerOutput: String?
        let timestamps: TimestampPayload?

        enum CodingKeys: String, CodingKey {
            case transcript
            case modelID = "model_id"
            case engine
            case processingSeconds = "processing_seconds"
            case warning
            case diarizationBackend = "diarization_backend"
            case speakerOutput = "speaker_output"
            case timestamps
        }
    }

    struct APIErrorResponse: Decodable {
        let error: String?
        let errorCode: String?
        let detail: String?
        let retryAfterSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case error
            case errorCode = "error_code"
            case detail
            case retryAfterSeconds = "retry_after_seconds"
        }
    }

    enum TranscriberError: LocalizedError {
        case invalidBaseURL(String)
        case noModelsAvailable
        case invalidResponse
        case missingTranscript
        case modelUnavailable(String)
        case unsupportedDiarization(String)
        case insecureConnectionRequiresOverride
        case httpError(Int, String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let value):
                return "Invalid TScript base URL: \(value)"
            case .noModelsAvailable:
                return "No TScript models are available from the server."
            case .invalidResponse:
                return "Invalid response from the TScript server."
            case .missingTranscript:
                return "The TScript server returned no transcript."
            case .modelUnavailable(let modelID):
                return "Selected TScript model is unavailable: \(modelID)"
            case .unsupportedDiarization(let modelID):
                return "Selected TScript model does not support the requested diarization mode: \(modelID)"
            case .insecureConnectionRequiresOverride:
                return "TScript requires HTTPS by default. Enable the insecure HTTP override in Settings if you want to use a plain HTTP endpoint."
            case .httpError(let status, let message):
                return "TScript HTTP error (\(status)): \(message)"
            case .networkError(let message):
                return message
            }
        }
    }

    func fetchModelRegistry(configuration: TScriptConfiguration) async throws -> TScriptModelsResponse {
        let requestURL = try endpointURL(configuration: configuration, path: "models")
        let session = makeSession(for: requestURL, configuration: configuration)
        let (data, response) = try await data(from: requestURL, session: session, configuration: configuration)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriberError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw TranscriberError.httpError(
                httpResponse.statusCode,
                errorMessage(from: data) ?? "Model registry request failed."
            )
        }
        return try JSONDecoder().decode(TScriptModelsResponse.self, from: data)
    }

    func transcribe(
        audioURL: URL,
        configuration: TScriptTranscriptionRunConfiguration
    ) async throws -> TranscriptionResult {
        let registry = try await fetchModelRegistry(configuration: configuration.configuration)
        let model = try resolveModel(in: registry, configuration: configuration.configuration)
        let outputFormat = chooseOutputFormat(for: model, configuration: configuration.configuration)
        let requestURL = try endpointURL(configuration: configuration.configuration, path: "transcribe")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try buildMultipartBody(
            boundary: boundary,
            audioURL: audioURL,
            model: model,
            configuration: configuration.configuration,
            outputFormat: outputFormat
        )
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let session = makeSession(for: requestURL, configuration: configuration.configuration)
        let (data, response) = try await data(for: request, session: session, configuration: configuration.configuration)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriberError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw TranscriberError.httpError(
                httpResponse.statusCode,
                errorMessage(from: data) ?? "Transcription request failed."
            )
        }

        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let transcriptState = try parseTranscriptState(
            responseData: data,
            response: decoded,
            model: model,
            outputFormat: outputFormat
        )
        return TranscriptionResult(
            transcriptState: transcriptState,
            warning: transcriptionWarning(from: decoded, requestedConfiguration: configuration.configuration)
        )
    }

    private func endpointURL(configuration: TScriptConfiguration, path: String) throws -> URL {
        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriberError.invalidBaseURL(configuration.baseURL)
        }
        let normalized: String
        if trimmed.contains("://") {
            normalized = trimmed
        } else {
            normalized = "https://\(trimmed)"
        }
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw TranscriberError.invalidBaseURL(configuration.baseURL)
        }
        if scheme == "http" && !configuration.allowInsecureHTTP {
            throw TranscriberError.insecureConnectionRequiresOverride
        }
        return url.appendingPathComponent(path)
    }

    private func makeSession(for url: URL, configuration: TScriptConfiguration) -> URLSession {
        let delegate = TScriptSessionDelegate(
            allowedHost: url.host,
            allowInvalidTLSCertificates: configuration.allowInvalidTLSCertificates
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        return URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    private func data(
        from url: URL,
        session: URLSession,
        configuration: TScriptConfiguration
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(from: url)
        } catch {
            throw translateNetworkError(error, configuration: configuration)
        }
    }

    private func data(
        for request: URLRequest,
        session: URLSession,
        configuration: TScriptConfiguration
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw translateNetworkError(error, configuration: configuration)
        }
    }

    private func translateNetworkError(
        _ error: Error,
        configuration: TScriptConfiguration
    ) -> Error {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error }

        switch nsError.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return TranscriberError.insecureConnectionRequiresOverride
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasBadDate:
            if configuration.allowInvalidTLSCertificates {
                return TranscriberError.networkError(
                    "The TScript server's TLS certificate is still failing even with invalid-certificate override enabled."
                )
            }
            return TranscriberError.networkError(
                "The TScript server's TLS certificate is not trusted. Enable the invalid TLS certificate override in Settings only if you trust this server."
            )
        case NSURLErrorSecureConnectionFailed:
            if configuration.allowInvalidTLSCertificates {
                return TranscriberError.networkError(
                    "A TLS error caused the secure connection to fail even with invalid-certificate override enabled. This usually indicates a server-side TLS configuration problem."
                )
            }
            return TranscriberError.networkError(
                "A TLS error caused the secure connection to fail. If this is a self-signed or locally issued certificate, you can enable the invalid TLS certificate override in Settings."
            )
        default:
            return error
        }
    }

    private func resolveModel(
        in registry: TScriptModelsResponse,
        configuration: TScriptConfiguration
    ) throws -> TScriptModel {
        let preferredID = configuration.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackID = registry.defaultModelID.flatMap { registry.models[$0]?.runtimeAvailable == true ? $0 : nil }
            ?? registry.allModels.first(where: \.runtimeAvailable)?.id
            ?? registry.allModels.first?.id
        guard let resolvedID = preferredID.isEmpty ? fallbackID : preferredID else {
            throw TranscriberError.noModelsAvailable
        }
        guard let model = registry.models[resolvedID] else {
            throw TranscriberError.modelUnavailable(resolvedID)
        }
        guard model.runtimeAvailable else {
            throw TranscriberError.modelUnavailable(resolvedID)
        }
        let diarizationMode = model.normalizedDiarizationMode(configuration.diarizationMode)
        if diarizationMode != .off,
           !model.availableDiarizationModes.contains(diarizationMode) {
            throw TranscriberError.unsupportedDiarization(model.id)
        }
        return model
    }

    private func chooseOutputFormat(
        for model: TScriptModel,
        configuration: TScriptConfiguration
    ) -> String {
        let formats = model.supportedOutputFormats
        let diarizationMode = model.normalizedDiarizationMode(configuration.diarizationMode)
        if diarizationMode != .off {
            if formats.contains("diarized-json") {
                return "diarized-json"
            }
            if formats.contains("json-full") {
                return "json-full"
            }
            if formats.contains("json") {
                return "json"
            }
        }
        if configuration.timestamps {
            if formats.contains("json") {
                return "json"
            }
            if formats.contains("json-full") {
                return "json-full"
            }
        }
        return formats.contains("txt") ? "txt" : (formats.first ?? "txt")
    }

    private func buildMultipartBody(
        boundary: String,
        audioURL: URL,
        model: TScriptModel,
        configuration: TScriptConfiguration,
        outputFormat: String
    ) throws -> Data {
        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw TranscriberError.invalidResponse
        }

        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        func appendPresenceField(_ name: String) {
            appendField(name, "true")
        }

        func appendFile(name: String, filename: String, mimeType: String, data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField("model_id", model.id)
        appendField("output-format", outputFormat)

        let language = configuration.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.acceptsLanguageSelection, !language.isEmpty {
            appendField("language", language)
        }
        if model.supportsTranslation, configuration.translate {
            appendField("translate", "true")
        }
        if model.supportsTimestamps, configuration.timestamps {
            appendField("timestamps", "true")
        }

        let diarizationMode = model.normalizedDiarizationMode(configuration.diarizationMode)
        if diarizationMode != .off,
           let backend = model.preferredDiarizationBackend {
            appendField("enable_diarization", "true")
            appendField("diarization_backend", backend)
            if model.supportsSegmentSpeakerOutput {
                appendField("speaker_output", "segments")
            }
            appendTrimmedField("num_speakers", configuration.numSpeakers, append: appendField)
            appendTrimmedField("min_speakers", configuration.minSpeakers, append: appendField)
            appendTrimmedField("max_speakers", configuration.maxSpeakers, append: appendField)
        }

        if model.isWhisperEngine {
            if configuration.advanced.flashAttention {
                appendField("fa", "true")
            }
            if configuration.advanced.splitOnWord {
                appendPresenceField("split-on-word")
            }
            appendTrimmedField("threads", configuration.advanced.threads, append: appendField)
            appendTrimmedField("processors", configuration.advanced.processors, append: appendField)
            appendTrimmedField("max-context", configuration.advanced.maxContext, append: appendField)
            appendTrimmedField("max-len", configuration.advanced.maxLen, append: appendField)
            appendTrimmedField("word-thold", configuration.advanced.wordThreshold, append: appendField)
            appendTrimmedField("best-of", configuration.advanced.bestOf, append: appendField)
            appendTrimmedField("beam-size", configuration.advanced.beamSize, append: appendField)
        }

        appendFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: mimeType(for: audioURL),
            data: audioData
        )

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func appendTrimmedField(
        _ name: String,
        _ value: String,
        append: (String, String) -> Void
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(name, trimmed)
    }

    private func mimeType(for audioURL: URL) -> String {
        switch audioURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "aac":
            return "audio/aac"
        case "ogg":
            return "audio/ogg"
        case "mp4":
            return "audio/mp4"
        default:
            return "application/octet-stream"
        }
    }

    private func errorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            let message = [decoded.error, decoded.detail]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !message.isEmpty {
                return message
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func parseTranscriptState(
        responseData: Data,
        response: APIResponse,
        model: TScriptModel,
        outputFormat: String
    ) throws -> TranscriptState {
        let fullResponseObject = try? JSONSerialization.jsonObject(with: responseData)

        if outputFormat == "diarized-json",
           let fullResponseObject,
           let parsed = parseStructuredResponseObject(fullResponseObject, transcriptText: response.transcript) {
            return parsed
        }

        if let parsed = parseStructuredTranscript(
            from: response.transcript,
            model: model,
            outputFormat: outputFormat
        ) {
            return parsed
        }

        if let fullResponseObject,
           let parsed = parseStructuredResponseObject(fullResponseObject, transcriptText: response.transcript) {
            return parsed
        }

        if let transcript = response.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcript.isEmpty {
            return TranscriptState(rawText: transcript)
        }

        throw TranscriberError.missingTranscript
    }

    private func parseStructuredTranscript(
        from transcript: String?,
        model: TScriptModel,
        outputFormat: String
    ) -> TranscriptState? {
        guard let transcript else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard outputFormat.contains("json") || trimmed.first == "{" || trimmed.first == "[" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return parseStructuredResponseObject(jsonObject, transcriptText: transcript, defaultEngine: model.engine)
    }

    private func parseStructuredResponseObject(
        _ object: Any,
        transcriptText: String?,
        defaultEngine: String? = nil
    ) -> TranscriptState? {
        guard let dictionary = object as? [String: Any] else { return nil }

        let aliasMap = extractSpeakerAliases(from: dictionary)
        let segmentCandidates = [
            "turns",
            "speaker_segments",
            "segments",
            "utterances",
            "transcription",
            "asr_segments"
        ]

        for key in segmentCandidates {
            if let items = dictionary[key] as? [Any] {
                let parsedSegments = items.compactMap(parseSegment)
                if !parsedSegments.isEmpty {
                    let combinedText = bestTranscriptText(from: dictionary, fallback: transcriptText, segments: parsedSegments)
                    return TranscriptState(
                        segments: parsedSegments,
                        rawText: combinedText,
                        speakerAliases: aliasMap
                    )
                }
            }
        }

        if let nested = dictionary["transcript"] as? [String: Any],
           let parsed = parseStructuredResponseObject(nested, transcriptText: transcriptText, defaultEngine: defaultEngine) {
            return parsed
        }

        return nil
    }

    private func bestTranscriptText(
        from dictionary: [String: Any],
        fallback: String?,
        segments: [TranscriptSegment]
    ) -> String {
        if let value = string(in: dictionary, keys: ["stitched_transcript", "combined_text", "text", "transcript"]), !value.isEmpty {
            return value
        }
        if let fallback {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.first != "{", trimmed.first != "[" {
                return trimmed
            }
        }
        return segments.map(\.text).joined(separator: "\n")
    }

    private func parseSegment(_ value: Any) -> TranscriptSegment? {
        guard let dictionary = value as? [String: Any] else { return nil }

        let text = string(in: dictionary, keys: ["text", "transcript", "utterance", "content"])
        guard let text, !text.isEmpty else { return nil }

        let speakerLabel = TranscriptState.canonicalSpeakerLabel(speakerLabel(in: dictionary))
        let start = startTime(in: dictionary)
        let end = endTime(in: dictionary)

        return TranscriptSegment(
            speakerLabel: speakerLabel,
            text: text,
            start: start,
            end: end
        )
    }

    private func extractSpeakerAliases(from dictionary: [String: Any]) -> [String: String] {
        if let mapping = dictionary["speakers"] as? [String: String] {
            return normalizedAliasMap(mapping)
        }
        if let items = dictionary["speakers"] as? [[String: Any]] {
            var aliases: [String: String] = [:]
            for item in items {
                guard let id = string(in: item, keys: ["id", "speaker", "speaker_id", "label"]),
                      let name = string(in: item, keys: ["name", "display_name", "speaker_name"]) else {
                    continue
                }
                if let canonical = TranscriptState.canonicalSpeakerLabel(id) {
                    aliases[canonical] = name
                }
            }
            return aliases
        }
        if let items = dictionary["speaker_objects"] as? [[String: Any]] {
            var aliases: [String: String] = [:]
            for item in items {
                guard let id = string(in: item, keys: ["id", "speaker", "speaker_id", "label", "key"]),
                      let name = string(in: item, keys: ["name", "display_name", "speaker_name", "label"]) else {
                    continue
                }
                if let canonical = TranscriptState.canonicalSpeakerLabel(id) {
                    aliases[canonical] = name
                }
            }
            return aliases
        }
        return [:]
    }

    private func speakerLabel(in dictionary: [String: Any]) -> String? {
        if let speaker = dictionary["speaker"] as? String, !speaker.isEmpty {
            return speaker
        }
        if let speaker = dictionary["speaker_label"] as? String, !speaker.isEmpty {
            return speaker
        }
        if let speaker = dictionary["speaker_id"] as? String, !speaker.isEmpty {
            return speaker
        }
        if let nestedSpeaker = dictionary["speaker"] as? [String: Any] {
            return string(in: nestedSpeaker, keys: ["id", "label", "name"])
        }
        return nil
    }

    private func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? Double {
                return value
            }
            if let value = dictionary[key] as? Int {
                return Double(value)
            }
            if let value = dictionary[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func normalizedAliasMap(_ mapping: [String: String]) -> [String: String] {
        mapping.reduce(into: [String: String]()) { result, entry in
            guard let canonical = TranscriptState.canonicalSpeakerLabel(entry.key) else { return }
            result[canonical] = entry.value
        }
    }

    private func startTime(in dictionary: [String: Any]) -> Double? {
        if let direct = number(in: dictionary, keys: ["start", "start_time", "start_sec", "begin", "from"]) {
            return direct
        }
        if let offsets = dictionary["offsets"] as? [String: Any],
           let milliseconds = number(in: offsets, keys: ["from", "start", "begin"]) {
            return milliseconds / 1000.0
        }
        if let timestamps = dictionary["timestamps"] as? [String: Any] {
            return timecode(in: timestamps, keys: ["from", "start", "begin"])
        }
        return nil
    }

    private func endTime(in dictionary: [String: Any]) -> Double? {
        if let direct = number(in: dictionary, keys: ["end", "end_time", "end_sec", "stop", "to"]) {
            return direct
        }
        if let offsets = dictionary["offsets"] as? [String: Any],
           let milliseconds = number(in: offsets, keys: ["to", "end", "stop"]) {
            return milliseconds / 1000.0
        }
        if let timestamps = dictionary["timestamps"] as? [String: Any] {
            return timecode(in: timestamps, keys: ["to", "end", "stop"])
        }
        return nil
    }

    private func timecode(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
            let components = normalized.split(separator: ":")
            guard components.count >= 2 else { continue }

            let secondsComponent = Double(components.last ?? "") ?? 0
            let minutesComponent = Double(components.dropLast().last ?? "") ?? 0
            let hoursComponent = components.count > 2 ? (Double(components.dropLast(2).last ?? "") ?? 0) : 0
            return (hoursComponent * 3600) + (minutesComponent * 60) + secondsComponent
        }
        return nil
    }

    private func transcriptionWarning(
        from response: APIResponse,
        requestedConfiguration: TScriptConfiguration
    ) -> String? {
        let trimmedWarning = response.warning?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedWarning, !trimmedWarning.isEmpty {
            return trimmedWarning
        }

        guard requestedConfiguration.diarizationMode != .off else { return nil }
        if response.speakerOutput?.lowercased() == "none" || response.diarizationBackend?.lowercased() == "none" {
            return "The TScript server did not return diarized speaker output for this run."
        }
        return nil
    }
}
