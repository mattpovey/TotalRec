import SwiftUI
import Combine

enum TotalRecSettingsCategory: String, CaseIterable, Identifiable {
    case providers
    case transcription
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers:
            return "Providers"
        case .transcription:
            return "Transcription"
        case .insights:
            return "Insights"
        }
    }

    var systemImage: String {
        switch self {
        case .providers:
            return "key.horizontal"
        case .transcription:
            return "waveform.and.mic"
        case .insights:
            return "sparkles.rectangle.stack"
        }
    }

    var subtitle: String {
        switch self {
        case .providers:
            return "Manage credentials, compatible endpoints, and shared model catalogs."
        case .transcription:
            return "Configure the private transcription server and speaker-name assistance."
        case .insights:
            return "Choose the default workflow, provider, and model for new insight artifacts."
        }
    }
}

struct TotalRecSettingsView: View {
    private static let contentColumnWidth: CGFloat = 720
    private static let apiKeyFieldWidth: CGFloat = 420

    @EnvironmentObject private var appModel: AppModel

    @State private var nameSuggestionProvider: NameSuggestionProvider
    @State private var defaultInsightWorkflow: InsightWorkflow
    @State private var defaultInsightProvider: LLMProvider
    @State private var defaultInsightModelID: String
    @State private var nameSuggestionModelID: String
    @State private var openAIAPIKey: String
    @State private var sambaNovaAPIKey: String
    @State private var sambaNovaBaseURL: String
    @State private var openAIModels: [ProviderModelDescriptor]
    @State private var sambaNovaModels: [ProviderModelDescriptor]
    @State private var openAIModelsUpdatedAt: Date?
    @State private var sambaNovaModelsUpdatedAt: Date?
    @State private var isOpenAIModelsLoading = false
    @State private var isSambaNovaModelsLoading = false
    @State private var openAIModelsError: String?
    @State private var sambaNovaModelsError: String?
    @State private var tScriptConfiguration: TScriptConfiguration
    @State private var selectedCategory: TotalRecSettingsCategory = .providers

    private let llmModelCatalogService = LLMModelCatalogService()

    init() {
        let config = AIConfigManager.shared.configuration
        _nameSuggestionProvider = State(initialValue: config.normalizedNameSuggestionProvider)
        _defaultInsightWorkflow = State(initialValue: config.normalizedInsightWorkflow)
        _defaultInsightProvider = State(initialValue: config.normalizedInsightProvider)
        _defaultInsightModelID = State(initialValue: config.defaultInsightModelID)
        _nameSuggestionModelID = State(initialValue: config.nameSuggestionModelID)
        _openAIAPIKey = State(initialValue: AIConfigManager.shared.openAIKey() ?? "")
        _sambaNovaAPIKey = State(initialValue: AIConfigManager.shared.sambaNovaKey() ?? "")
        _sambaNovaBaseURL = State(initialValue: AIConfigManager.shared.baseURL(for: .sambaNova))
        _openAIModels = State(initialValue: config.openAI.cachedModels)
        _sambaNovaModels = State(initialValue: config.sambaNova.cachedModels)
        _openAIModelsUpdatedAt = State(initialValue: config.openAI.modelsUpdatedAt)
        _sambaNovaModelsUpdatedAt = State(initialValue: config.sambaNova.modelsUpdatedAt)
        _tScriptConfiguration = State(initialValue: config.tscript)
    }

    private var hasOpenAIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSambaNovaKey: Bool {
        !sambaNovaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTScriptBaseURL: Bool {
        !tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedTScriptBaseURL: String {
        let trimmed = tScriptConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private var tScriptBaseURLScheme: String? {
        guard !normalizedTScriptBaseURL.isEmpty else { return nil }
        return URL(string: normalizedTScriptBaseURL)?.scheme?.lowercased()
    }

    private var tScriptTransportWarningText: String? {
        if tScriptBaseURLScheme == "http" && !tScriptConfiguration.allowInsecureHTTP {
            return "This endpoint uses HTTP. Enable the insecure override only for a trusted private server."
        }
        if tScriptBaseURLScheme == "http" && tScriptConfiguration.allowInsecureHTTP {
            return "Insecure HTTP override is enabled. Traffic to this server is not protected by TLS."
        }
        if tScriptBaseURLScheme == "https" && tScriptConfiguration.allowInvalidTLSCertificates {
            return "Invalid TLS certificate override is enabled for this host."
        }
        return nil
    }

    var body: some View {
        TabView(selection: $selectedCategory) {
            ForEach(TotalRecSettingsCategory.allCases) { category in
                settingsPage(for: category)
                    .tag(category)
                    .tabItem {
                        Label(category.title, systemImage: category.systemImage)
                    }
                    .accessibilityIdentifier("settingsCategory_\(category.rawValue)")
            }
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 500, idealHeight: 620)
        .onChange(of: nameSuggestionProvider) { _, newProvider in
            do {
                try AIConfigManager.shared.setNameSuggestionProvider(newProvider.rawValue)
                nameSuggestionModelID = AIConfigManager.shared.configuration.nameSuggestionModelID
            } catch {
                appModel.showNotice("Failed to save name suggestion provider: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: defaultInsightWorkflow) { _, newWorkflow in
            do {
                try AIConfigManager.shared.setDefaultInsightWorkflow(newWorkflow)
            } catch {
                appModel.showNotice("Failed to save default insight workflow: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: defaultInsightProvider) { _, newProvider in
            do {
                try AIConfigManager.shared.setDefaultInsightProvider(newProvider)
                defaultInsightModelID = AIConfigManager.shared.configuration.defaultInsightModelID
            } catch {
                appModel.showNotice("Failed to save default insight provider: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: defaultInsightModelID) { _, newModelID in
            do {
                try AIConfigManager.shared.setDefaultInsightModelID(newModelID)
            } catch {
                appModel.showNotice("Failed to save default insight model: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: nameSuggestionModelID) { _, newModelID in
            do {
                try AIConfigManager.shared.setNameSuggestionModelID(newModelID)
            } catch {
                appModel.showNotice("Failed to save name suggestion model: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: openAIAPIKey) { _, newKey in
            do {
                try AIConfigManager.shared.updateOpenAIKey(newKey.isEmpty ? nil : newKey)
            } catch {
                appModel.showNotice("Failed to save OpenAI key: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: sambaNovaAPIKey) { _, newKey in
            do {
                try AIConfigManager.shared.updateSambaNovaKey(newKey.isEmpty ? nil : newKey)
            } catch {
                appModel.showNotice("Failed to save SambaNova key: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: sambaNovaBaseURL) { oldValue, newValue in
            do {
                try AIConfigManager.shared.setBaseURL(newValue, for: .sambaNova)
                if oldValue.trimmingCharacters(in: .whitespacesAndNewlines) != newValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                    sambaNovaModels = []
                    sambaNovaModelsUpdatedAt = nil
                    sambaNovaModelsError = nil
                    try AIConfigManager.shared.updateCachedModels([], for: .sambaNova)
                    nameSuggestionModelID = AIConfigManager.shared.configuration.nameSuggestionModelID
                    defaultInsightModelID = AIConfigManager.shared.configuration.defaultInsightModelID
                }
            } catch {
                appModel.showNotice("Failed to save SambaNova base URL: \(error.localizedDescription)", style: .error)
            }
        }
        .onChange(of: tScriptConfiguration) { oldValue, newValue in
            handleTScriptConfigurationChange(oldValue: oldValue, newValue: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .totalRecAIConfigurationDidChange)) { _ in
            syncFromStoredConfiguration()
        }
    }

    private func settingsPage(for category: TotalRecSettingsCategory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsLead(for: category)

                if let notice = appModel.transientNotice {
                    TransientNoticeBanner(
                        notice: notice,
                        onDismiss: appModel.dismissTransientNotice
                    )
                    .id(notice.id)
                }

                settingsSections(for: category)
            }
            .frame(maxWidth: Self.contentColumnWidth, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func settingsLead(for category: TotalRecSettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title)
                .font(.title3.weight(.semibold))
            Text(category.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func settingsSections(for category: TotalRecSettingsCategory) -> some View {
        switch category {
        case .providers:
            providerCredentialsSection
        case .transcription:
            tScriptServerSection
            if BuildFeatures.nameSuggestionsEnabled {
                nameSuggestionsSection
            }
        case .insights:
            insightDefaultsSection
        }
    }

    private var providerCredentialsSection: some View {
        settingsSection(
            title: "Text Providers",
            subtitle: "Store credentials and refresh the shared model catalogs."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                providerCredentialGroup(
                    provider: .openAI,
                    subtitle: "Used for OpenAI transcription and compatible insight workflows.",
                    apiKey: $openAIAPIKey,
                    hasKey: hasOpenAIKey,
                    baseURLBinding: nil,
                    models: openAIModels,
                    isLoading: isOpenAIModelsLoading,
                    refreshError: openAIModelsError
                )

                providerCredentialGroup(
                    provider: .sambaNova,
                    subtitle: "Used for SambaNova-backed insights and name suggestions.",
                    apiKey: $sambaNovaAPIKey,
                    hasKey: hasSambaNovaKey,
                    baseURLBinding: $sambaNovaBaseURL,
                    models: sambaNovaModels,
                    isLoading: isSambaNovaModelsLoading,
                    refreshError: sambaNovaModelsError
                )
            }
        }
    }

    private var insightDefaultsSection: some View {
        settingsSection(
            title: "Insights",
            subtitle: "Choose the default workflow and provider for new artifact runs."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Default Workflow", selection: $defaultInsightWorkflow) {
                    ForEach(InsightWorkflow.allCases) { workflow in
                        Text(workflow.displayName).tag(workflow)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)

                Picker("Provider", selection: $defaultInsightProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Model", selection: $defaultInsightModelID) {
                    ForEach(effectiveModelChoices(for: defaultInsightProvider, feature: .insights, selectedID: defaultInsightModelID)) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)

                Text(defaultInsightWorkflow.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nameSuggestionsSection: some View {
        settingsSection(
            title: "Name Suggestions",
            subtitle: "Choose how diarized speakers get AI-assisted names."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $nameSuggestionProvider) {
                    ForEach(NameSuggestionProvider.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420, alignment: .leading)

                if let llmProvider = nameSuggestionProvider.llmProvider {
                    Picker("Model", selection: $nameSuggestionModelID) {
                        ForEach(effectiveModelChoices(for: llmProvider, feature: .nameSuggestions, selectedID: nameSuggestionModelID)) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360, alignment: .leading)

                    Text("\(llmProvider.displayName) will be used when speaker-name suggestions are enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Speaker-name suggestions are off. Cleanup stays manual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tScriptServerSection: some View {
        settingsSection(
            title: "TScript Server",
            subtitle: "Configure the private server used for model discovery and transcription."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: hasTScriptBaseURL ? "server.rack" : "network.slash")
                        .foregroundStyle(hasTScriptBaseURL ? TotalRecGlass.accentForeground(TotalRecGlass.successGreen) : .secondary)

                    DeferredCommitTextField("https://transcribe-api.localhost:1355", text: $tScriptConfiguration.baseURL)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .totalRecReadableInset(cornerRadius: 12)

                if hasTScriptBaseURL {
                    LabeledContent("Resolved Endpoint") {
                        Text(normalizedTScriptBaseURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Allow insecure HTTP", isOn: $tScriptConfiguration.allowInsecureHTTP)
                Toggle("Allow invalid TLS certificates", isOn: $tScriptConfiguration.allowInvalidTLSCertificates)

                Text("Keep both overrides off unless this is a private server you control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = tScriptTransportWarningText {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(TotalRecGlass.warningAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func providerModels(for provider: LLMProvider) -> [ProviderModelDescriptor] {
        switch provider {
        case .openAI:
            return openAIModels
        case .sambaNova:
            return sambaNovaModels
        }
    }

    private func effectiveModelChoices(
        for provider: LLMProvider,
        feature: LLMFeature,
        selectedID: String
    ) -> [ProviderModelDescriptor] {
        let filtered = providerModels(for: provider).filter { $0.supports(feature: feature) }
        let trimmed = selectedID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if !filtered.isEmpty {
                return filtered
            }
            return [
                ProviderModelDescriptor(
                    id: provider.defaultModelID(for: feature),
                    displayName: provider.defaultModelID(for: feature),
                    provider: provider,
                    contextWindow: nil,
                    supportsStreaming: true,
                    supportsJSONMode: true,
                    lifecycle: .unknown
                )
            ]
        }

        if filtered.contains(where: { $0.id == trimmed }) {
            return filtered
        }

        return filtered + [
            ProviderModelDescriptor(
                id: trimmed,
                displayName: trimmed,
                provider: provider,
                contextWindow: nil,
                supportsStreaming: true,
                supportsJSONMode: true,
                lifecycle: .unknown
            )
        ]
    }

    private func modelRefreshStatus(for provider: LLMProvider) -> String {
        let updatedAt: Date?
        let models: [ProviderModelDescriptor]
        switch provider {
        case .openAI:
            updatedAt = openAIModelsUpdatedAt
            models = openAIModels
        case .sambaNova:
            updatedAt = sambaNovaModelsUpdatedAt
            models = sambaNovaModels
        }

        if let updatedAt {
            return "Loaded \(models.count) models on \(updatedAt.formatted(date: .abbreviated, time: .shortened))."
        }

        return models.isEmpty ? "No cached models yet." : "Loaded \(models.count) cached models."
    }

    private func syncFromStoredConfiguration() {
        let config = AIConfigManager.shared.configuration

        openAIAPIKey = AIConfigManager.shared.openAIKey() ?? ""
        sambaNovaAPIKey = AIConfigManager.shared.sambaNovaKey() ?? ""
        sambaNovaBaseURL = AIConfigManager.shared.baseURL(for: .sambaNova)
        openAIModels = config.openAI.cachedModels
        sambaNovaModels = config.sambaNova.cachedModels
        openAIModelsUpdatedAt = config.openAI.modelsUpdatedAt
        sambaNovaModelsUpdatedAt = config.sambaNova.modelsUpdatedAt
        tScriptConfiguration = config.tscript
        nameSuggestionProvider = config.normalizedNameSuggestionProvider
        defaultInsightWorkflow = config.normalizedInsightWorkflow
        defaultInsightProvider = config.normalizedInsightProvider
        defaultInsightModelID = config.defaultInsightModelID
        nameSuggestionModelID = config.nameSuggestionModelID
    }

    private func handleTScriptConfigurationChange(oldValue: TScriptConfiguration, newValue: TScriptConfiguration) {
        do {
            try AIConfigManager.shared.updateTScriptConfiguration(newValue)
        } catch {
            appModel.showNotice("Failed to save TScript settings: \(error.localizedDescription)", style: .error)
        }
    }

    private func refreshLLMModels(for provider: LLMProvider) {
        switch provider {
        case .openAI:
            guard hasOpenAIKey else {
                openAIModelsError = "Add an OpenAI key before loading models."
                return
            }
            guard !isOpenAIModelsLoading else { return }
            isOpenAIModelsLoading = true
            openAIModelsError = nil
        case .sambaNova:
            guard hasSambaNovaKey else {
                sambaNovaModelsError = "Add a SambaNova key before loading models."
                return
            }
            guard !isSambaNovaModelsLoading else { return }
            isSambaNovaModelsLoading = true
            sambaNovaModelsError = nil
        }

        Task {
            do {
                let models = try await llmModelCatalogService.fetchModels(for: provider)
                try AIConfigManager.shared.updateCachedModels(models, for: provider)
                let config = AIConfigManager.shared.configuration

                await MainActor.run {
                    switch provider {
                    case .openAI:
                        isOpenAIModelsLoading = false
                        openAIModels = config.openAI.cachedModels
                        openAIModelsUpdatedAt = config.openAI.modelsUpdatedAt
                        openAIModelsError = nil
                    case .sambaNova:
                        isSambaNovaModelsLoading = false
                        sambaNovaModels = config.sambaNova.cachedModels
                        sambaNovaModelsUpdatedAt = config.sambaNova.modelsUpdatedAt
                        sambaNovaModelsError = nil
                    }

                    defaultInsightModelID = config.defaultInsightModelID
                    nameSuggestionModelID = config.nameSuggestionModelID
                }
            } catch {
                await MainActor.run {
                    switch provider {
                    case .openAI:
                        isOpenAIModelsLoading = false
                        openAIModelsError = error.localizedDescription
                    case .sambaNova:
                        isSambaNovaModelsLoading = false
                        sambaNovaModelsError = error.localizedDescription
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func providerCredentialGroup(
        provider: LLMProvider,
        subtitle: String,
        apiKey: Binding<String>,
        hasKey: Bool,
        baseURLBinding: Binding<String>?,
        models: [ProviderModelDescriptor],
        isLoading: Bool,
        refreshError: String?
    ) -> some View {
        GroupBox(provider.displayName) {
            VStack(alignment: .leading, spacing: 12) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        providerAPIKeyField(apiKey: apiKey)
                            .frame(maxWidth: Self.apiKeyFieldWidth, alignment: .leading)
                        providerStatusSummary(hasKey: hasKey, models: models, isLoading: isLoading)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        providerAPIKeyField(apiKey: apiKey)
                        providerStatusSummary(hasKey: hasKey, models: models, isLoading: isLoading)
                    }
                }

                if let baseURLBinding {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)

                        DeferredCommitTextField(provider.defaultBaseURL, text: baseURLBinding)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .totalRecReadableInset(cornerRadius: 12)
                }

                HStack(spacing: 10) {
                    Button(isLoading ? "Refreshing…" : "Refresh Models") {
                        refreshLLMModels(for: provider)
                    }
                    .disabled(isLoading || !hasKey)
                    .controlSize(.small)

                    Text(modelRefreshStatus(for: provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if hasKey {
                        Button("Clear Key") {
                            switch provider {
                            case .openAI:
                                openAIAPIKey = ""
                            case .sambaNova:
                                sambaNovaAPIKey = ""
                            }
                        }
                        .controlSize(.small)
                    }
                }

                if let refreshError, !refreshError.isEmpty {
                    Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func providerAPIKeyField(apiKey: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            DeferredCommitSecureField("Stored in Keychain", text: apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func providerStatusSummary(
        hasKey: Bool,
        models: [ProviderModelDescriptor],
        isLoading: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(hasKey ? "Key stored in Keychain" : "Key required", systemImage: hasKey ? "key.fill" : "key.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasKey ? TotalRecGlass.accentForeground(TotalRecGlass.successGreen) : TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))

            Text(isLoading ? "Refreshing model catalog…" : "\(models.count) cached models")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 140, alignment: .leading)
    }
}
