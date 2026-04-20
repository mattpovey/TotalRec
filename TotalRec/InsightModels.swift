import Foundation

enum InsightWorkflow: String, CaseIterable, Codable, Identifiable {
    case meetingNotes
    case actionItems
    case decisions
    case customerCall
    case podcastSummary
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meetingNotes:
            return "Meeting Notes"
        case .actionItems:
            return "Action Items"
        case .decisions:
            return "Decisions"
        case .customerCall:
            return "Customer Call Summary"
        case .podcastSummary:
            return "Podcast Summary"
        case .custom:
            return "Custom Workflow"
        }
    }

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
        case .podcastSummary:
            return "Summarizes an audio episode with themes, takeaways, notable moments, and audience-facing highlights."
        case .custom:
            return "Start from a generic transcript-analysis template and customize the output structure yourself."
        }
    }

    var artifactTitle: String {
        displayName
    }

    var fileSlug: String {
        switch self {
        case .meetingNotes:
            return "meeting-notes"
        case .actionItems:
            return "action-items"
        case .decisions:
            return "decisions"
        case .customerCall:
            return "customer-call-summary"
        case .podcastSummary:
            return "podcast-summary"
        case .custom:
            return "custom-insight"
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
        case .podcastSummary:
            return Self.podcastSummaryPrompt
        case .custom:
            return Self.customPrompt
        }
    }

    static let fallbackDefault: InsightWorkflow = .meetingNotes

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

    private static let podcastSummaryPrompt: String = """
You are an assistant that turns a diarized podcast or long-form audio transcript into a polished transcript-derived summary.

GOAL
Produce a listener-friendly summary that captures:
1. The central topic and framing of the episode
2. The major themes or segments in order
3. Notable arguments, insights, or stories
4. Memorable quotes or moments worth revisiting
5. Actionable takeaways or follow-up listening cues

RULES
- Use only the information in the transcript.
- Do not invent show metadata, guest bios, or episode titles that are not stated.
- Preserve uncertainty and mark unclear points explicitly.
- Keep the output readable for someone deciding whether to listen or revisit the episode.
- Avoid sounding like meeting minutes; this is an editorial summary of an audio conversation.

OUTPUT IN MARKDOWN WITH THESE SECTIONS

# Episode Summary
- 3–5 bullets capturing the main topic, tone, and overall takeaway.

# Key Themes
For each major theme or segment, in order:
## Theme 1: [Short title]
- What was discussed
- Why it mattered
- Notable supporting detail or example

# Notable Moments
- **M1**: [Memorable insight, example, exchange, or quote-worthy moment]
  - Why it stands out: [Short note]

# Takeaways
- **T1**: [Clear takeaway for the listener]
- **T2**: [Clear takeaway for the listener]

# Follow-up Listening
- Topics, questions, or references the listener may want to revisit in the transcript.

TRANSCRIPT START
{{TRANSCRIPT}}
TRANSCRIPT END
"""

    private static let customPrompt: String = """
You are an assistant that turns a diarized transcript into a clear, structured artifact.

GOAL
- Read the transcript carefully.
- Produce concise Markdown output.
- Preserve factual accuracy and label ambiguity explicitly.
- Keep the output useful for a human reviewing the audio after the fact.

SUGGESTED STRUCTURE
# Summary
- Short bullets with the most important takeaways

# Main Points
- Organize the important discussion points in the order they occurred

# Decisions / Actions / Follow-ups
- Capture explicit commitments, next steps, risks, and unresolved questions

TRANSCRIPT START
{{TRANSCRIPT}}
TRANSCRIPT END
"""
}

enum TextGenerationTransportKind: String, Codable {
    case responses
    case conversation
}

struct InsightSettings: Codable, Equatable {
    var selectedWorkflow: InsightWorkflow
    var useCustomPrompt: Bool
    var customPrompt: String

    init(
        selectedWorkflow: InsightWorkflow = .fallbackDefault,
        useCustomPrompt: Bool = false,
        customPrompt: String? = nil
    ) {
        self.selectedWorkflow = selectedWorkflow
        self.useCustomPrompt = useCustomPrompt
        self.customPrompt = customPrompt ?? selectedWorkflow.promptTemplate
    }

    var trimmedCustomPrompt: String {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectivePrompt: String {
        let trimmed = trimmedCustomPrompt
        if useCustomPrompt, !trimmed.isEmpty {
            return trimmed
        }
        return selectedWorkflow.promptTemplate
    }
}

struct InsightArtifact: Codable, Equatable {
    var workflow: InsightWorkflow
    var title: String
    var content: String
    var generatedAt: Date
    var provider: LLMProvider
    var modelID: String
    var transport: TextGenerationTransportKind
    var promptUsed: String

    enum CodingKeys: String, CodingKey {
        case workflow
        case title
        case content
        case generatedAt
        case provider
        case modelID
        case transport
        case promptUsed
    }

    init(
        workflow: InsightWorkflow,
        title: String,
        content: String,
        generatedAt: Date,
        provider: LLMProvider,
        modelID: String,
        transport: TextGenerationTransportKind,
        promptUsed: String
    ) {
        self.workflow = workflow
        self.title = title
        self.content = content
        self.generatedAt = generatedAt
        self.provider = provider
        self.modelID = modelID
        self.transport = transport
        self.promptUsed = promptUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflow = try container.decode(InsightWorkflow.self, forKey: .workflow)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        provider = try container.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? .openAI
        modelID = try container.decode(String.self, forKey: .modelID)
        transport = try container.decode(TextGenerationTransportKind.self, forKey: .transport)
        promptUsed = try container.decode(String.self, forKey: .promptUsed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflow, forKey: .workflow)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(provider, forKey: .provider)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(transport, forKey: .transport)
        try container.encode(promptUsed, forKey: .promptUsed)
    }

    var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
