import Foundation

struct TScriptModelsResponse: Decodable {
    let defaultModelID: String?
    let models: [String: TScriptModel]

    enum CodingKeys: String, CodingKey {
        case defaultModelID = "default_model_id"
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID)
        let wrappedModels = try container.decode([String: TScriptModelWrapper].self, forKey: .models)
        self.models = wrappedModels.unwrappedModels
    }
}

struct TScriptModel: Equatable, Identifiable {
    struct Supports: Decodable, Equatable {
        let fileUpload: Bool?
        let fileURL: Bool?
        let translate: Bool?
        let language: Bool?
        let timestamps: Bool?
        let outputFormats: [String]?

        enum CodingKeys: String, CodingKey {
            case fileUpload = "file_upload"
            case fileURL = "file_url"
            case translate
            case language
            case timestamps
            case outputFormats = "output_formats"
        }
    }

    struct Capabilities: Decodable, Equatable {
        struct Inputs: Decodable, Equatable {
            let fileUpload: Bool?
            let fileURL: Bool?
            let acceptedAudioExtensions: [String]?

            enum CodingKeys: String, CodingKey {
                case fileUpload = "file_upload"
                case fileURL = "file_url"
                case acceptedAudioExtensions = "accepted_audio_extensions"
            }
        }

        struct Outputs: Decodable, Equatable {
            let formats: [String]?
            let timecodeFormats: [String]?
            let diarizedJSON: Bool?
            let responseFields: [String]?

            enum CodingKeys: String, CodingKey {
                case formats
                case timecodeFormats = "timecode_formats"
                case diarizedJSON = "diarized_json"
                case responseFields = "response_fields"
            }
        }

        struct Features: Decodable, Equatable {
            let languageSelection: Bool?
            let translation: Bool?
            let timestamps: Bool?
            let pyannoteDiarization: Bool?
            let legacyWhisperDiarization: Bool?
            let legacyTinydiarize: TinydiarizeSupport?

            enum CodingKeys: String, CodingKey {
                case languageSelection = "language_selection"
                case translation
                case timestamps
                case pyannoteDiarization = "pyannote_diarization"
                case legacyWhisperDiarization = "legacy_whisper_diarization"
                case legacyTinydiarize = "legacy_tinydiarize"
            }
        }

        struct Diarization: Decodable, Equatable {
            let supportedBackends: [String]?
            let speakerOutputModes: [String]?
            let supportsDiarizedJSON: Bool?

            enum CodingKeys: String, CodingKey {
                case supportedBackends = "supported_backends"
                case speakerOutputModes = "speaker_output_modes"
                case supportsDiarizedJSON = "supports_diarized_json"
            }
        }

        struct SwitchMetadata: Decodable, Equatable, Identifiable {
            let field: String
            let kind: String
            let description: String?

            var id: String { field }
        }

        let inputs: Inputs?
        let outputs: Outputs?
        let features: Features?
        let diarization: Diarization?
        let switches: [SwitchMetadata]?
    }

    enum TinydiarizeSupport: Decodable, Equatable {
        case unavailable
        case supported(Bool)
        case status(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .supported(value)
            } else if let value = try? container.decode(String.self) {
                self = .status(value)
            } else {
                self = .unavailable
            }
        }
    }

    let id: String
    let displayName: String
    let engine: String
    let backendModel: String?
    let supports: Supports?
    let capabilities: Capabilities?
    let status: String?
    let notes: String?
    let runtimeAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case engine
        case backendModel = "backend_model"
        case supports
        case capabilities
        case status
        case notes
        case runtimeAvailable = "runtime_available"
    }

    init(id: String, from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = id
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        self.engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? "unknown"
        self.backendModel = try container.decodeIfPresent(String.self, forKey: .backendModel)
        self.supports = try container.decodeIfPresent(Supports.self, forKey: .supports)
        self.capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.runtimeAvailable = try container.decodeIfPresent(Bool.self, forKey: .runtimeAvailable) ?? false
    }
}

private struct TScriptModelWrapper: Decodable {
    let model: TScriptModel

    init(from decoder: Decoder) throws {
        guard let key = decoder.codingPath.last?.stringValue else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing model identifier in coding path."
                )
            )
        }
        self.model = try TScriptModel(id: key, from: decoder)
    }
}

extension TScriptModelsResponse {
    var allModels: [TScriptModel] {
        models.values.sorted { lhs, rhs in
            if lhs.runtimeAvailable != rhs.runtimeAvailable {
                return lhs.runtimeAvailable && !rhs.runtimeAvailable
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

extension TScriptModel {
    var supportedOutputFormats: [String] {
        capabilities?.outputs?.formats ?? supports?.outputFormats ?? []
    }

    var timecodeFormats: [String] {
        capabilities?.outputs?.timecodeFormats ?? []
    }

    var acceptsLanguageSelection: Bool {
        capabilities?.features?.languageSelection
            ?? supports?.language
            ?? false
    }

    var supportsTranslation: Bool {
        capabilities?.features?.translation
            ?? supports?.translate
            ?? false
    }

    var supportsTimestamps: Bool {
        capabilities?.features?.timestamps
            ?? supports?.timestamps
            ?? false
    }

    var supportsDiarizedJSON: Bool {
        capabilities?.diarization?.supportsDiarizedJSON
            ?? capabilities?.outputs?.diarizedJSON
            ?? supportedOutputFormats.contains("diarized-json")
    }

    var supportedDiarizationBackends: [String] {
        capabilities?.diarization?.supportedBackends ?? []
    }

    var supportedSpeakerOutputModes: [String] {
        capabilities?.diarization?.speakerOutputModes ?? []
    }

    var supportsSegmentSpeakerOutput: Bool {
        if supportedSpeakerOutputModes.isEmpty {
            return supportsDiarizedJSON || capabilities?.features?.pyannoteDiarization == true
        }
        return supportedSpeakerOutputModes.contains("segments")
    }

    var supportsStandardDiarization: Bool {
        if !supportedDiarizationBackends.isEmpty {
            return supportedDiarizationBackends.contains(where: { $0 != "none" }) && supportsSegmentSpeakerOutput
        }
        if capabilities?.features?.pyannoteDiarization == true {
            return true
        }
        if capabilities?.features?.legacyWhisperDiarization == true {
            return true
        }
        return supportsDiarizedJSON
    }

    var supportsTinyDiarization: Bool {
        switch capabilities?.features?.legacyTinydiarize {
        case .supported(let value):
            return value
        case .status(let value):
            return value.lowercased() == "supported"
        case .unavailable, .none:
            return false
        }
    }

    var availableDiarizationModes: [TScriptDiarizationMode] {
        var modes: [TScriptDiarizationMode] = [.off]
        if supportsStandardDiarization {
            modes.append(.standard)
        }
        return modes
    }

    func normalizedDiarizationMode(_ mode: TScriptDiarizationMode) -> TScriptDiarizationMode {
        switch mode {
        case .off:
            return .off
        case .standard:
            return supportsStandardDiarization ? .standard : .off
        case .tiny:
            return supportsStandardDiarization ? .standard : .off
        }
    }

    var preferredDiarizationBackend: String? {
        if let backend = supportedDiarizationBackends.first(where: { $0 == "pyannote_community" }) {
            return backend
        }
        if let backend = supportedDiarizationBackends.first(where: { $0 != "none" }) {
            return backend
        }
        if supportsStandardDiarization {
            return "pyannote_community"
        }
        return nil
    }

    var isWhisperEngine: Bool {
        engine == "whisper_cpp"
    }
}

extension Dictionary where Key == String, Value == TScriptModelWrapper {
    var unwrappedModels: [String: TScriptModel] {
        reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value.model
        }
    }
}
