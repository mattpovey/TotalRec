import SwiftUI

private enum TranscriptSpeakerFocusMode: String, CaseIterable, Identifiable {
    case selectedSpeaker = "Selected Speaker"
    case conversationContext = "Conversation Context"

    var id: String { rawValue }
}

struct TranscriptSpeakersView: View {
    @Binding var transcript: TranscriptState

    private let audioURL: URL?
    private let audioDuration: TimeInterval?

    private let areSuggestionsEnabled: Bool
    private let suggestionProviderName: String
    private let onStatusMessage: (String) -> Void

    @StateObject private var viewModel: TranscriptViewModel
    @State private var isRequestInFlight = false
    @State private var requestError: TranscriptViewModel.RequestError?
    @State private var showSuggestionSheet = false
    @State private var selectedSpeakerLabel: String?
    @State private var transcriptFocusMode: TranscriptSpeakerFocusMode = .selectedSpeaker
    @State private var excerptEditorTarget: ExcerptEditorTarget?

    private struct ExcerptEditorTarget: Identifiable {
        let label: String

        var id: String { label }
    }

    init(
        transcript: Binding<TranscriptState>,
        audioURL: URL?,
        audioDuration: TimeInterval?,
        suggestionService: NameSuggestionService = NameSuggestionService(),
        areSuggestionsEnabled: Bool,
        suggestionProviderName: String,
        onStatusMessage: @escaping (String) -> Void = { _ in }
    ) {
        _transcript = transcript
        self.audioURL = audioURL
        self.audioDuration = audioDuration
        self.areSuggestionsEnabled = areSuggestionsEnabled
        self.suggestionProviderName = suggestionProviderName
        self.onStatusMessage = onStatusMessage
        _viewModel = StateObject(
            wrappedValue: TranscriptViewModel(
                transcript: transcript.wrappedValue,
                suggestionService: suggestionService
            )
        )
    }

    private var activeSpeakerLabel: String? {
        if let selectedSpeakerLabel,
           viewModel.speakers.contains(where: { $0.label == selectedSpeakerLabel }) {
            return selectedSpeakerLabel
        }
        return viewModel.speakers.first?.label
    }

    private var selectedSpeaker: TranscriptViewModel.SpeakerState? {
        guard let activeSpeakerLabel else { return nil }
        return viewModel.speakers.first(where: { $0.label == activeSpeakerLabel })
    }

    private var speakerTurnCounts: [String: Int] {
        transcript.segments.reduce(into: [String: Int]()) { counts, segment in
            guard let label = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) else { return }
            counts[label, default: 0] += 1
        }
    }

    private var hasCustomSpeakerAliases: Bool {
        transcript.orderedSpeakerLabels.contains { label in
            transcript.alias(for: label).caseInsensitiveCompare(label) != .orderedSame
        }
    }

    private var speakerBrowserSegments: [TranscriptSegment] {
        guard let activeSpeakerLabel else { return [] }

        if transcriptFocusMode == .selectedSpeaker {
            return transcript.segments.filter {
                TranscriptState.canonicalSpeakerLabel($0.speakerLabel) == activeSpeakerLabel
            }
        }

        return transcript.segments
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                TranscriptSpeakerActionCard(
                    speakerCount: viewModel.speakers.count,
                    turnCount: transcript.segments.count,
                    hasConsecutiveSpeakerRuns: transcript.hasConsecutiveSpeakerRuns,
                    hasCustomSpeakerAliases: hasCustomSpeakerAliases,
                    areSuggestionsEnabled: areSuggestionsEnabled,
                    suggestionProviderName: suggestionProviderName,
                    isRequestInFlight: isRequestInFlight,
                    onRequestSuggestions: requestSuggestions,
                    onConsolidateSpeakers: consolidateSpeakers,
                    onResetAliases: resetAliases
                )

                HStack(alignment: .top, spacing: 16) {
                    TranscriptSpeakerListCard(
                        speakers: viewModel.speakers,
                        selectedSpeakerLabel: activeSpeakerLabel,
                        turnCounts: speakerTurnCounts,
                        isRequestInFlight: isRequestInFlight,
                        onSelect: { label in
                            selectedSpeakerLabel = label
                            transcriptFocusMode = .selectedSpeaker
                        }
                    )
                    .frame(width: 280)

                    VStack(alignment: .leading, spacing: 16) {
                        TranscriptSpeakerDetailCard(
                            speaker: selectedSpeaker,
                            speakerTurnCount: selectedSpeaker.map { speakerTurnCounts[$0.label, default: 0] } ?? 0,
                            isRequestInFlight: isRequestInFlight,
                            onCommitAlias: commitAlias,
                            onEditExcerpt: { label in
                                excerptEditorTarget = ExcerptEditorTarget(label: label)
                            }
                        )

                        TranscriptSpeakerTurnsCard(
                            transcript: transcript,
                            selectedSpeaker: selectedSpeaker,
                            focusMode: $transcriptFocusMode,
                            visibleSegments: speakerBrowserSegments,
                            audioURL: audioURL,
                            audioDuration: audioDuration,
                            onUpdateSpeaker: updateSpeakerAssignment
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear {
                viewModel.update(from: transcript)
                syncSelectedSpeaker()
            }
            .onChange(of: transcript) { _, newValue in
                viewModel.update(from: newValue)
                syncSelectedSpeaker()
            }
            .onDisappear {
                syncAliasesToTranscript()
            }
            .onReceive(viewModel.$speakers) { _ in
                syncSelectedSpeaker()
            }

            if isRequestInFlight {
                TranscriptSuggestionOverlay()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.12), value: isRequestInFlight)
        .sheet(isPresented: $showSuggestionSheet) {
            suggestionSheet
        }
        .sheet(item: $excerptEditorTarget) { target in
            excerptEditorSheet(for: target.label)
        }
        .alert(item: $requestError) { error in
            Alert(
                title: Text("Suggestion Failed"),
                message: Text(error.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissError()
                }
            )
        }
        .onReceive(viewModel.$isRequestInFlight) { newValue in
            isRequestInFlight = newValue
        }
        .onReceive(viewModel.$requestError) { newValue in
            requestError = newValue
        }
        .onReceive(viewModel.$showSuggestionSheet) { newValue in
            showSuggestionSheet = newValue
        }
    }

    private var suggestionSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if viewModel.suggestions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Suggestions")
                            .font(.headline)
                        Text("Try requesting suggestions again or edit speaker names manually.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Review and edit suggested speaker names before applying.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach($viewModel.suggestions) { $suggestion in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text("Speaker \(suggestion.label)")
                                                .font(.headline)
                                            Spacer()
                                            Text(viewModel.speakers.first(where: { $0.label == suggestion.label })?.alias ?? suggestion.label)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        TextField("Suggested name", text: $suggestion.name)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("suggestedNameField_\(suggestion.label)")

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Excerpt Used")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Text(viewModel.speakers.first(where: { $0.label == suggestion.label })?.excerpt ?? "No excerpt available.")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                    }
                                    .padding()
                                    .background(Color.gray.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                Divider()

                HStack {
                    Button("Edit manually") {
                        viewModel.chooseManualEditing()
                    }
                    .accessibilityIdentifier("manualEditButton")

                    Spacer()

                    Button("Retry") {
                        viewModel.retrySuggestions()
                    }
                    .accessibilityIdentifier("retrySuggestionsButton")

                    Button("Apply") {
                        viewModel.applySuggestions()
                        syncAliasesToTranscript()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("applySuggestionsButton")
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Suggested Names")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.dismissSuggestions()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func excerptEditorSheet(for label: String) -> some View {
        if let speaker = viewModel.speakers.first(where: { $0.label == label }) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This excerpt is only used when requesting speaker-name suggestions. It does not edit the transcript text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    DeferredCommitSpeakerTextEditor(text: speaker.excerpt) { updatedExcerpt in
                        viewModel.updateExcerpt(updatedExcerpt, for: label)
                    }
                    .font(.body)
                    .padding(10)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18))
                    )
                    .accessibilityIdentifier("excerptEditor_\(label)")
                }
                .padding(20)
                .navigationTitle("\(transcript.alias(for: label)) Suggestion Context")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            excerptEditorTarget = nil
                        }
                    }
                }
            }
            .frame(minWidth: 460, minHeight: 320)
        } else {
            Text("Unable to edit excerpt for this speaker.")
                .padding()
        }
    }

    private func requestSuggestions() {
        guard areSuggestionsEnabled, !isRequestInFlight else { return }
        onStatusMessage("Requesting speaker name suggestions...")
        viewModel.requestSuggestions(using: transcript)
    }

    private func consolidateSpeakers() {
        var updated = transcript
        guard updated.consolidateConsecutiveSpeakers() else { return }
        transcript = updated
        onStatusMessage("Consolidated consecutive speaker turns.")
    }

    private func updateSpeakerAssignment(_ speakerLabel: String?, forSegmentID segmentID: UUID) {
        var updated = transcript
        guard updated.updateSpeakerLabel(speakerLabel, forSegmentID: segmentID) else { return }
        transcript = updated
    }

    private func resetAliases() {
        var updated = transcript
        updated.resetAliases()
        transcript = updated
        viewModel.update(from: updated)
        onStatusMessage("Speaker aliases reset.")
    }

    private func syncSelectedSpeaker() {
        guard !viewModel.speakers.isEmpty else {
            selectedSpeakerLabel = nil
            transcriptFocusMode = .conversationContext
            return
        }

        if let selectedSpeakerLabel,
           viewModel.speakers.contains(where: { $0.label == selectedSpeakerLabel }) {
            return
        }

        selectedSpeakerLabel = viewModel.speakers.first?.label
        transcriptFocusMode = .selectedSpeaker
    }

    private func syncAliasesToTranscript() {
        var updated = transcript
        if viewModel.applyAliases(to: &updated) {
            transcript = updated
        }
    }

    private func commitAlias(_ label: String, _ alias: String) {
        var updated = transcript
        updated.setAlias(alias, for: label)

        if let mergeTarget = updated.speakerLabel(matchingAlias: updated.alias(for: label), excluding: label),
           updated.mergeSpeakerLabel(label, into: mergeTarget) {
            transcript = updated
            selectedSpeakerLabel = mergeTarget
            onStatusMessage("Merged duplicate speaker labels for \(updated.alias(for: mergeTarget)).")
            return
        }

        transcript = updated
    }

}

private struct TranscriptSpeakerActionCard: View {
    let speakerCount: Int
    let turnCount: Int
    let hasConsecutiveSpeakerRuns: Bool
    let hasCustomSpeakerAliases: Bool
    let areSuggestionsEnabled: Bool
    let suggestionProviderName: String
    let isRequestInFlight: Bool
    let onRequestSuggestions: () -> Void
    let onConsolidateSpeakers: () -> Void
    let onResetAliases: () -> Void

    var body: some View {
        TranscriptWorkspacePanel(
            title: "Speaker Tools",
            subtitle: BuildFeatures.nameSuggestionsEnabled
                ? "Rename aliases, request suggestions, play one speaker at a time, and keep consolidation as an explicit action."
                : "Rename aliases, play one speaker at a time, and keep consolidation as an explicit action."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TranscriptSummaryChip(title: "\(speakerCount) speakers", systemImage: "person.2.fill", tint: .indigo)
                    TranscriptSummaryChip(title: "\(turnCount) turns", systemImage: "text.alignleft", tint: .blue)
                    if hasConsecutiveSpeakerRuns {
                        TranscriptSummaryChip(title: "Merge recommended", systemImage: "arrow.triangle.merge", tint: .orange)
                    }
                    Spacer(minLength: 0)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actionButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        actionButtons
                    }
                }

                if BuildFeatures.nameSuggestionsEnabled {
                    if !areSuggestionsEnabled {
                        Text("Speaker-name suggestions are disabled in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isRequestInFlight {
                        Text("Contacting \(suggestionProviderName) for speaker name ideas…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Suggestions review existing turns and excerpt context. Consolidation and alias reset stay manual.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Aliases, consolidation, and turn review stay manual in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionButtons: some View {
        Group {
            if BuildFeatures.nameSuggestionsEnabled {
                Button(isRequestInFlight ? "Requesting…" : "Request Suggestions", action: onRequestSuggestions)
                    .buttonStyle(.bordered)
                    .disabled(isRequestInFlight || !areSuggestionsEnabled || speakerCount == 0)
            }

            Button("Consolidate Consecutive Speakers", action: onConsolidateSpeakers)
                .buttonStyle(.bordered)
                .disabled(!hasConsecutiveSpeakerRuns)

            Button("Reset Speaker Names", action: onResetAliases)
                .buttonStyle(.bordered)
                .disabled(!hasCustomSpeakerAliases)
        }
    }
}

private struct TranscriptSpeakerListCard: View {
    let speakers: [TranscriptViewModel.SpeakerState]
    let selectedSpeakerLabel: String?
    let turnCounts: [String: Int]
    let isRequestInFlight: Bool
    let onSelect: (String) -> Void

    var body: some View {
        TranscriptWorkspacePanel(
            title: "Speakers",
            subtitle: "Choose a speaker to edit aliases, play their clips, and verify attribution in context."
        ) {
            if speakers.isEmpty {
                Text("Speaker labels will appear once a diarized transcript is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(speakers) { speaker in
                            Button {
                                onSelect(speaker.label)
                            } label: {
                                TranscriptSpeakerRow(
                                    speaker: speaker,
                                    isSelected: selectedSpeakerLabel == speaker.label,
                                    turnCount: turnCounts[speaker.label, default: 0]
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRequestInFlight)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 440, alignment: .top)
            }
        }
    }
}

private struct TranscriptSpeakerRow: View {
    let speaker: TranscriptViewModel.SpeakerState
    let isSelected: Bool
    let turnCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(speaker.alias)
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                Text("Label \(speaker.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(speaker.excerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Label("\(turnCount) turns", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct TranscriptSpeakerDetailCard: View {
    let speaker: TranscriptViewModel.SpeakerState?
    let speakerTurnCount: Int
    let isRequestInFlight: Bool
    let onCommitAlias: (String, String) -> Void
    let onEditExcerpt: (String) -> Void

    @State private var isSuggestionContextExpanded = false

    var body: some View {
        TranscriptWorkspacePanel(
            title: speaker.map { "\($0.alias) Detail" } ?? "Speaker Detail",
            subtitle: BuildFeatures.nameSuggestionsEnabled
                ? "Aliases change transcript display. Suggestion context only affects future speaker-name requests."
                : "Aliases change transcript display. Clip playback and reassignment happen below."
        ) {
            if let speaker {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TranscriptSummaryChip(title: "Raw label \(speaker.label)", systemImage: "tag", tint: .secondary)
                        TranscriptSummaryChip(title: "\(speakerTurnCount) turns", systemImage: "waveform", tint: .blue)
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alias")
                            .font(.subheadline.weight(.semibold))
                        DeferredCommitSpeakerTextField("Alias", text: speaker.alias) { newAlias in
                            onCommitAlias(speaker.label, newAlias)
                        }
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRequestInFlight)
                        .accessibilityIdentifier("aliasField_\(speaker.label)")
                    }

                    if BuildFeatures.nameSuggestionsEnabled {
                        DisclosureGroup(isExpanded: $isSuggestionContextExpanded) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("This excerpt is only sent when requesting speaker-name suggestions. It does not edit the transcript or change turn boundaries.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(speaker.excerpt)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.18))
                                    )

                                Button {
                                    onEditExcerpt(speaker.label)
                                } label: {
                                    Label("Edit Suggestion Excerpt", systemImage: "square.and.pencil")
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isRequestInFlight)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Advanced Suggestion Context")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            } else {
                Text(
                    BuildFeatures.nameSuggestionsEnabled
                        ? "Select a speaker to review aliases and suggestion context."
                        : "Select a speaker to review aliases and their turns."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TranscriptSpeakerTurnsCard: View {
    let transcript: TranscriptState
    let selectedSpeaker: TranscriptViewModel.SpeakerState?
    @Binding var focusMode: TranscriptSpeakerFocusMode
    let visibleSegments: [TranscriptSegment]
    let audioURL: URL?
    let audioDuration: TimeInterval?
    let onUpdateSpeaker: (String?, UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TranscriptWorkspacePanel(
                title: "Speaker Review",
                subtitle: subtitle
            ) {
                if selectedSpeaker != nil {
                    Picker("Review Mode", selection: $focusMode) {
                        ForEach(TranscriptSpeakerFocusMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("Select a speaker to review their clips and reassign misattributed turns.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            TranscriptSegmentBrowser(
                title: browserTitle,
                subtitle: browserSubtitle,
                emptyMessage: emptyMessage,
                transcript: transcript,
                segments: visibleSegments,
                mode: .speakerEditing,
                audioURL: audioURL,
                audioDuration: audioDuration,
                emphasizedSpeakerLabel: focusMode == .conversationContext ? selectedSpeaker?.label : nil
            ) { segment, playback in
                TranscriptSpeakerInspectorCard(
                    transcript: transcript,
                    selectedSegment: segment,
                    playback: playback,
                    onUpdateSpeaker: onUpdateSpeaker
                )
            }
        }
    }

    private var subtitle: String {
        if focusMode == .selectedSpeaker, let selectedSpeaker {
            return "Play only \(selectedSpeaker.alias)'s clips, then reassign any turn that was attributed to the wrong speaker."
        }
        if let selectedSpeaker {
            return "Keep transcript order intact while visually emphasizing \(selectedSpeaker.alias)'s turns."
        }
        return "Choose a speaker to review their clips in isolation or against the full transcript."
    }

    private var browserTitle: String {
        if focusMode == .selectedSpeaker, let selectedSpeaker {
            return "\(selectedSpeaker.alias) Clips"
        }
        return "Conversation Context"
    }

    private var browserSubtitle: String {
        if focusMode == .selectedSpeaker, let selectedSpeaker {
            return "Only clips currently assigned to \(selectedSpeaker.alias) are shown here."
        }
        if let selectedSpeaker {
            return "Full transcript order stays visible while \(selectedSpeaker.alias)'s clips remain emphasized."
        }
        return "Select a speaker to start review."
    }

    private var emptyMessage: String {
        if focusMode == .selectedSpeaker, let selectedSpeaker {
            return "No clips are currently assigned to \(selectedSpeaker.alias)."
        }
        return "No transcript segments are available for speaker review."
    }
}

private struct TranscriptSpeakerInspectorCard: View {
    let transcript: TranscriptState
    let selectedSegment: TranscriptSegment
    let playback: TranscriptSegmentBrowserPlaybackState
    let onUpdateSpeaker: (String?, UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected Clip")
                    .font(.headline)
                Text("Playback and reassignment stay attached to the clip you selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                TranscriptSegmentDetailBlock(
                    title: "Speaker",
                    value: transcriptSpeakerDisplay(for: selectedSegment, in: transcript)
                )

                TranscriptSegmentDetailBlock(
                    title: "Timestamp",
                    value: transcriptTimestampText(for: selectedSegment)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Playback")
                    .font(.subheadline.weight(.semibold))

                if !playback.audioAvailable {
                    Text("Session audio is not available, so playback is disabled.")
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

                Text("Context playback adds 2 seconds before and after the selected clip when audio bounds allow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker Reassignment")
                    .font(.subheadline.weight(.semibold))

                Picker(
                    "Speaker",
                    selection: Binding<String?>(
                        get: {
                            TranscriptState.canonicalSpeakerLabel(selectedSegment.speakerLabel)
                        },
                        set: { newValue in
                            onUpdateSpeaker(newValue, selectedSegment.id)
                        }
                    )
                ) {
                    ForEach(transcript.orderedSpeakerLabels, id: \.self) { label in
                        Text(speakerOptionLabel(for: label))
                            .tag(Optional(label))
                    }
                }
                .pickerStyle(.menu)

                Text("This changes the selected clip’s canonical speaker label. Consolidation remains a separate speaker-management action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    private func speakerOptionLabel(for label: String) -> String {
        let alias = transcript.alias(for: label)
        if alias == label {
            return alias
        }
        return "\(alias) (\(label))"
    }
}

private struct TranscriptSuggestionOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView("Requesting suggestions…")
                    .progressViewStyle(.circular)
                Text("This may take a moment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12)
        }
    }
}

private struct TranscriptWorkspacePanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct TranscriptSummaryChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

private struct DeferredCommitSpeakerTextField: View {
    let title: String
    let text: String
    let onCommit: (String) -> Void

    @State private var draftText: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.onCommit = onCommit
        _draftText = State(initialValue: text)
    }

    var body: some View {
        TextField(title, text: $draftText)
            .focused($isFocused)
            .onSubmit {
                commit()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: text) { _, newValue in
                if !isFocused && draftText != newValue {
                    draftText = newValue
                }
            }
            .onDisappear {
                commit()
            }
    }

    private func commit() {
        if draftText != text {
            onCommit(draftText)
        }
    }
}

private struct DeferredCommitSpeakerTextEditor: View {
    let text: String
    let onCommit: (String) -> Void

    @State private var draftText: String
    @FocusState private var isFocused: Bool

    init(text: String, onCommit: @escaping (String) -> Void) {
        self.text = text
        self.onCommit = onCommit
        _draftText = State(initialValue: text)
    }

    var body: some View {
        TextEditor(text: $draftText)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: text) { _, newValue in
                if !isFocused && draftText != newValue {
                    draftText = newValue
                }
            }
            .onDisappear {
                commit()
            }
    }

    private func commit() {
        if draftText != text {
            onCommit(draftText)
        }
    }
}

private struct TranscriptSpeakersPreviewContainer: View {
    @State private var state: TranscriptState = {
        let segments = [
            TranscriptSegment(speakerLabel: "SPEAKER_00", text: "Hello, welcome to TotalRec!", start: 0, end: 2.5),
            TranscriptSegment(speakerLabel: "SPEAKER_01", text: "Thanks! It's great to be here.", start: 2.5, end: 4.7),
            TranscriptSegment(speakerLabel: "SPEAKER_00", text: "Let's try out the new speaker alias tools.", start: 4.7, end: 8.1)
        ]
        return TranscriptState(segments: segments)
    }()

    var body: some View {
        TranscriptSpeakersView(
            transcript: $state,
            audioURL: nil,
            audioDuration: 8.1,
            areSuggestionsEnabled: true,
            suggestionProviderName: "OpenAI"
        )
        .frame(width: 900)
        .padding()
    }
}

#Preview {
    TranscriptSpeakersPreviewContainer()
}
