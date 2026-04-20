import SwiftUI

struct TranscriptEditorView: View {
    @Binding var transcript: TranscriptState

    let audioURL: URL?
    let audioDuration: TimeInterval?

    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var replaceStatusMessage: String?
    @State private var showMatchingClipsOnly = false
    @State private var rawTextDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TranscriptFindReplaceCard(
                searchText: $searchText,
                replacementText: $replacementText,
                showMatchingClipsOnly: $showMatchingClipsOnly,
                matchCount: transcript.literalMatchCount(for: searchText),
                matchingClipCount: matchingClipCount,
                canFilterClips: transcript.hasTimedSegments,
                statusMessage: replaceStatusMessage,
                onReplaceAll: applyReplaceAll
            )

            if transcript.hasTimedSegments {
                TranscriptSegmentBrowser(
                    title: "Transcript Clips",
                    subtitle: "Play timed clips and edit transcript wording.",
                    emptyMessage: filteredEmptyMessage,
                    transcript: transcript,
                    segments: visibleSegments,
                    mode: .textEditing,
                    audioURL: audioURL,
                    audioDuration: audioDuration,
                    emphasizedSpeakerLabel: nil
                ) { segment, playback in
                    TranscriptTextInspectorCard(
                        transcript: transcript,
                        selectedSegment: segment,
                        playback: playback,
                        onSaveText: saveSegmentText
                    )
                }
            } else {
                TranscriptRawTextEditorCard(
                    rawTextDraft: $rawTextDraft,
                    onSave: saveRawText,
                    onRevert: revertRawText
                )
                .onAppear(perform: syncRawTextDraft)
                .onChange(of: transcript.rawText) { _, _ in
                    syncRawTextDraft()
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                showMatchingClipsOnly = false
            }
        }
    }

    private var visibleSegments: [TranscriptSegment] {
        guard transcript.hasTimedSegments, showMatchingClipsOnly, !searchText.isEmpty else {
            return transcript.segments
        }
        return transcript.segments.filter { $0.text.contains(searchText) }
    }

    private var matchingClipCount: Int {
        guard transcript.hasTimedSegments, !searchText.isEmpty else { return 0 }
        return transcript.segments.reduce(into: 0) { count, segment in
            if segment.text.contains(searchText) {
                count += 1
            }
        }
    }

    private var filteredEmptyMessage: String {
        if showMatchingClipsOnly, !searchText.isEmpty {
            return "No timed clips match the current find text."
        }
        return "No timed segments are available for transcript editing."
    }

    private func syncRawTextDraft() {
        rawTextDraft = transcript.rawText
    }

    private func saveSegmentText(_ text: String, forSegmentID segmentID: UUID) {
        var updated = transcript
        guard updated.updateText(text, forSegmentID: segmentID) else { return }
        transcript = updated
        replaceStatusMessage = "Updated selected clip text."
    }

    private func saveRawText() {
        transcript.updateRawText(rawTextDraft)
        replaceStatusMessage = "Updated transcript text."
    }

    private func revertRawText() {
        rawTextDraft = transcript.rawText
    }

    private func applyReplaceAll() {
        let replacements = transcript.replaceAllLiteralMatches(of: searchText, with: replacementText)
        if replacements > 0 {
            replaceStatusMessage = "Replaced \(replacements) occurrence\(replacements == 1 ? "" : "s")."
            if !transcript.hasTimedSegments {
                rawTextDraft = transcript.rawText
            }
        } else {
            replaceStatusMessage = "No matches found."
        }
    }
}

private struct TranscriptFindReplaceCard: View {
    @Binding var searchText: String
    @Binding var replacementText: String
    @Binding var showMatchingClipsOnly: Bool
    let matchCount: Int
    let matchingClipCount: Int
    let canFilterClips: Bool
    let statusMessage: String?
    let onReplaceAll: () -> Void

    var body: some View {
        TranscriptSurfacePanel(
            title: "Find and Replace",
            subtitle: "Apply literal, case-sensitive replacements across the current transcript."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Search transcript text", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Replace")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Replacement text", text: $replacementText)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 10) {
                    Text(matchCount == 1 ? "1 match" : "\(matchCount) matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if canFilterClips, !searchText.isEmpty {
                        Toggle(isOn: $showMatchingClipsOnly) {
                            Text(matchingClipCount == 1 ? "Show 1 matching clip" : "Show \(matchingClipCount) matching clips")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }

                    Button("Replace All", action: onReplaceAll)
                        .totalRecGlassButton(prominent: true)
                        .disabled(searchText.isEmpty || matchCount == 0)

                    Button("Clear") {
                        searchText = ""
                        replacementText = ""
                        showMatchingClipsOnly = false
                    }
                    .totalRecGlassButton()
                    .disabled(searchText.isEmpty && replacementText.isEmpty)

                    Spacer(minLength: 0)
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TranscriptTextInspectorCard: View {
    let transcript: TranscriptState
    let selectedSegment: TranscriptSegment
    let playback: TranscriptSegmentBrowserPlaybackState
    let onSaveText: (String, UUID) -> Void

    @State private var draftText: String

    init(
        transcript: TranscriptState,
        selectedSegment: TranscriptSegment,
        playback: TranscriptSegmentBrowserPlaybackState,
        onSaveText: @escaping (String, UUID) -> Void
    ) {
        self.transcript = transcript
        self.selectedSegment = selectedSegment
        self.playback = playback
        self.onSaveText = onSaveText
        _draftText = State(initialValue: selectedSegment.text)
    }

    var body: some View {
        TranscriptInspectorPanel(
            title: "Text Inspector",
            subtitle: "Review playback and edit the selected clip."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if transcript.hasSpeakerLabels {
                        TranscriptSegmentDetailBlock(
                            title: "Speaker",
                            value: transcriptSpeakerDisplay(for: selectedSegment, in: transcript)
                        )
                    }

                    TranscriptSegmentDetailBlock(
                        title: "Timestamp",
                        value: transcriptTimestampText(for: selectedSegment)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Playback")
                        .font(.subheadline.weight(.semibold))

                    if !playback.audioAvailable {
                        Text("Session audio is unavailable, so playback is off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            TranscriptPlaybackControls(
                                canPlaySelectedSegment: playback.canPlaySelectedSegment,
                                isPlaying: playback.isPlaying,
                                onPlayClip: playback.playClip,
                                onPlayWithContext: playback.playWithContext,
                                onStopPlayback: playback.stopPlayback
                            )
                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            TranscriptPlaybackControls(
                                canPlaySelectedSegment: playback.canPlaySelectedSegment,
                                isPlaying: playback.isPlaying,
                                onPlayClip: playback.playClip,
                                onPlayWithContext: playback.playWithContext,
                                onStopPlayback: playback.stopPlayback
                            )
                        }
                    }

                    Text("Play With Context adds 2 seconds on each side when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Clip Text")
                        .font(.subheadline.weight(.semibold))

                    TextEditor(text: $draftText)
                        .font(.body)
                        .frame(minHeight: 120)
                        .padding(10)
                        .totalRecReadableInset(cornerRadius: 12)

                    HStack(spacing: 8) {
                        Button {
                            onSaveText(draftText, selectedSegment.id)
                        } label: {
                            Label("Save", systemImage: "checkmark.circle")
                        }
                        .totalRecGlassButton(prominent: true)
                        .disabled(!canSave)

                        Button("Revert") {
                            draftText = selectedSegment.text
                        }
                        .totalRecGlassButton()
                        .disabled(draftText == selectedSegment.text)

                        Spacer(minLength: 0)
                    }

                    if !canSave {
                        Text("Clip text cannot be empty or whitespace only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: selectedSegment.text) { _, newValue in
            draftText = newValue
        }
    }

    private var canSave: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct TranscriptRawTextEditorCard: View {
    @Binding var rawTextDraft: String
    let onSave: () -> Void
    let onRevert: () -> Void

    var body: some View {
        TranscriptSurfacePanel(
            title: "Transcript Text",
            subtitle: "This transcript has no timed clips, so it is edited as one document."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $rawTextDraft)
                    .font(.body)
                    .frame(minHeight: 360)
                    .padding(10)
                    .totalRecReadableInset(cornerRadius: 12)

                HStack(spacing: 8) {
                    Button(action: onSave) {
                        Label("Save", systemImage: "checkmark.circle")
                    }
                        .totalRecGlassButton(prominent: true)

                    Button("Revert", action: onRevert)
                        .totalRecGlassButton()

                    Spacer(minLength: 0)
                }
            }
        }
    }
}
