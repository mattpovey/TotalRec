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
                        TranscriptDocumentContent(transcript: transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .totalRecReadableInset(cornerRadius: 12)
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

private struct TranscriptDocumentContent: View {
    let transcript: TranscriptState

    var body: some View {
        Group {
            if transcript.segments.isEmpty {
                Text(transcript.rawText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transcript.segments) { segment in
                        TranscriptDocumentLine(
                            speakerLabel: TranscriptState.canonicalSpeakerLabel(segment.speakerLabel).map(transcript.alias(for:)),
                            text: segment.text
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }
}

private struct TranscriptDocumentLine: View {
    let speakerLabel: String?
    let text: String

    var body: some View {
        lineText
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineText: Text {
        if let speakerLabel {
            return Text("\(Text("\(speakerLabel):").fontWeight(.semibold)) \(text)")
        }
        return Text(text)
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
            Button(action: onCopyMarkdown) {
                Label("Copy Transcript (Markdown)", systemImage: "doc.on.doc")
            }
                .totalRecGlassButton()

            Button(action: onSaveTranscript) {
                Label("Save Transcript…", systemImage: "square.and.arrow.down")
            }
                .totalRecGlassButton()
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
        .totalRecStaticPanel(cornerRadius: 16)
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
