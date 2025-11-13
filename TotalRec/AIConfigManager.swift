import Foundation
import Security

struct AIConfiguration: Codable {
    var defaultProvider: String
    var openAIAPIKey: String?

    init(defaultProvider: String = "openai", openAIAPIKey: String? = nil) {
        self.defaultProvider = defaultProvider
        self.openAIAPIKey = openAIAPIKey
    }
}

final class AIConfigManager {
    static let shared = AIConfigManager()
    
    private let keychainService = "com.totalrec.ai"
    private let keychainAccount = "openai_api_key"

    private(set) var configuration: AIConfiguration

    private init() {
        // Attempt to load existing config; otherwise, create a default one and persist it.
        if let loaded = try? Self.loadFromDisk() {
            self.configuration = loaded
        } else {
            self.configuration = AIConfiguration()
            do {
                try save()
            } catch {
                // Non-fatal: log but continue with in-memory defaults
                print("[AIConfigManager] Failed to save default configuration: \(error)")
            }
        }
        
        // Migrate any previously stored key from JSON to Keychain
        if let legacyKey = self.configuration.openAIAPIKey, !legacyKey.isEmpty {
            do {
                try setOpenAIKey(legacyKey)
                self.configuration.openAIAPIKey = nil
                try save()
                print("[AIConfigManager] Migrated OpenAI key from JSON to Keychain.")
            } catch {
                print("[AIConfigManager] Failed to migrate key to Keychain: \(error)")
            }
        }
    }

    // MARK: - Public API

    // MARK: - Keychain
    func openAIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setOpenAIKey(_ key: String?) throws {
        // Delete if nil or empty
        guard let key, !key.isEmpty else {
            try deleteOpenAIKey()
            return
        }
        let data = Data(key.utf8)
        // Try update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
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

    func deleteOpenAIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func updateOpenAIKey(_ key: String?) throws {
        configuration.openAIAPIKey = nil
        try setOpenAIKey(key)
        try save()
    }

    func setDefaultProvider(_ provider: String) throws {
        configuration.defaultProvider = provider
        try save()
    }

    // MARK: - Diagnostics
    /// Performs a simple add/read/delete cycle in Keychain to verify access.
    /// - Returns: `nil` if Keychain is usable, otherwise an Error describing the failure.
    func keychainSelfTest() -> Error? {
        let testAccount = "diagnostic"
        let testData = Data("ok".utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: testAccount
        ]
        // Clean up any existing diagnostic item (ignore not found)
        _ = SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = testData
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain add failed ("])
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

    // MARK: - Persistence

    private static func configDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Optionally namespace by bundle identifier if available
        let bundleID = Bundle.main.bundleIdentifier ?? "AIApp"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func configFileURL() throws -> URL {
        return try configDirectoryURL().appendingPathComponent("AIConfiguration.json")
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
    }
}
