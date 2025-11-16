import SwiftUI
import Combine

struct TranscriptView: View {
    @Binding var transcript: TranscriptState
    @StateObject private var viewModel: TranscriptViewModel
    @Binding private var externalSuggestionTrigger: Int
    @Binding private var externalRequestInFlight: Bool

    @State private var isRequestInFlight: Bool = false
    @State private var requestError: TranscriptViewModel.RequestError?
    @State private var showSuggestionSheet: Bool = false

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
            VStack(spacing: 16) {
                introContent
                transcriptDisplay
                formContent
            }
            .onAppear {
                viewModel.update(from: transcript)
                syncAliasesToTranscript()
            }
            .onChange(of: transcript) { _, newValue in
                viewModel.update(from: newValue)
            }
            .onChange(of: viewModel.speakers) { _, _ in
                syncAliasesToTranscript()
            }
            .onChange(of: externalSuggestionTrigger) { _, _ in
                viewModel.requestSuggestions(using: transcript)
            }

            if isRequestInFlight {
                overlay
            }
        }
        .animation(.easeInOut(duration: 0.1), value: isRequestInFlight)
        .sheet(isPresented: $showSuggestionSheet) {
            suggestionSheet
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

    private var introContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speaker review & smart suggestions")
                .font(.headline)
            Text("Edit speaker aliases manually, review diarized excerpts, or trigger AI-powered name suggestions from the toolbar above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formContent: some View {
        Form {
            Section(header: Text("Speaker Aliases")) {
                if viewModel.speakers.isEmpty {
                    Text("Speaker labels will appear once a diarized transcript is available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach($viewModel.speakers) { $speaker in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Speaker \(speaker.label)")
                                    .font(.headline)
                                Spacer()
                                TextField("Alias", text: $speaker.alias)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isRequestInFlight)
                                    .accessibilityIdentifier("aliasField_\(speaker.label)")
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Excerpt")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $speaker.excerpt)
                                    .frame(minHeight: 96)
                                    .disabled(isRequestInFlight)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.3))
                                    )
                                    .accessibilityIdentifier("excerptEditor_\(speaker.label)")
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    HStack {
                        Button("Reset speaker names") {
                            viewModel.resetAliases()
                        }
                        .disabled(isRequestInFlight)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("resetAliasesButton")
                        Spacer()
                    }
                }
            }
        }
    }

    private var transcriptDisplay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            if transcript.displayText.isEmpty {
                Text("Transcript will appear here once available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    Text(transcript.attributedDisplayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
        }
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
                                        Text("Speaker \(suggestion.label)")
                                            .font(.headline)
                                        TextField("Suggested name", text: $suggestion.name)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("suggestedNameField_\(suggestion.label)")
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

    private func syncAliasesToTranscript() {
        var updated = transcript
        if viewModel.applyAliases(to: &updated) {
            transcript = updated
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
