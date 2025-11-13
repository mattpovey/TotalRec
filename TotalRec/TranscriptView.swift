import SwiftUI

struct TranscriptView: View {
    @Binding var transcript: TranscriptState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if transcript.hasSpeakerLabels {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker Labels")
                        .font(.headline)
                    ForEach(transcript.orderedSpeakerLabels, id: \.self) { label in
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 60, alignment: .leading)
                            TextField("Alias", text: aliasBinding(for: label))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            ScrollView {
                Text(transcript.displayText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 120, maxHeight: 240)
        }
    }

    private func aliasBinding(for label: String) -> Binding<String> {
        Binding(
            get: {
                transcript.alias(for: label)
            },
            set: { newValue in
                transcript.setAlias(newValue, for: label)
            }
        )
    }
}
