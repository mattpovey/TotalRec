import Foundation

struct NameSuggestionService {
    struct SpeakerExcerpt: Identifiable {
        let id: UUID
        let label: String
        let alias: String
        let excerpt: String

        init(id: UUID = UUID(), label: String, alias: String, excerpt: String) {
            self.id = id
            self.label = label
            self.alias = alias
            self.excerpt = excerpt
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let name: String
    }

    enum ServiceError: LocalizedError {
        case excerptTooLong(labels: [String], limit: Int)
        case noSpeakers

        var errorDescription: String? {
            switch self {
            case let .excerptTooLong(labels, limit):
                let joined = labels.joined(separator: ", ")
                return "Speaker excerpts for \(joined) exceed the \(limit)-character limit."
            case .noSpeakers:
                return "No speakers are available for name suggestions."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .excerptTooLong:
                return "Trim the excerpts and try again."
            case .noSpeakers:
                return "Record or import a transcript before requesting suggestions."
            }
        }

        var userFacingMessage: String {
            let base = errorDescription ?? "An unknown error occurred."
            if let recovery = recoverySuggestion {
                return "\(base) \(recovery)"
            }
            return base
        }
    }

    let maxExcerptLength: Int

    init(maxExcerptLength: Int = 480) {
        self.maxExcerptLength = maxExcerptLength
    }

    func suggestAliases(for speakers: [SpeakerExcerpt]) async throws -> [Suggestion] {
        guard !speakers.isEmpty else {
            throw ServiceError.noSpeakers
        }

        let truncatedLabels = speakers
            .filter { $0.excerpt.count > maxExcerptLength }
            .map { $0.label }

        if !truncatedLabels.isEmpty {
            throw ServiceError.excerptTooLong(labels: truncatedLabels, limit: maxExcerptLength)
        }

        try await Task.sleep(nanoseconds: 75_000_000)

        return speakers.map { speaker in
            let sourceAlias = speaker.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerptWords = speaker.excerpt
                .split { $0.isWhitespace || $0.isNewline }
                .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
                .filter { !$0.isEmpty }

            let candidate = excerptWords.first ?? sourceAlias
            let fallback = sourceAlias.isEmpty ? speaker.label : sourceAlias
            let name = candidate.isEmpty ? fallback : candidate.prefix(1).uppercased() + candidate.dropFirst()
            return Suggestion(label: speaker.label, name: String(name))
        }
    }
}
