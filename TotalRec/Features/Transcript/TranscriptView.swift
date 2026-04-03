import SwiftUI
import Combine

fileprivate enum TranscriptFocusMode: String, CaseIterable, Identifiable {
    case full = "Full Transcript"
    case selectedSpeaker = "Selected Speaker"

    var id: String { rawValue }
}

struct TranscriptView: View {
    @Binding var transcript: TranscriptState
    @StateObject private var viewModel: TranscriptViewModel
    @Binding private var externalSuggestionTrigger: Int
    @Binding private var externalRequestInFlight: Bool

    @State private var isRequestInFlight: Bool = false
    @State private var requestError: TranscriptViewModel.RequestError?
    @State private var showSuggestionSheet: Bool = false
    @State private var selectedSpeakerLabel: String?
    @State private var transcriptFocusMode: TranscriptFocusMode = .full
    @State private var excerptEditorTarget: ExcerptEditorTarget?
    @State private var speakerTurnCountsCache: [String: Int] = [:]
    @State private var speakerListRevision: Int = 0
    @State private var transcriptDocumentRevision: Int = 0
    @State private var fullTranscriptDisplayText = AttributedString()
    @State private var focusedTranscriptDisplayText = ""

    private struct SummaryBadge: Identifiable {
        let title: String
        let systemImage: String
        let tint: Color

        var id: String { "\(title)-\(systemImage)" }
    }

    private struct ExcerptEditorTarget: Identifiable {
        let label: String

        var id: String { label }
    }

    init(
        transcript: Binding<TranscriptState>,
        suggestionService: NameSuggestionService = NameSuggestionService(),
        externalSuggestionTrigger: Binding<Int> = .constant(0),
        externalRequestInFlight: Binding<Bool> = .constant(false)
    ) {
        _transcript = transcript
        _externalSuggestionTrigger = externalSuggestionTrigger
        _externalRequestInFlight = externalRequestInFlight
        _viewModel = StateObject(wrappedValue: TranscriptViewModel(transcript: transcript.wrappedValue, suggestionService: suggestionService))
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                workspaceSummary
                reviewWorkspace
            }
            .onAppear {
                viewModel.update(from: transcript)
                refreshDerivedState(from: transcript)
                syncAliasesToTranscript()
                syncSelectedSpeaker()
            }
            .onChange(of: transcript) { _, newValue in
                viewModel.update(from: newValue)
                syncSelectedSpeaker()
                refreshDerivedState(from: newValue)
            }
            .onChange(of: activeSpeakerLabel) { _, _ in
                refreshFocusedTranscriptText()
            }
            .onChange(of: transcriptFocusMode) { _, _ in
                refreshFocusedTranscriptText()
            }
            .onChange(of: externalSuggestionTrigger) { _, _ in
                viewModel.requestSuggestions(using: transcript)
            }
            .onDisappear {
                syncAliasesToTranscript()
            }
            .onReceive(viewModel.$speakers) { _ in
                speakerListRevision &+= 1
            }

            if isRequestInFlight {
                overlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.1), value: isRequestInFlight)
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
            externalRequestInFlight = newValue
        }
        .onReceive(viewModel.$requestError) { newValue in
            requestError = newValue
        }
        .onReceive(viewModel.$showSuggestionSheet) { newValue in
            showSuggestionSheet = newValue
        }
    }

    private var workspaceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasSpeakerReviewWorkspace ? "Speaker review workspace" : "Transcript workspace")
                .font(.headline)
            Text(
                hasSpeakerReviewWorkspace
                    ? "Review diarized speakers, tune aliases, inspect the supporting excerpts, and keep the transcript in view while you edit."
                    : "This transcript does not include speaker labels, so the workspace stays focused on the full text."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(summaryBadges) { badge in
                    summaryChip(badge.title, systemImage: badge.systemImage, tint: badge.tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var reviewWorkspace: some View {
        if !hasSpeakerReviewWorkspace {
            transcriptDocumentPanel
        } else {
            HStack(alignment: .top, spacing: 16) {
                speakerNavigatorPanel
                    .frame(width: 280)

                VStack(alignment: .leading, spacing: 16) {
                    selectedSpeakerPanel
                    transcriptDocumentPanel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var speakerNavigatorPanel: some View {
        workspacePanel(title: "Speakers", subtitle: "Choose a speaker to review aliases and excerpts in context.") {
            TranscriptSpeakerList(
                revision: speakerListRevision,
                speakers: viewModel.speakers,
                selectedSpeakerLabel: activeSpeakerLabel,
                turnCounts: speakerTurnCounts,
                isRequestInFlight: isRequestInFlight,
                onSelect: { label in
                    selectedSpeakerLabel = label
                }
            )
            .equatable()
        }
    }

    private var selectedSpeakerPanel: some View {
        SelectedSpeakerPanel(
            speaker: selectedSpeaker,
            speakerTurnCount: selectedSpeaker.map { speakerTurnCount(for: $0.label) } ?? 0,
            title: activeSpeakerTitle,
            isRequestInFlight: isRequestInFlight,
            onCommitAlias: { label, alias in
                commitAlias(alias, for: label)
            },
            onEditExcerpt: { label in
                excerptEditorTarget = ExcerptEditorTarget(label: label)
            }
        )
    }

    private var transcriptDocumentPanel: some View {
        workspacePanel(title: "Transcript", subtitle: transcriptPanelSubtitle) {
            if !transcript.hasDisplayText {
                Text("Transcript will appear here once available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if activeSpeakerLabel != nil {
                        Picker("Transcript Focus", selection: $transcriptFocusMode) {
                            ForEach(TranscriptFocusMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    ScrollView {
                        EquatableTranscriptDisplayContent(
                            revision: transcriptDocumentRevision,
                            fullText: fullTranscriptDisplayText,
                            focusedText: focusedTranscriptDisplayText,
                            transcriptFocusMode: transcriptFocusMode
                        )
                        .equatable()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .frame(minHeight: 220)
                }
            }
        }
    }

    private var activeSpeakerTitle: String {
        guard let selectedSpeaker else { return "Speaker detail" }
        return "\(selectedSpeaker.alias) detail"
    }

    private var transcriptPanelSubtitle: String {
        if !hasSpeakerReviewWorkspace {
            return "Showing the full transcript text. Speaker review tools appear automatically when diarized labels are available."
        }
        if transcriptFocusMode == .selectedSpeaker, let selectedSpeaker {
            return "Showing only turns spoken by \(selectedSpeaker.alias). Switch back to the full transcript any time."
        }
        return "Keep the diarized transcript visible while you review speakers and suggestion context."
    }

    private var transcriptSegmentCount: Int {
        transcript.segments.isEmpty
            ? transcript.rawText.split(whereSeparator: \.isNewline).count
            : transcript.segments.count
    }

    private var durationText: String? {
        guard let first = transcript.segments.first,
              let last = transcript.segments.last else { return nil }

        let start = first.start ?? 0
        let end = last.end ?? last.start ?? start
        guard end > start else { return nil }
        return "≈ \(formatDuration(end - start))"
    }

    private var activeSpeakerLabel: String? {
        if let selectedSpeakerLabel,
           viewModel.speakers.contains(where: { $0.label == selectedSpeakerLabel }) {
            return selectedSpeakerLabel
        }
        return viewModel.speakers.first?.label
    }

    private var hasSpeakerReviewWorkspace: Bool {
        !viewModel.speakers.isEmpty
    }

    private var speakerTurnCounts: [String: Int] {
        speakerTurnCountsCache
    }

    private var selectedSpeaker: TranscriptViewModel.SpeakerState? {
        guard let activeSpeakerLabel else {
            return nil
        }
        return viewModel.speakers.first(where: { $0.label == activeSpeakerLabel })
    }

    private var summaryBadges: [SummaryBadge] {
        var badges = [
            SummaryBadge(title: "\(viewModel.speakers.count) speakers", systemImage: "person.2.fill", tint: .indigo),
            SummaryBadge(title: "\(transcriptSegmentCount) turns", systemImage: "text.alignleft", tint: .blue)
        ]

        if let durationText {
            badges.append(SummaryBadge(title: durationText, systemImage: "clock", tint: .secondary))
        }

        if transcript.hasConsecutiveSpeakerRuns {
            badges.append(SummaryBadge(title: "Merge recommended", systemImage: "arrow.triangle.merge", tint: .orange))
        }

        if transcriptFocusMode == .selectedSpeaker, let selectedSpeaker {
            badges.append(SummaryBadge(title: "Focused on \(selectedSpeaker.alias)", systemImage: "scope", tint: .green))
        }

        return badges
    }

    private func speakerTurnCount(for label: String) -> Int {
        speakerTurnCounts[label, default: 0]
    }

    private func syncSelectedSpeaker() {
        guard !viewModel.speakers.isEmpty else {
            selectedSpeakerLabel = nil
            transcriptFocusMode = .full
            return
        }

        if let selectedSpeakerLabel,
           viewModel.speakers.contains(where: { $0.label == selectedSpeakerLabel }) {
            return
        }

        selectedSpeakerLabel = viewModel.speakers.first?.label
    }

    private func refreshDerivedState(from transcript: TranscriptState) {
        speakerTurnCountsCache = transcript.segments.reduce(into: [String: Int]()) { counts, segment in
            guard let label = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) else {
                return
            }
            counts[label, default: 0] += 1
        }
        fullTranscriptDisplayText = transcript.attributedDisplayText
        refreshFocusedTranscriptText(using: transcript)
    }

    private func refreshFocusedTranscriptText(using transcript: TranscriptState? = nil) {
        focusedTranscriptDisplayText = focusedTranscriptText(
            for: activeSpeakerLabel,
            in: transcript ?? self.transcript
        )
        transcriptDocumentRevision &+= 1
    }

    private func focusedTranscriptText(for activeSpeakerLabel: String?, in transcript: TranscriptState) -> String {
        guard let activeSpeakerLabel else { return transcript.displayText }
        let filteredSegments = transcript.segments.filter {
            TranscriptState.canonicalSpeakerLabel($0.speakerLabel) == activeSpeakerLabel
        }

        if filteredSegments.isEmpty {
            return transcript.displayText
        }

        let alias = transcript.alias(for: activeSpeakerLabel)
        return filteredSegments
            .map { segment in
                let prefix = timestampPrefix(for: segment)
                return prefix.isEmpty
                    ? "\(alias): \(segment.text)"
                    : "\(prefix) \(alias): \(segment.text)"
            }
            .joined(separator: "\n\n")
    }

    private func timestampPrefix(for segment: TranscriptSegment) -> String {
        guard segment.start != nil || segment.end != nil else { return "" }
        let startText = formatDuration(segment.start ?? 0)
        let endText = segment.end.map(formatDuration)
        if let endText {
            return "[\(startText)-\(endText)]"
        }
        return "[\(startText)]"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func summaryChip(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private func workspacePanel<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
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

    private var overlay: some View {
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
                        // Ensure aliases are written into the bound transcript immediately
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

    private func excerptEditButton(for label: String) -> some View {
        Button {
            excerptEditorTarget = ExcerptEditorTarget(label: label)
        } label: {
            Label("Edit suggestion excerpt", systemImage: "square.and.pencil")
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRequestInFlight)
    }

    @ViewBuilder
    private func excerptEditorSheet(for label: String) -> some View {
        if let speaker = viewModel.speakers.first(where: { $0.label == label }) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This excerpt is only used when requesting speaker-name suggestions. It does not edit the transcript text below.")
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
                .navigationTitle("\(transcript.alias(for: label)) Excerpt")
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

    private func syncAliasesToTranscript() {
        var updated = transcript
        if viewModel.applyAliases(to: &updated) {
            transcript = updated
        }
    }

    private func commitAlias(_ alias: String, for label: String) {
        viewModel.updateAlias(alias, for: label)
        syncAliasesToTranscript()
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

private struct SelectedSpeakerPanel: View {
    let speaker: TranscriptViewModel.SpeakerState?
    let speakerTurnCount: Int
    let title: String
    let isRequestInFlight: Bool
    let onCommitAlias: (String, String) -> Void
    let onEditExcerpt: (String) -> Void

    var body: some View {
        workspacePanel(
            title: title,
            subtitle: "Aliases affect how the transcript is displayed. Excerpts are used when requesting speaker-name suggestions."
        ) {
            if let speaker {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        summaryChip("Raw label \(speaker.label)", systemImage: "tag", tint: .secondary)
                        summaryChip("\(speakerTurnCount) turns", systemImage: "waveform", tint: .blue)
                        Spacer(minLength: 0)
                    }

                    excerptEditButton(for: speaker.label)

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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Excerpt Used For Suggestions")
                            .font(.subheadline.weight(.semibold))
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

                        Text("This is the excerpt currently used for speaker-name suggestions. Editing it does not change the transcript itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Select a speaker to review aliases and suggestion excerpts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summaryChip(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private func excerptEditButton(for label: String) -> some View {
        Button {
            onEditExcerpt(label)
        } label: {
            Label("Edit suggestion excerpt", systemImage: "square.and.pencil")
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRequestInFlight)
    }

    private func workspacePanel<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
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

private struct TranscriptSpeakerList: View, Equatable {
    let revision: Int
    let speakers: [TranscriptViewModel.SpeakerState]
    let selectedSpeakerLabel: String?
    let turnCounts: [String: Int]
    let isRequestInFlight: Bool
    let onSelect: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision &&
        lhs.selectedSpeakerLabel == rhs.selectedSpeakerLabel &&
        lhs.isRequestInFlight == rhs.isRequestInFlight
    }

    var body: some View {
        if speakers.isEmpty {
            Text("Speaker labels will appear once a diarized transcript is available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if speakers.count <= 4 {
            VStack(alignment: .leading, spacing: 10) {
                speakerRows
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    speakerRows
                }
            }
            .frame(minHeight: 180, maxHeight: 360, alignment: .top)
        }
    }

    @ViewBuilder
    private var speakerRows: some View {
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

private struct EquatableTranscriptDisplayContent: View, Equatable {
    let revision: Int
    let fullText: AttributedString
    let focusedText: String
    let transcriptFocusMode: TranscriptFocusMode

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision &&
        lhs.transcriptFocusMode == rhs.transcriptFocusMode
    }

    var body: some View {
        Group {
            if transcriptFocusMode == .selectedSpeaker {
                Text(focusedText)
            } else {
                Text(fullText)
            }
        }
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
        self._draftText = State(initialValue: text)
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
        self._draftText = State(initialValue: text)
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

private struct TranscriptViewPreviewContainer: View {
    @State private var state: TranscriptState = {
        let segments = [
            TranscriptSegment(speakerLabel: "A", text: "Hello, welcome to TotalRec!", start: 0, end: 2.5),
            TranscriptSegment(speakerLabel: "B", text: "Thanks! It's great to be here.", start: 2.5, end: 4.7),
            TranscriptSegment(speakerLabel: "A", text: "Let's try out the new speaker alias tools.", start: 4.7, end: 8.1)
        ]
        return TranscriptState(segments: segments)
    }()
    @State private var trigger: Int = 0
    @State private var inFlight: Bool = false

    var body: some View {
        TranscriptView(
            transcript: $state,
            externalSuggestionTrigger: $trigger,
            externalRequestInFlight: $inFlight
        )
            .frame(width: 600)
            .padding()
    }
}

#Preview {
    TranscriptViewPreviewContainer()
}
