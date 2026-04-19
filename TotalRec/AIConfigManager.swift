import Foundation
import Security

extension Notification.Name {
    static let totalRecAIConfigurationDidChange = Notification.Name("TotalRecAIConfigurationDidChange")
}

struct AIConfiguration: Codable {
    var defaultProvider: String
    var nameSuggestionProvider: String
    var defaultInsightWorkflow: String
    var defaultInsightProvider: String
    var defaultInsightModelID: String
    var nameSuggestionModelID: String
    var openAIAPIKey: String?
    var sambaNovaAPIKey: String?
    var openAI: LLMProviderConfiguration
    var sambaNova: LLMProviderConfiguration
    var tscript: TScriptConfiguration

    init(
        defaultProvider: String = "openai",
        nameSuggestionProvider: String = NameSuggestionProvider.buildDefault.rawValue,
        defaultInsightWorkflow: String = InsightWorkflow.fallbackDefault.rawValue,
        defaultInsightProvider: String = LLMProvider.openAI.rawValue,
        defaultInsightModelID: String = LLMProvider.openAI.defaultModelID(for: .insights),
        nameSuggestionModelID: String = LLMProvider.openAI.defaultModelID(for: .nameSuggestions),
        openAIAPIKey: String? = nil,
        sambaNovaAPIKey: String? = nil,
        openAI: LLMProviderConfiguration = LLMProviderConfiguration(baseURL: LLMProvider.openAI.defaultBaseURL),
        sambaNova: LLMProviderConfiguration = LLMProviderConfiguration(baseURL: LLMProvider.sambaNova.defaultBaseURL),
        tscript: TScriptConfiguration = TScriptConfiguration()
    ) {
        self.defaultProvider = defaultProvider
        self.nameSuggestionProvider = nameSuggestionProvider
        self.defaultInsightWorkflow = defaultInsightWorkflow
        self.defaultInsightProvider = defaultInsightProvider
        self.defaultInsightModelID = defaultInsightModelID
        self.nameSuggestionModelID = nameSuggestionModelID
        self.openAIAPIKey = openAIAPIKey
        self.sambaNovaAPIKey = sambaNovaAPIKey
        self.openAI = openAI
        self.sambaNova = sambaNova
        self.tscript = tscript
    }

    enum CodingKeys: String, CodingKey {
        case defaultProvider
        case nameSuggestionProvider
        case defaultInsightWorkflow
        case defaultInsightProvider
        case defaultInsightModelID
        case nameSuggestionModelID
        case openAIAPIKey
        case sambaNovaAPIKey
        case openAI
        case sambaNova
        case tscript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultProvider = try container.decodeIfPresent(String.self, forKey: .defaultProvider) ?? "openai"
        self.nameSuggestionProvider = try container.decodeIfPresent(String.self, forKey: .nameSuggestionProvider) ?? NameSuggestionProvider.buildDefault.rawValue
        self.defaultInsightWorkflow = try container.decodeIfPresent(String.self, forKey: .defaultInsightWorkflow) ?? InsightWorkflow.fallbackDefault.rawValue
        self.defaultInsightProvider = try container.decodeIfPresent(String.self, forKey: .defaultInsightProvider) ?? LLMProvider.openAI.rawValue
        self.defaultInsightModelID = try container.decodeIfPresent(String.self, forKey: .defaultInsightModelID) ?? LLMProvider.openAI.defaultModelID(for: .insights)
        self.nameSuggestionModelID = try container.decodeIfPresent(String.self, forKey: .nameSuggestionModelID) ?? LLMProvider.openAI.defaultModelID(for: .nameSuggestions)
        self.openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey)
        self.sambaNovaAPIKey = try container.decodeIfPresent(String.self, forKey: .sambaNovaAPIKey)
        self.openAI = try container.decodeIfPresent(LLMProviderConfiguration.self, forKey: .openAI)
            ?? LLMProviderConfiguration(baseURL: LLMProvider.openAI.defaultBaseURL)
        self.sambaNova = try container.decodeIfPresent(LLMProviderConfiguration.self, forKey: .sambaNova)
            ?? LLMProviderConfiguration(baseURL: LLMProvider.sambaNova.defaultBaseURL)
        self.tscript = try container.decodeIfPresent(TScriptConfiguration.self, forKey: .tscript) ?? TScriptConfiguration()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultProvider, forKey: .defaultProvider)
        try container.encode(nameSuggestionProvider, forKey: .nameSuggestionProvider)
        try container.encode(defaultInsightWorkflow, forKey: .defaultInsightWorkflow)
        try container.encode(defaultInsightProvider, forKey: .defaultInsightProvider)
        try container.encode(defaultInsightModelID, forKey: .defaultInsightModelID)
        try container.encode(nameSuggestionModelID, forKey: .nameSuggestionModelID)
        try container.encodeIfPresent(openAIAPIKey, forKey: .openAIAPIKey)
        try container.encodeIfPresent(sambaNovaAPIKey, forKey: .sambaNovaAPIKey)
        try container.encode(openAI, forKey: .openAI)
        try container.encode(sambaNova, forKey: .sambaNova)
        try container.encode(tscript, forKey: .tscript)
    }

    var normalizedInsightWorkflow: InsightWorkflow {
        InsightWorkflow(rawValue: defaultInsightWorkflow) ?? .fallbackDefault
    }

    var normalizedInsightProvider: LLMProvider {
        LLMProvider(rawValue: defaultInsightProvider.lowercased()) ?? .openAI
    }

    var normalizedNameSuggestionProvider: NameSuggestionProvider {
        NameSuggestionProvider(rawValue: nameSuggestionProvider.lowercased()) ?? NameSuggestionProvider.buildDefault
    }

    func providerConfiguration(for provider: LLMProvider) -> LLMProviderConfiguration {
        switch provider {
        case .openAI:
            return openAI
        case .sambaNova:
            return sambaNova
        }
    }

    mutating func setProviderConfiguration(_ configuration: LLMProviderConfiguration, for provider: LLMProvider) {
        switch provider {
        case .openAI:
            openAI = configuration
        case .sambaNova:
            sambaNova = configuration
        }
    }
}

final class AIConfigManager {
    enum ConfigurationError: LocalizedError {
        case missingAPIKey(LLMProvider)
        case invalidBaseURL(LLMProvider)

        var errorDescription: String? {
            switch self {
            case let .missingAPIKey(provider):
                return "\(provider.displayName) API key is missing."
            case let .invalidBaseURL(provider):
                return "\(provider.displayName) base URL is invalid."
            }
        }
    }

    static let shared = AIConfigManager()

    private let keychainService = "com.totalrec.ai"
    private let openAIKeychainAccount = "openai_api_key"
    private let sambaNovaKeychainAccount = "sambanova_api_key"

    private(set) var configuration: AIConfiguration

    private init() {
        if let loaded = try? Self.loadFromDisk() {
            self.configuration = loaded
        } else {
            self.configuration = AIConfiguration()
            do {
                try save()
            } catch {
                print("[AIConfigManager] Failed to save default configuration: \(error)")
            }
        }

        let supportedSuggestionProviders = Set(NameSuggestionProvider.allCases.map(\.rawValue))
        if configuration.nameSuggestionProvider.isEmpty || !supportedSuggestionProviders.contains(configuration.nameSuggestionProvider.lowercased()) {
            configuration.nameSuggestionProvider = NameSuggestionProvider.buildDefault.rawValue
        }

        if InsightWorkflow(rawValue: configuration.defaultInsightWorkflow) == nil {
            configuration.defaultInsightWorkflow = InsightWorkflow.fallbackDefault.rawValue
        }

        if LLMProvider(rawValue: configuration.defaultInsightProvider.lowercased()) == nil {
            configuration.defaultInsightProvider = LLMProvider.openAI.rawValue
        }

        normalizeProviderConfiguration(for: .openAI)
        normalizeProviderConfiguration(for: .sambaNova)
        normalizeModelSelections()

        migrateLegacyKeyIfNeeded(configuration.openAIAPIKey, for: .openAI)
        configuration.openAIAPIKey = nil
        migrateLegacyKeyIfNeeded(configuration.sambaNovaAPIKey, for: .sambaNova)
        configuration.sambaNovaAPIKey = nil

        try? save()
    }

    func openAIKey() -> String? {
        apiKey(for: .openAI)
    }

    func setOpenAIKey(_ key: String?) throws {
        try setAPIKey(key, for: .openAI)
    }

    func deleteOpenAIKey() throws {
        try deleteAPIKey(for: .openAI)
    }

    func updateOpenAIKey(_ key: String?) throws {
        try updateAPIKey(key, for: .openAI)
    }

    func sambaNovaKey() -> String? {
        apiKey(for: .sambaNova)
    }

    func updateSambaNovaKey(_ key: String?) throws {
        try updateAPIKey(key, for: .sambaNova)
    }

    func apiKey(for provider: LLMProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func updateAPIKey(_ key: String?, for provider: LLMProvider) throws {
        try setAPIKey(key, for: provider)
        try save()
    }

    func setDefaultProvider(_ provider: String) throws {
        configuration.defaultProvider = provider
        try save()
    }

    func setNameSuggestionProvider(_ provider: String) throws {
        configuration.nameSuggestionProvider = provider
        normalizeModelSelection(for: .nameSuggestions)
        try save()
    }

    func setDefaultInsightWorkflow(_ workflow: InsightWorkflow) throws {
        configuration.defaultInsightWorkflow = workflow.rawValue
        try save()
    }

    func setDefaultInsightProvider(_ provider: LLMProvider) throws {
        configuration.defaultInsightProvider = provider.rawValue
        normalizeModelSelection(for: .insights)
        try save()
    }

    func setDefaultInsightModelID(_ modelID: String) throws {
        configuration.defaultInsightModelID = modelID
        try save()
    }

    func setNameSuggestionModelID(_ modelID: String) throws {
        configuration.nameSuggestionModelID = modelID
        try save()
    }

    func setBaseURL(_ baseURL: String, for provider: LLMProvider) throws {
        var providerConfiguration = configuration.providerConfiguration(for: provider)
        providerConfiguration.baseURL = baseURL
        configuration.setProviderConfiguration(providerConfiguration, for: provider)
        try save()
    }

    func updateTScriptConfiguration(_ configuration: TScriptConfiguration) throws {
        self.configuration.tscript = configuration
        try save()
    }

    func updateCachedModels(_ models: [ProviderModelDescriptor], for provider: LLMProvider, updatedAt: Date = Date()) throws {
        var providerConfiguration = configuration.providerConfiguration(for: provider)
        providerConfiguration.cachedModels = models
        providerConfiguration.modelsUpdatedAt = updatedAt
        configuration.setProviderConfiguration(providerConfiguration, for: provider)
        normalizeModelSelections()
        try save()
    }

    func cachedModels(for provider: LLMProvider) -> [ProviderModelDescriptor] {
        configuration.providerConfiguration(for: provider).cachedModels
    }

    func cachedModelsUpdatedAt(for provider: LLMProvider) -> Date? {
        configuration.providerConfiguration(for: provider).modelsUpdatedAt
    }

    func baseURL(for provider: LLMProvider) -> String {
        let configured = configuration.providerConfiguration(for: provider).baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? provider.defaultBaseURL : configured
    }

    func resolvedProviderAccess(for provider: LLMProvider) throws -> (baseURL: URL, apiKey: String) {
        guard let apiKey = apiKey(for: provider), !apiKey.isEmpty else {
            throw ConfigurationError.missingAPIKey(provider)
        }

        let baseURLString = baseURL(for: provider)
        guard let baseURL = URL(string: baseURLString) else {
            throw ConfigurationError.invalidBaseURL(provider)
        }

        return (baseURL: baseURL, apiKey: apiKey)
    }

    func resolvedInsightConfiguration() throws -> LLMResolvedConfiguration {
        try resolvedConfiguration(
            provider: configuration.normalizedInsightProvider,
            feature: .insights
        )
    }

    func resolvedNameSuggestionConfiguration() throws -> LLMResolvedConfiguration {
        guard let provider = configuration.normalizedNameSuggestionProvider.llmProvider else {
            throw ConfigurationError.missingAPIKey(.openAI)
        }
        return try resolvedConfiguration(
            provider: provider,
            feature: .nameSuggestions
        )
    }

    func resolvedModelID(for feature: LLMFeature, provider overrideProvider: LLMProvider? = nil) -> String {
        let resolvedProvider = overrideProvider ?? provider(for: feature)
        let preferredID: String
        switch feature {
        case .insights:
            preferredID = configuration.defaultInsightModelID
        case .nameSuggestions:
            preferredID = configuration.nameSuggestionModelID
        }

        let trimmed = preferredID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if let firstCached = cachedModels(for: resolvedProvider).first(where: { $0.supports(feature: feature) }) {
            return firstCached.id
        }

        return resolvedProvider.defaultModelID(for: feature)
    }

    func provider(for feature: LLMFeature) -> LLMProvider {
        switch feature {
        case .insights:
            return configuration.normalizedInsightProvider
        case .nameSuggestions:
            return configuration.normalizedNameSuggestionProvider.llmProvider ?? .openAI
        }
    }

    func keychainSelfTest() -> Error? {
        let testAccount = "diagnostic"
        let testData = Data("ok".utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: testAccount
        ]
        _ = SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = testData
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain add failed"])
        }

        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        guard readStatus == errSecSuccess, let data = item as? Data, data == testData else {
            _ = SecItemDelete(baseQuery as CFDictionary)
            return NSError(domain: NSOSStatusErrorDomain, code: Int(readStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain read failed"])
        }

        let delStatus = SecItemDelete(baseQuery as CFDictionary)
        guard delStatus == errSecSuccess || delStatus == errSecItemNotFound else {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(delStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain delete failed"])
        }
        return nil
    }

    private func keychainAccount(for provider: LLMProvider) -> String {
        switch provider {
        case .openAI:
            return openAIKeychainAccount
        case .sambaNova:
            return sambaNovaKeychainAccount
        }
    }

    private func setAPIKey(_ key: String?, for provider: LLMProvider) throws {
        guard let key, !key.isEmpty else {
            try deleteAPIKey(for: provider)
            return
        }

        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(for: provider)
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
            return
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private func deleteAPIKey(for provider: LLMProvider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(for: provider)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func configDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "AIApp"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func configFileURL() throws -> URL {
        try configDirectoryURL().appendingPathComponent("AIConfiguration.json")
    }

    private static func loadFromDisk() throws -> AIConfiguration {
        let url = try configFileURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AIConfiguration.self, from: data)
    }

    private func save() throws {
        let url = try Self.configFileURL()
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: url, options: [.atomic])
        NotificationCenter.default.post(name: .totalRecAIConfigurationDidChange, object: nil)
    }

    private func normalizeProviderConfiguration(for provider: LLMProvider) {
        var providerConfiguration = configuration.providerConfiguration(for: provider)
        if providerConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerConfiguration.baseURL = provider.defaultBaseURL
        }
        providerConfiguration.cachedModels = providerConfiguration.cachedModels.filter { $0.provider == provider }
        configuration.setProviderConfiguration(providerConfiguration, for: provider)
    }

    private func normalizeModelSelections() {
        normalizeModelSelection(for: .insights)
        normalizeModelSelection(for: .nameSuggestions)
    }

    private func normalizeModelSelection(for feature: LLMFeature) {
        let provider = self.provider(for: feature)
        let available = cachedModels(for: provider).filter { $0.supports(feature: feature) }
        let fallback = available.first?.id ?? provider.defaultModelID(for: feature)

        switch feature {
        case .insights:
            let configured = configuration.defaultInsightModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if configured.isEmpty || (!available.isEmpty && !available.contains(where: { $0.id == configured })) {
                configuration.defaultInsightModelID = fallback
            }
        case .nameSuggestions:
            let configured = configuration.nameSuggestionModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if configured.isEmpty || (!available.isEmpty && !available.contains(where: { $0.id == configured })) {
                configuration.nameSuggestionModelID = fallback
            }
        }
    }

    private func migrateLegacyKeyIfNeeded(_ key: String?, for provider: LLMProvider) {
        guard let key, !key.isEmpty else { return }
        do {
            try setAPIKey(key, for: provider)
            print("[AIConfigManager] Migrated \(provider.displayName) key from JSON to Keychain.")
        } catch {
            print("[AIConfigManager] Failed to migrate \(provider.displayName) key to Keychain: \(error)")
        }
    }

    private func resolvedConfiguration(
        provider: LLMProvider,
        feature: LLMFeature
    ) throws -> LLMResolvedConfiguration {
        guard let apiKey = apiKey(for: provider), !apiKey.isEmpty else {
            throw ConfigurationError.missingAPIKey(provider)
        }

        let baseURLString = baseURL(for: provider)
        guard let baseURL = URL(string: baseURLString) else {
            throw ConfigurationError.invalidBaseURL(provider)
        }

        return LLMResolvedConfiguration(
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: resolvedModelID(for: feature, provider: provider)
        )
    }
}
