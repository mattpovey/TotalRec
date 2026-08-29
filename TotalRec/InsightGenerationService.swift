import Foundation

protocol InsightGenerating {
    func generateArtifact(
        from transcript: TranscriptState,
        settings: InsightSettings,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> InsightArtifact
}

struct InsightGenerationService: InsightGenerating {
    enum ServiceError: LocalizedError {
        case missingTranscript
        case missingPrompt

        var errorDescription: String? {
            switch self {
            case .missingTranscript:
                return "Transcript is empty. Generate a transcript first."
            case .missingPrompt:
                return "Enter a custom prompt or switch back to a built-in workflow."
            }
        }
    }

    let responsesTransport: any TextGeneratingTransport
    let conversationTransport: any TextGeneratingTransport

    init(
        responsesTransport: any TextGeneratingTransport = ResponsesTransport(),
        conversationTransport: any TextGeneratingTransport = ConversationTransport()
    ) {
        self.responsesTransport = responsesTransport
        self.conversationTransport = conversationTransport
    }

    func generateArtifact(
        from transcript: TranscriptState,
        settings: InsightSettings,
        onEvent: @MainActor @escaping (TextGenerationEvent) -> Void
    ) async throws -> InsightArtifact {
        let transcriptBody = transcriptText(from: transcript)
        guard !transcriptBody.isEmpty else {
            throw ServiceError.missingTranscript
        }

        let promptSource = settings.effectivePrompt
        guard !promptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.missingPrompt
        }

        let resolved = try AIConfigManager.shared.resolvedInsightConfiguration()
        let transport = transport(for: resolved.provider)

        let renderedPrompt = renderPrompt(promptSource: promptSource, transcript: transcriptBody)
        let generatedText = try await transport.generateText(
            TextGenerationRequest(
                provider: resolved.provider,
                baseURL: resolved.baseURL,
                apiKey: resolved.apiKey,
                systemInstruction: systemInstruction(for: settings),
                prompt: renderedPrompt,
                inputText: transcriptBody,
                modelID: resolved.modelID,
                preferStreaming: true,
                outputExpectations: "Return Markdown output."
            ),
            onEvent: onEvent
        )

        return InsightArtifact(
            workflow: settings.selectedWorkflow,
            title: settings.selectedWorkflow.artifactTitle,
            content: generatedText,
            generatedAt: Date(),
            provider: resolved.provider,
            modelID: resolved.modelID,
            transport: transport.kind,
            promptUsed: promptSource
        )
    }

    private func transport(for provider: LLMProvider) -> any TextGeneratingTransport {
        switch provider {
        case .openAI:
            return responsesTransport
        case .sambaNova:
            return conversationTransport
        }
    }

    private func transcriptText(from transcript: TranscriptState) -> String {
        let formatter = TranscriptFormatter(transcript: transcript)
        let preferred = formatter.joinedPlainText()
        let fallback = formatter.joinedRawSpeakerText()
        let body = preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : preferred
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderPrompt(promptSource: String, transcript: String) -> String {
        let token = "{{TRANSCRIPT}}"
        if promptSource.contains(token) {
            return promptSource.replacingOccurrences(of: token, with: transcript)
        }
        return promptSource + "\n\nTRANSCRIPT START\n" + transcript + "\nTRANSCRIPT END"
    }

    private func systemInstruction(for settings: InsightSettings) -> String {
        if settings.useCustomPrompt {
            return "You are a helpful transcript analysis assistant. Follow the user's instructions precisely when working with the provided diarized transcript."
        }
        return "You transform diarized transcripts into structured markdown artifacts."
    }
}
