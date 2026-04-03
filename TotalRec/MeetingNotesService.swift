import Foundation

struct MeetingNotesService {
    enum Preset: String, CaseIterable, Identifiable {
        case meetingNotes = "Meeting Notes"
        case actionItems = "Action Items"
        case decisions = "Decisions"
        case customerCall = "Customer Call Summary"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .meetingNotes:
                return "Balanced meeting minutes with summaries, decisions, action items, and follow-ups."
            case .actionItems:
                return "A tighter operational readout focused on owners, deadlines, blockers, and next steps."
            case .decisions:
                return "Highlights agreements, decision rationale, unresolved questions, and explicit commitments."
            case .customerCall:
                return "Frames the transcript as a customer conversation with pains, objections, sentiment, and follow-ups."
            }
        }

        var promptTemplate: String {
            switch self {
            case .meetingNotes:
                return Self.meetingNotesPrompt
            case .actionItems:
                return Self.actionItemsPrompt
            case .decisions:
                return Self.decisionsPrompt
            case .customerCall:
                return Self.customerCallPrompt
            }
        }

        private static let meetingNotesPrompt: String = """
You are an assistant that turns raw diarized meeting transcripts into clear, concise, actionable meeting notes.

INPUT FORMAT
- You will receive a diarized transcript of a meeting.
- Each utterance is tagged with a speaker label (e.g. “Speaker 1”, “Alice”, “PM”, etc.), and may include timestamps.

YOUR GOALS
From the transcript, produce:
1. A short, high-level summary of the meeting.
2. A structured list of topics discussed, in the order they occurred.
3. A clear list of decisions made.
4. A clear list of action items with owner and, if mentioned, due date.
5. A list of open questions / risks / follow-ups that were not resolved.

GENERAL RULES
- Be concise but specific: capture the substance, not every detail.
- Preserve factual accuracy; do not invent names, dates, or decisions.
- If something is ambiguous or inaudible, explicitly label it as “Unclear” instead of guessing.
- Ignore greetings, small talk, filler words, and digressions that have no bearing on outcomes.
- Keep speaker attributions only when the identity matters (e.g. for decisions, objections, or action owners).
- If you infer information (e.g. a role from context), mark it with “(inferred)”.
- Maintain the chronological order of topics as they appeared in the transcript.

EXTRACTED METADATA
First, infer and list any metadata you can find:
- Meeting title:
- Date and time:
- Participants (map speaker labels to names/roles where possible):
  - Speaker label → Name / role (or “Unknown” if not stated)
- Main objective of the meeting (if stated):

If a field is not stated, write “Not stated”.

STRUCTURE YOUR OUTPUT IN MARKDOWN EXACTLY AS FOLLOWS

# Meeting Summary
- 2–5 bullet points summarising the overall purpose, key discussions, and outcomes.

# Participants
- Speaker label → Name / role (if known)
- …

# Agenda / Topics Discussed
For each major topic, in the order discussed:
## Topic 1: [Short topic name]
- Brief description of what was discussed.
- Key points and arguments (group similar points; no need to attribute every sentence).
- Important context or background that affects decisions or actions.

## Topic 2: [Short topic name]
- …

# Decisions
List only explicit or clearly implied decisions (do NOT invent them):
- **D1**: [Decision statement in plain language]
  - Owner: [Person/role or “Not specified”]
  - Rationale: [1 short sentence from the discussion]
- **D2**: …

If no decisions were made, state: “No clear decisions were made in this meeting.”

# Action Items
Each action item must have at least a description and an owner if stated:
- **A1**
  - Description: [What needs to be done, starting with a verb]
  - Owner: [Person/role or “Not specified”]
  - Due date: [If stated, else “Not specified”]
  - Related topic / decision: [If applicable]

- **A2**
  - …

# Open Questions / Risks / Follow-ups
List items that were discussed but not resolved:
- **Q1**: [Open question or issue]
  - Owner (if any): [Person/role or “Not specified”]
  - Notes: [Relevant context or constraints]

- **R1**: [Risk or concern]
  - Impact: [Short description]
  - Mitigation (if discussed): [Short description or “Not discussed”]

# Parking Lot (Optional)
If the team explicitly postponed items, list them here:
- [Item and brief description]

SOURCE TRANSCRIPT
Use only the information in the transcript below. Do not add external knowledge.

TRANSCRIPT START
{{TRANSCRIPT}}
TRANSCRIPT END
"""

        private static let actionItemsPrompt: String = """
You are an assistant that extracts an execution-focused action register from a diarized meeting transcript.

GOAL
Produce a concise operational summary that emphasizes:
1. Immediate next steps
2. Explicit owners
3. Due dates or timing signals
4. Dependencies and blockers
5. Follow-up questions that could block execution

RULES
- Use only information present in the transcript.
- Do not invent owners or dates.
- If ownership or timing is unclear, mark it as “Not specified”.
- Ignore small talk and background context unless it affects actionability.
- Keep output compact and easy to scan.

OUTPUT IN MARKDOWN WITH THESE SECTIONS

# Executive Summary
- 2–4 bullets on what the team is trying to accomplish and what changed in this meeting.

# Action Items
For every concrete task mentioned:
- **A1**
  - Description: [Start with a verb]
  - Owner: [Name / role or “Not specified”]
  - Due date / timing: [Exact date, timeframe, or “Not specified”]
  - Status: [New / In progress / Waiting / Blocked]
  - Dependencies: [If mentioned, else “None stated”]

# Blockers / Risks
- **B1**: [Blocker or risk]
  - Impact: [Short description]
  - Owner: [If stated, else “Not specified”]
  - Next move: [If stated, else “Not stated”]

# Follow-ups Needed
- Items that require another meeting, external confirmation, or missing information before work can continue.

TRANSCRIPT START
{{TRANSCRIPT}}
TRANSCRIPT END
"""

        private static let decisionsPrompt: String = """
You are an assistant that turns a diarized meeting transcript into a decision log.

GOAL
Extract and organize:
1. Confirmed decisions
2. Near-decisions / proposed decisions that were not finalized
3. Rationale and tradeoffs discussed
4. Open questions that still affect the decision space

RULES
- Only label something a decision if it is explicit or strongly implied by the conversation.
- Separate confirmed decisions from proposals or unresolved options.
- Preserve uncertainty. If the transcript is ambiguous, say so.
- Attribute owners only when the transcript states or strongly implies them.

OUTPUT IN MARKDOWN WITH THESE SECTIONS

# Decision Summary
- 2–4 bullets capturing the most important outcomes.

# Confirmed Decisions
- **D1**: [Decision]
  - Owner: [Name / role or “Not specified”]
  - Rationale: [1–2 sentences]
  - Tradeoffs mentioned: [Short bullets or “Not discussed”]

# Proposed But Not Finalized
- **P1**: [Proposal or option]
  - Status: [Pending / Rejected / Needs more input]
  - Concerns raised: [Short bullets]

# Open Questions
- **Q1**: [Question]
  - Why it matters: [Short explanation]
  - Needed from: [Person / role or “Not specified”]

TRANSCRIPT START
{{TRANSCRIPT}}
TRANSCRIPT END
"""

        private static let customerCallPrompt: String = """
You are an assistant that summarizes a diarized customer or prospect call for a product and go-to-market team.

GOAL
Turn the transcript into a clear customer call readout that captures:
1. Customer context and goals
2. Pain points, objections, and unmet needs
3. Product feedback and requested capabilities
4. Commitments or follow-up actions from either side
5. Overall customer sentiment

RULES
- Use only information from the transcript.
- Distinguish clearly between what the customer said and what the internal team said.
- Do not overstate sentiment; if mixed, describe it as mixed.
- Capture direct needs and implied needs separately when useful.

OUTPUT IN MARKDOWN WITH THESE SECTIONS

# Call Summary
- 3–5 bullets covering the account context, main pain points, and overall outcome.

# Customer Goals / Context
- What the customer is trying to achieve
- Relevant constraints, timelines, or team context

# Pain Points / Objections
- **P1**: [Pain point or objection]
  - Severity: [High / Medium / Low if inferable, else “Not clear”]
  - Evidence: [Short supporting note]

# Product Feedback / Requests
- **F1**: [Requested feature, workflow issue, or product reaction]
  - Priority signal: [If mentioned or inferable]
  - Notes: [Short context]

# Commitments / Next Steps
- **A1**
  - Description: [What happens next]
  - Owner: [Internal / customer / name if stated]
  - Timing: [If stated, else “Not specified”]

# Sentiment
- Overall sentiment: [Positive / Neutral / Mixed / Negative]
- Why: [Short explanation grounded in the transcript]

TRANSCRIPT START
{{TRANSCRIPT}}
TRANSCRIPT END
"""
    }

    enum ServiceError: LocalizedError {
        case missingTranscript
        case invalidResponse
        case missingAPIKey
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingTranscript:
                return "Transcript is empty. Generate a transcript first."
            case .invalidResponse:
                return "The meeting notes service returned an unexpected response."
            case .missingAPIKey:
                return "Set an OpenAI API key to generate meeting notes."
            case let .httpError(code, body):
                return "Meeting notes request failed (HTTP \(code)): \(body)"
            }
        }
    }

    func generateNotes(from transcript: TranscriptState, promptOverride: String? = nil) async throws -> String {
        let formatter = TranscriptFormatter(transcript: transcript)
        let preferred = formatter.joinedPlainText()
        let fallback = formatter.joinedRawSpeakerText()
        let body = preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : preferred
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.missingTranscript
        }

        guard let apiKey = AIConfigManager.shared.openAIKey(), !apiKey.isEmpty else {
            print("[MeetingNotesService] ERROR: Missing OpenAI API key")
            throw ServiceError.missingAPIKey
        }

        return try await generateWithOpenAI(apiKey: apiKey, transcript: transcript, rawBody: body, promptOverride: promptOverride)
    }

    // MARK: - OpenAI

    private struct ChatCompletionRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let maxCompletionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    private func generateWithOpenAI(apiKey: String, transcript: TranscriptState, rawBody: String, promptOverride: String?) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw ServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let model = "gpt-5-mini"
        let promptSource = promptOverride?.isEmpty == false ? promptOverride! : Self.defaultPrompt
        let token = "{{TRANSCRIPT}}"
        let prompt: String
        if promptSource.contains(token) {
            prompt = promptSource.replacingOccurrences(of: token, with: rawBody)
        } else {
            prompt = promptSource + "\n\nTRANSCRIPT START\n" + rawBody + "\nTRANSCRIPT END"
        }
        print("[MeetingNotesService] Requesting OpenAI meeting notes (model=\(model), promptChars=\(prompt.count))")
        let systemContent: String
        if promptOverride?.isEmpty == false {
            systemContent = "You are a helpful meeting assistant. Follow the user's instructions precisely when working with the provided diarized transcript."
        } else {
            systemContent = "You transform diarized meeting transcripts into structured meeting minutes."
        }
        let system = ChatCompletionRequest.Message(
            role: "system",
            content: systemContent
        )
        let user = ChatCompletionRequest.Message(role: "user", content: prompt)
        let payload = ChatCompletionRequest(
            model: model,
            messages: [system, user],
            maxCompletionTokens: nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let dataResponse: (Data, URLResponse)
        do {
            dataResponse = try await URLSession.shared.data(for: request)
        } catch {
            print("[MeetingNotesService] ERROR: \(error.localizedDescription)")
            throw error
        }
        let (data, response) = dataResponse
        guard let http = response as? HTTPURLResponse else {
            print("[MeetingNotesService] ERROR: Missing HTTPURLResponse")
            throw ServiceError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            print("[MeetingNotesService] ERROR: HTTP \(http.statusCode) \(body)")
            throw ServiceError.httpError(http.statusCode, body)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            print("[MeetingNotesService] ERROR: Failed to decode response: \(error.localizedDescription)")
            throw error
        }
        guard let content = decoded.choices.first?.message.content else {
            print("[MeetingNotesService] ERROR: Empty choices in response")
            throw ServiceError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Heuristic fallback

    static let defaultPrompt: String = Preset.meetingNotes.promptTemplate
}
