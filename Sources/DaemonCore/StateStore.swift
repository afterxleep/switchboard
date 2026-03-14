import Foundation

public enum StateStoreError: Error, Equatable {
    case missingEntry(id: String)
}

public final class StateStore: StateStoring {
    private let stateFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(stateFilePath: String = "~/.flowdeck-daemon/state.json") {
        self.stateFileURL = URL(fileURLWithPath: NSString(string: stateFilePath).expandingTildeInPath)
        self.fileManager = .default
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Tolerate both ISO8601 strings (current format) and legacy Unix epoch doubles
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                let iso = ISO8601DateFormatter()
                if let date = iso.date(from: str) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Cannot parse date string: \(str)"
                )
            }
            let epoch = try container.decode(Double.self)
            return Date(timeIntervalSince1970: epoch)
        }
    }

    public var stateFilePath: String {
        stateFileURL.path
    }

    public func load() throws -> [String: StateEntry] {
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: stateFileURL)
        return try decoder.decode([String: StateEntry].self, from: data)
    }

    public func save(_ state: [String: StateEntry]) throws {
        let directoryURL = stateFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: stateFileURL, options: .atomic)
    }

    public func upsert(_ entry: StateEntry) throws {
        var state = try load()
        state[entry.id] = entry
        try save(state)
    }

    public func markInFlight(id: String) throws {
        try updateEntry(id: id) { entry in
            entry.status = .inFlight
            entry.startedAt = Date()
            entry.updatedAt = Date()
        }
    }

    public func markDone(id: String) throws {
        try updateEntry(id: id) { entry in
            entry.status = .done
            entry.agentPhase = .done
            entry.updatedAt = Date()
        }
    }

    public func markPending(id: String) throws {
        try updateEntry(id: id) { entry in
            entry.status = .pending
            entry.startedAt = nil
            entry.updatedAt = Date()
            entry.agentPid = nil
            entry.tokensUsed = nil
        }
    }

    public func updateMetadata(
        id: String,
        sessionId: String?,
        agentPid: Int?,
        tokensUsed: Int?
    ) throws {
        try updateEntry(id: id) { entry in
            entry.sessionId = sessionId
            entry.agentPid = agentPid
            entry.tokensUsed = tokensUsed
            entry.updatedAt = Date()
        }
    }

    public func updateThread(
        id: String,
        sessionId: String?,
        threadPath: String?
    ) throws {
        try updateEntry(id: id) { entry in
            entry.sessionId = sessionId
            entry.threadPath = threadPath
            entry.updatedAt = Date()
        }
    }

    public func updateLinearIssueId(id: String, linearIssueId: String) throws {
        try updateEntry(id: id) { entry in
            entry.linearIssueId = linearIssueId
            entry.updatedAt = Date()
        }
    }

    public func entry(forPR prNumber: Int) -> StateEntry? {
        (try? load().values.first(where: { $0.prNumber == prNumber })) ?? nil
    }

    public func attachPR(id: String, prNumber: Int, threadPath: String?) throws {
        try updateEntry(id: id) { entry in
            entry.prNumber = prNumber
            if let threadPath {
                entry.threadPath = threadPath
            }
            entry.updatedAt = Date()
        }
    }

    public func updatePhase(id: String, phase: AgentPhase) throws {
        try updateEntry(id: id) { entry in
            entry.agentPhase = phase
            entry.updatedAt = Date()
        }
    }

    public func markTurnStarted(id: String) throws {
        try updateEntry(id: id) { entry in
            let now = Date()
            entry.lastTurnAt = now
            entry.startedAt = now
            entry.status = .inFlight
            entry.updatedAt = now
        }
    }

    public func incrementRetry(id: String) throws {
        try updateEntry(id: id) { entry in
            entry.retryCount += 1
            entry.updatedAt = Date()
        }
    }

    public func resetRetry(id: String) throws {
        try updateEntry(id: id) { entry in
            entry.retryCount = 0
            entry.updatedAt = Date()
        }
    }

    public func incrementConsecutiveCIFailures(id: String) throws -> Int {
        var nextCount = 0
        try updateEntry(id: id) { entry in
            entry.consecutiveCIFailures += 1
            nextCount = entry.consecutiveCIFailures
            entry.updatedAt = Date()
        }
        return nextCount
    }

    public func resetConsecutiveCIFailures(id: String) throws {
        try updateEntry(id: id) { entry in
            entry.consecutiveCIFailures = 0
            entry.updatedAt = Date()
        }
    }

    public func allActive() -> [StateEntry] {
        let state = (try? load()) ?? [:]
        return state.values.filter { $0.agentPhase != .done }
    }

    public func isInFlight(id: String) -> Bool {
        guard let entry = try? load()[id] else {
            return false
        }

        return entry.status == .inFlight
    }

    public func timedOut(id: String, after timeoutSeconds: TimeInterval) -> Bool {
        guard
            let entry = try? load()[id],
            let startedAt = entry.startedAt
        else {
            return false
        }

        return Date().timeIntervalSince(startedAt) > timeoutSeconds
    }

    public func cleanup() throws {
        let cutoffDate = Date().addingTimeInterval(-(24 * 60 * 60))
        var state = try load()
        state = state.filter { _, entry in
            !(entry.status == .done && entry.updatedAt < cutoffDate)
        }
        try save(state)
    }

    private func updateEntry(id: String, mutate: (inout StateEntry) -> Void) throws {
        var state = try load()
        guard var entry = state[id] else {
            throw StateStoreError.missingEntry(id: id)
        }

        mutate(&entry)
        state[id] = entry
        try save(state)
    }
}
