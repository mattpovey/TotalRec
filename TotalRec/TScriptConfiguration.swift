import Foundation

enum TScriptDiarizationMode: String, CaseIterable, Codable, Identifiable {
    case off
    case standard
    case tiny

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .standard:
            return "Pyannote"
        case .tiny:
            return "Legacy Tiny"
        }
    }
}

struct TScriptAdvancedOptions: Codable, Equatable {
    var flashAttention: Bool
    var splitOnWord: Bool
    var threads: String
    var processors: String
    var maxContext: String
    var maxLen: String
    var wordThreshold: String
    var bestOf: String
    var beamSize: String

    init(
        flashAttention: Bool = false,
        splitOnWord: Bool = false,
        threads: String = "",
        processors: String = "",
        maxContext: String = "",
        maxLen: String = "",
        wordThreshold: String = "",
        bestOf: String = "",
        beamSize: String = ""
    ) {
        self.flashAttention = flashAttention
        self.splitOnWord = splitOnWord
        self.threads = threads
        self.processors = processors
        self.maxContext = maxContext
        self.maxLen = maxLen
        self.wordThreshold = wordThreshold
        self.bestOf = bestOf
        self.beamSize = beamSize
    }
}

struct TScriptConfiguration: Codable, Equatable {
    var baseURL: String
    var selectedModelID: String
    var language: String
    var translate: Bool
    var timestamps: Bool
    var diarizationMode: TScriptDiarizationMode
    var numSpeakers: String
    var minSpeakers: String
    var maxSpeakers: String
    var allowInsecureHTTP: Bool
    var allowInvalidTLSCertificates: Bool
    var advanced: TScriptAdvancedOptions

    enum CodingKeys: String, CodingKey {
        case baseURL
        case selectedModelID
        case language
        case translate
        case timestamps
        case diarizationMode
        case numSpeakers
        case minSpeakers
        case maxSpeakers
        case allowInsecureHTTP
        case allowInvalidTLSCertificates
        case advanced
    }

    init(
        baseURL: String = "",
        selectedModelID: String = "",
        language: String = "en",
        translate: Bool = false,
        timestamps: Bool = false,
        diarizationMode: TScriptDiarizationMode = .off,
        numSpeakers: String = "",
        minSpeakers: String = "",
        maxSpeakers: String = "",
        allowInsecureHTTP: Bool = false,
        allowInvalidTLSCertificates: Bool = false,
        advanced: TScriptAdvancedOptions = TScriptAdvancedOptions()
    ) {
        self.baseURL = baseURL
        self.selectedModelID = selectedModelID
        self.language = language
        self.translate = translate
        self.timestamps = timestamps
        self.diarizationMode = diarizationMode
        self.numSpeakers = numSpeakers
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowInvalidTLSCertificates = allowInvalidTLSCertificates
        self.advanced = advanced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        self.selectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID) ?? ""
        self.language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.translate = try container.decodeIfPresent(Bool.self, forKey: .translate) ?? false
        self.timestamps = try container.decodeIfPresent(Bool.self, forKey: .timestamps) ?? false
        self.diarizationMode = try container.decodeIfPresent(TScriptDiarizationMode.self, forKey: .diarizationMode) ?? .off
        self.numSpeakers = try container.decodeIfPresent(String.self, forKey: .numSpeakers) ?? ""
        self.minSpeakers = try container.decodeIfPresent(String.self, forKey: .minSpeakers) ?? ""
        self.maxSpeakers = try container.decodeIfPresent(String.self, forKey: .maxSpeakers) ?? ""
        self.allowInsecureHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
        self.allowInvalidTLSCertificates = try container.decodeIfPresent(Bool.self, forKey: .allowInvalidTLSCertificates) ?? false
        self.advanced = try container.decodeIfPresent(TScriptAdvancedOptions.self, forKey: .advanced) ?? TScriptAdvancedOptions()
    }
}
