import SwiftUI

struct TranscriptDocumentView: View {
    let transcript: TranscriptState
    let onCopyMarkdown: () -> Void
    let onSaveTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TranscriptDocumentActionCard(
                hasTimedSegments: transcript.hasTimedSegments,
                onCopyMarkdown: onCopyMarkdown,
                onSaveTranscript: onSaveTranscript
            )

            TranscriptDocumentPanel(
                title: "Transcript Document",
                subtitle: "Read the full transcript, verify speaker display, and export the current state without editing transcript text here."
            ) {
                if transcript.hasDisplayText {
                    ScrollView {
                        Text(transcript.attributedDisplayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .frame(minHeight: 420)
                } else {
                    Text("Transcript content will appear here once a run has completed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct TranscriptDocumentActionCard: View {
    let hasTimedSegments: Bool
    let onCopyMarkdown: () -> Void
    let onSaveTranscript: () -> Void

    var body: some View {
        TranscriptDocumentPanel(
            title: "Export",
            subtitle: hasTimedSegments
                ? "Copy the current transcript as Markdown or save it as text, JSON, WebVTT, or SRT from one standard save panel."
                : "Copy the current transcript as Markdown or save it as text or JSON from one standard save panel."
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    actionButtons
                }
            }
        }
    }

    private var actionButtons: some View {
        Group {
            Button("Copy Transcript (Markdown)", action: onCopyMarkdown)
                .buttonStyle(.bordered)

            Button("Save Transcript…", action: onSaveTranscript)
                .buttonStyle(.bordered)
        }
    }
}

private struct TranscriptDocumentPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}

#Preview {
    TranscriptDocumentView(
        transcript: TranscriptState(
            segments: [
                TranscriptSegment(speakerLabel: "SPEAKER_00", text: "Hello world.", start: 0, end: 3),
                TranscriptSegment(speakerLabel: "SPEAKER_01", text: "Transcript export preview.", start: 3, end: 6)
            ]
        ),
        onCopyMarkdown: {},
        onSaveTranscript: {}
    )
    .padding()
    .frame(width: 960, height: 620)
}
