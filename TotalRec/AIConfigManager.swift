import Foundation

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
    }

    // MARK: - Public API

    func updateOpenAIKey(_ key: String?) throws {
        configuration.openAIAPIKey = key
        try save()
    }

    func setDefaultProvider(_ provider: String) throws {
        configuration.defaultProvider = provider
        try save()
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
