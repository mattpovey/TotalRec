import Foundation

struct TScriptTranscriptionRunConfiguration: Sendable {
    let baseURL: String
    let configuration: TScriptConfiguration
}

struct TranscriptionRunConfiguration {
    let provider: TranscriptionProvider
    let openAIAPIKey: String
    let openAIChunkingStrategy: String
    let knownSpeakers: [OpenAITranscriber.KnownSpeaker]
    let tscript: TScriptTranscriptionRunConfiguration?

    init(
        provider: TranscriptionProvider,
        openAIAPIKey: String = "",
        openAIChunkingStrategy: String = "auto",
        knownSpeakers: [OpenAITranscriber.KnownSpeaker] = [],
        tscript: TScriptTranscriptionRunConfiguration? = nil
    ) {
        self.provider = provider
        self.openAIAPIKey = openAIAPIKey
        self.openAIChunkingStrategy = openAIChunkingStrategy
        self.knownSpeakers = knownSpeakers
        self.tscript = tscript
    }
}
