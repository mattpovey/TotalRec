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

    @ViewBuilder
    private var speakerWorkspace: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 16) {
            speakerListPanel
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 320, alignment: .topLeading)

            speakerDetailWorkspace
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        #else
        VStack(alignment: .leading, spacing: 16) {
            speakerListPanel
            speakerDetailWorkspace
        }
        #endif
    }

    private var speakerListPanel: some View {
        TranscriptSpeakerListCard(
            speakers: viewModel.speakers,
            selectedSpeakerLabel: $selectedSpeakerLabel,
            turnCounts: speakerTurnCounts,
            isRequestInFlight: isRequestInFlight
        )
        .onChange(of: selectedSpeakerLabel) { _, newValue in
            if newValue != nil {
                transcriptFocusMode = .selectedSpeaker
            }
        }
    }

    private var speakerDetailWorkspace: some View {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
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

                speakerWorkspace
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                                    TranscriptInsetPanel(cornerRadius: 10) {
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
                                                    .totalRecReadableInset(cornerRadius: 8)
                                            }
                                        }
                                    }
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
                    .totalRecGlassButton()
                    .accessibilityIdentifier("manualEditButton")

                    Spacer()

                    Button("Retry") {
                        viewModel.retrySuggestions()
                    }
                    .totalRecGlassButton()
                    .accessibilityIdentifier("retrySuggestionsButton")

                    Button("Apply") {
                        viewModel.applySuggestions()
                        syncAliasesToTranscript()
                    }
                    .totalRecGlassButton(prominent: true)
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
                    .totalRecReadableInset(cornerRadius: 12)
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
        TranscriptSurfacePanel(
            title: "Speaker Tools",
            subtitle: BuildFeatures.nameSuggestionsEnabled
                ? "Aliases, suggestions, and consolidation controls."
                : "Aliases and consolidation controls."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        TranscriptSummaryChip(title: "\(speakerCount) speakers", systemImage: "person.2.fill", tint: TotalRecGlass.transcriptViolet)
                        TranscriptSummaryChip(title: "\(turnCount) turns", systemImage: "text.alignleft", tint: TotalRecGlass.captureBlue)
                        if hasConsecutiveSpeakerRuns {
                            TranscriptSummaryChip(title: "Merge recommended", systemImage: "arrow.triangle.merge", tint: TotalRecGlass.warningAmber)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        TranscriptSummaryChip(title: "\(speakerCount) speakers", systemImage: "person.2.fill", tint: TotalRecGlass.transcriptViolet)
                        TranscriptSummaryChip(title: "\(turnCount) turns", systemImage: "text.alignleft", tint: TotalRecGlass.captureBlue)
                        if hasConsecutiveSpeakerRuns {
                            TranscriptSummaryChip(title: "Merge recommended", systemImage: "arrow.triangle.merge", tint: TotalRecGlass.warningAmber)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actionButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        actionButtons
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if BuildFeatures.nameSuggestionsEnabled {
            if !areSuggestionsEnabled {
                return "AI suggestions are off in Settings."
            }
            if isRequestInFlight {
                return "Requesting suggestions from \(suggestionProviderName)…"
            }
            return "Suggestions are optional. Alias edits and consolidation stay manual."
        }

        return "Alias edits and consolidation stay manual in this build."
    }

    private var actionButtons: some View {
        Group {
            if BuildFeatures.nameSuggestionsEnabled {
                Button(isRequestInFlight ? "Requesting…" : "Request Suggestions", action: onRequestSuggestions)
                    .totalRecGlassButton()
                    .disabled(isRequestInFlight || !areSuggestionsEnabled || speakerCount == 0)
            }

            Button("Consolidate Consecutive Speakers", action: onConsolidateSpeakers)
                .totalRecGlassButton()
                .disabled(!hasConsecutiveSpeakerRuns)

            Button("Reset Speaker Names", action: onResetAliases)
                .totalRecGlassButton()
                .disabled(!hasCustomSpeakerAliases)
        }
    }
}

private struct TranscriptSpeakerListCard: View {
    let speakers: [TranscriptViewModel.SpeakerState]
    @Binding var selectedSpeakerLabel: String?
    let turnCounts: [String: Int]
    let isRequestInFlight: Bool

    var body: some View {
        TranscriptSurfacePanel(
            title: "Speakers",
            subtitle: "Select a speaker to rename or review."
        ) {
            if speakers.isEmpty {
                Text("Speaker labels will appear once a diarized transcript is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TranscriptListContainer {
                    List(selection: $selectedSpeakerLabel) {
                        ForEach(speakers) { speaker in
                            TranscriptSpeakerRow(
                                speaker: speaker,
                                turnCount: turnCounts[speaker.label, default: 0]
                            )
                            .tag(Optional(speaker.label))
                            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .disabled(isRequestInFlight)
                }
                .frame(minHeight: 180, maxHeight: 440, alignment: .top)
            }
        }
    }
}

private struct TranscriptSpeakerRow: View {
    let speaker: TranscriptViewModel.SpeakerState
    let turnCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(speaker.alias)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        TranscriptInspectorPanel(
            title: "Selected Speaker",
            subtitle: speaker == nil
                ? "Select a speaker to review alias and context."
                : "Alias changes update transcript display for future review."
        ) {
            if let speaker {
                VStack(alignment: .leading, spacing: 12) {
                    Text(speaker.alias)
                        .font(.headline)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            TranscriptSummaryChip(title: "Raw label \(speaker.label)", systemImage: "tag", tint: .secondary)
                            TranscriptSummaryChip(title: "\(speakerTurnCount) turns", systemImage: "waveform", tint: TotalRecGlass.captureBlue)
                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            TranscriptSummaryChip(title: "Raw label \(speaker.label)", systemImage: "tag", tint: .secondary)
                            TranscriptSummaryChip(title: "\(speakerTurnCount) turns", systemImage: "waveform", tint: TotalRecGlass.captureBlue)
                        }
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
                                TranscriptInsetPanel(cornerRadius: 10) {
                                    Text(speaker.excerpt)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                        .multilineTextAlignment(.leading)
                                        .textSelection(.enabled)
                                }

                                Button {
                                    onEditExcerpt(speaker.label)
                                } label: {
                                    Label("Edit Suggestion Excerpt", systemImage: "square.and.pencil")
                                }
                                .font(.caption.weight(.semibold))
                                .totalRecGlassButton()
                                .controlSize(.small)
                                .disabled(isRequestInFlight)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Suggestion Context")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a Speaker",
                    systemImage: "person.crop.square",
                    description: Text(
                        BuildFeatures.nameSuggestionsEnabled
                            ? "Choose a speaker to review aliases and suggestion context."
                            : "Choose a speaker to review aliases and turns."
                    )
                )
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
            reviewModeControls

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

    @ViewBuilder
    private var reviewModeControls: some View {
        if selectedSpeaker != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review Mode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                reviewModePicker
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }

    private var reviewModePicker: some View {
        Picker("Review Mode", selection: $focusMode) {
            ForEach(TranscriptSpeakerFocusMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var browserTitle: String {
        if focusMode == .selectedSpeaker, let selectedSpeaker {
            return "\(selectedSpeaker.alias) Clips"
        }
        if selectedSpeaker != nil {
            return "Conversation Context"
        }
        return "Speaker Review"
    }

    private var browserSubtitle: String {
        if focusMode == .selectedSpeaker, let selectedSpeaker {
            return "Review clips currently assigned to \(selectedSpeaker.alias)."
        }
        if let selectedSpeaker {
            return "Keep transcript order visible while emphasizing \(selectedSpeaker.alias)'s clips."
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
        TranscriptInspectorPanel(
            title: "Clip Reassignment",
            subtitle: "Review playback and update the selected clip’s speaker."
        ) {
            VStack(alignment: .leading, spacing: 12) {
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
                    Text("Speaker")
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

                    Text("This updates the selected clip’s canonical speaker label.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            .totalRecGlassPanel(cornerRadius: 16, tint: TotalRecGlass.transcriptViolet)
            .totalRecGlassTransition()
        }
    }
}

private struct TranscriptSummaryChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(TotalRecGlass.accentForeground(tint))
            Text(title)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .totalRecGlassPill(tint: tint)
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
