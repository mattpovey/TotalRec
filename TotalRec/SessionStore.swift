import Foundation

struct SessionStore {
    private struct CurrentSessionPointer: Codable {
        var sessionID: UUID
    }

    private let fileManager = FileManager.default

    func loadLatestSession() throws -> RecordingSession? {
        let pointerURL = try currentSessionPointerURL()
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            return nil
        }

        let pointerData = try Data(contentsOf: pointerURL)
        let pointer = try JSONDecoder().decode(CurrentSessionPointer.self, from: pointerData)
        let manifestURL = try sessionManifestURL(for: pointer.sessionID)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifestData = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(RecordingSession.self, from: manifestData)
    }

    func loadSession(id: UUID) throws -> RecordingSession? {
        let manifestURL = try sessionManifestURL(for: id)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifestData = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(RecordingSession.self, from: manifestData)
    }

    func listRecentSessions(limit: Int = 12) throws -> [RecordingSession] {
        let sessionsURL = try sessionsDirectoryURL()
        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return []
        }

        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let sessions = try sessionDirectories.compactMap { directoryURL -> RecordingSession? in
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }

            let manifestURL = directoryURL.appendingPathComponent("Session.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

            let manifestData = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(RecordingSession.self, from: manifestData)
        }

        return sessions
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    func listRecentSessionSummaries(limit: Int = 12) throws -> [RecordingSessionSummary] {
        let sessionsURL = try sessionsDirectoryURL()
        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return []
        }

        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let summaries = try sessionDirectories.compactMap { directoryURL -> RecordingSessionSummary? in
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }

            let summaryURL = directoryURL.appendingPathComponent("SessionSummary.json")
            if fileManager.fileExists(atPath: summaryURL.path) {
                let summaryData = try Data(contentsOf: summaryURL)
                return try JSONDecoder().decode(RecordingSessionSummary.self, from: summaryData)
            }

            let manifestURL = directoryURL.appendingPathComponent("Session.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

            let manifestData = try Data(contentsOf: manifestURL)
            let session = try JSONDecoder().decode(RecordingSession.self, from: manifestData)
            return session.summary
        }

        return summaries
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    func createSession(sourceDescription: String) throws -> RecordingSession {
        let session = RecordingSession(sourceDescription: sourceDescription)
        try ensureDirectoryExists(at: sessionDirectoryURL(for: session))
        try save(session)
        return session
    }

    func save(_ session: RecordingSession) throws {
        try ensureDirectoryExists(at: sessionsDirectoryURL())
        try ensureDirectoryExists(at: sessionDirectoryURL(for: session))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sessionData = try encoder.encode(session)
        try sessionData.write(to: sessionManifestURL(for: session.id), options: [.atomic])

        let summaryData = try encoder.encode(session.summary)
        try summaryData.write(to: sessionSummaryURL(for: session.id), options: [.atomic])

        let pointerData = try encoder.encode(CurrentSessionPointer(sessionID: session.id))
        try pointerData.write(to: currentSessionPointerURL(), options: [.atomic])
    }

    func setCurrentSession(_ sessionID: UUID) throws {
        let pointerData = try JSONEncoder().encode(CurrentSessionPointer(sessionID: sessionID))
        try pointerData.write(to: currentSessionPointerURL(), options: [.atomic])
    }

    func clearCurrentSession() throws {
        let pointerURL = try currentSessionPointerURL()
        guard fileManager.fileExists(atPath: pointerURL.path) else { return }
        try fileManager.removeItem(at: pointerURL)
    }

    func deleteSession(_ sessionID: UUID) throws {
        let sessionDirectory = try sessionsDirectoryURL().appendingPathComponent(sessionID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: sessionDirectory.path) {
            try fileManager.removeItem(at: sessionDirectory)
        }

        let pointerURL = try currentSessionPointerURL()
        guard fileManager.fileExists(atPath: pointerURL.path) else { return }

        let pointerData = try Data(contentsOf: pointerURL)
        let pointer = try JSONDecoder().decode(CurrentSessionPointer.self, from: pointerData)
        if pointer.sessionID == sessionID {
            try clearCurrentSession()
        }
    }

    func fileURL(for filename: String?, in session: RecordingSession) -> URL? {
        guard let filename else { return nil }
        return sessionDirectoryURL(for: session).appendingPathComponent(filename)
    }

    func captureMovieURL(for session: RecordingSession) throws -> URL {
        sessionDirectoryURL(for: session).appendingPathComponent("capture.mov")
    }

    func mixedAudioURL(for session: RecordingSession) throws -> URL {
        sessionDirectoryURL(for: session).appendingPathComponent("audio.m4a")
    }

    func importedAudioURL(for session: RecordingSession, ext: String) throws -> URL {
        sessionDirectoryURL(for: session)
            .appendingPathComponent("imported-audio")
            .appendingPathExtension(ext)
    }

    private func applicationSupportDirectoryURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "sosayweall.TotalRec"
        let appDirectory = base.appendingPathComponent(bundleID, isDirectory: true)
        try ensureDirectoryExists(at: appDirectory)
        return appDirectory
    }

    private func sessionsDirectoryURL() throws -> URL {
        let sessionsDirectory = try applicationSupportDirectoryURL().appendingPathComponent("Sessions", isDirectory: true)
        try ensureDirectoryExists(at: sessionsDirectory)
        return sessionsDirectory
    }

    private func currentSessionPointerURL() throws -> URL {
        try applicationSupportDirectoryURL().appendingPathComponent("CurrentSession.json")
    }

    func sessionDirectoryURL(for session: RecordingSession) -> URL {
        try! sessionsDirectoryURL().appendingPathComponent(session.sessionDirectoryName, isDirectory: true)
    }

    private func sessionManifestURL(for sessionID: UUID) throws -> URL {
        try sessionsDirectoryURL()
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("Session.json")
    }

    private func sessionSummaryURL(for sessionID: UUID) throws -> URL {
        try sessionsDirectoryURL()
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("SessionSummary.json")
    }

    private func ensureDirectoryExists(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
