import SwiftUI

struct TranscriptView: View {
    @StateObject private var viewModel: TranscriptViewModel

    @State private var isRequestInFlight: Bool = false
    @State private var requestError: TranscriptViewModel.RequestError?
    @State private var showSuggestionSheet: Bool = false

    init(viewModel: TranscriptViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            content
            if isRequestInFlight {
                overlay
            }
        }
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
            withAnimation(.easeInOut(duration: 0.1)) {
                isRequestInFlight = newValue
            }
        }
        .onReceive(viewModel.$requestError) { newValue in
            requestError = newValue
        }
        .onReceive(viewModel.$showSuggestionSheet) { newValue in
            showSuggestionSheet = newValue
        }
    }

    private var content: some View {
        Form {
            Section(header: Text("Speaker Aliases")) {
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

                Button("Reset speaker names") {
                    viewModel.resetAliases()
                }
                .disabled(isRequestInFlight)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("resetAliasesButton")
            }

            Section(header: Text("Name Suggestions")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use an AI-assisted suggestion to label each speaker.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        viewModel.requestSuggestions()
                    } label: {
                        Label("Request Suggestions", systemImage: "sparkles")
                    }
                    .disabled(isRequestInFlight)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("requestSuggestionsButton")
                }
                .padding(.vertical, 4)
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
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    List(viewModel.suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speaker \(suggestion.label)")
                                .font(.headline)
                            Text(suggestion.name)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
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
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("applySuggestionsButton")
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top)
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
}

#Preview {
    TranscriptView(viewModel: TranscriptViewModel(numberOfSpeakers: 3))
}
