import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable, Codable {
    case appleOnDevice = "Apple (On-Device)"
    case appleCloud = "Apple (Cloud)"
    case openAI = "OpenAI (Diarized)"
    case tscript = "TScript"

    var id: String { rawValue }

    var storageValue: String {
        switch self {
        case .appleOnDevice:
            return "apple_ondevice"
        case .appleCloud:
            return "apple_cloud"
        case .openAI:
            return "openai"
        case .tscript:
            return "tscript"
        }
    }

    static func fromStoredValue(_ value: String) -> TranscriptionProvider {
        switch value.lowercased() {
        case "openai":
            return .openAI
        case "apple (on-device)", "apple_ondevice", "apple-ondevice", "apple_on_device":
            return .appleOnDevice
        case "tscript":
            return .tscript
        default:
            return .appleCloud
        }
    }
}
