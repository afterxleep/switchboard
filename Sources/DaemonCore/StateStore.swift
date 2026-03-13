import Foundation

public enum StateStoreError: Error, Equatable {
    case missingEntry(id: String)
}

public final class StateStore {
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
            entry.updatedAt = Date()
        }
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
