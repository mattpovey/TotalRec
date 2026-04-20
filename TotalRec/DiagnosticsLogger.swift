import Foundation

enum DiagnosticsLogger {
    private static let queue = DispatchQueue(label: "sosayweall.totalrec.diagnostics")
    private static let subsystem = "TotalRec"
    private static let maxMetadataValueLength = 8_000

    static var logFileURL: URL? {
        try? logsDirectoryURL().appendingPathComponent("InsightsDiagnostics.log")
    }

    static func log(category: String, message: String, metadata: [String: String] = [:]) {
        let entry = formatEntry(level: "INFO", category: category, message: message, metadata: metadata)
        print(entry)
        append(entry)
    }

    static func logError(category: String, message: String, error: Error, metadata: [String: String] = [:]) {
        let nsError = error as NSError
        var merged = metadata
        merged["errorDomain"] = nsError.domain
        merged["errorCode"] = "\(nsError.code)"
        merged["errorDescription"] = error.localizedDescription
        let entry = formatEntry(level: "ERROR", category: category, message: message, metadata: merged)
        print(entry)
        append(entry)
    }

    static func preview(_ value: String, limit: Int = 1_500) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "…"
    }

    private static func append(_ entry: String) {
        queue.async {
            guard let fileURL = logFileURL else { return }

            do {
                try ensureLogFileExists(at: fileURL)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = (entry + "\n").data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                print("[\(subsystem)][Diagnostics] Failed to append log entry: \(error.localizedDescription)")
            }
        }
    }

    private static func ensureLogFileExists(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.atomic])
        }
    }

    private static func logsDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "sosayweall.TotalRec"
        let directory = base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func formatEntry(level: String, category: String, message: String, metadata: [String: String]) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadataBlock = metadata
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(preview(value, limit: maxMetadataValueLength))"
            }
            .joined(separator: " | ")

        if metadataBlock.isEmpty {
            return "[\(subsystem)][\(timestamp)][\(level)][\(category)] \(message)"
        }

        return "[\(subsystem)][\(timestamp)][\(level)][\(category)] \(message) | \(metadataBlock)"
    }
}
