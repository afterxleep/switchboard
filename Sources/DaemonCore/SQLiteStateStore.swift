import Foundation
import SQLite3

public final class SQLiteStateStore: StateStoring {
    private let dbPath: String
    private let database: OpaquePointer
    private let lock = NSLock()

    public init(dbPath: String) throws {
        self.dbPath = NSString(string: dbPath).expandingTildeInPath
        self.database = try SQLiteStateStore.openDatabase(at: self.dbPath)
        try withDatabase { database in
            try Self.execute(sql: Self.createTableSQL, database: database)
        }
        try migrateLegacyStateIfNeeded()
    }

    deinit {
        sqlite3_close(database)
    }

    public var stateFilePath: String {
        dbPath
    }

    public func load() throws -> [String: StateEntry] {
        try withDatabase { database in
            let sql = """
            SELECT
                id, status, event_type, details, started_at, updated_at, session_id,
                agent_pid, tokens_used, pr_number, pr_title, thread_path, linear_issue_id,
                agent_phase, last_turn_at, retry_count, consecutive_ci_failures,
                pending_thread_node_ids
            FROM state_entries;
            """
            let statement = try Self.prepare(sql: sql, database: database)
            defer { sqlite3_finalize(statement) }

            var entries: [String: StateEntry] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let entry = try Self.readEntry(from: statement)
                entries[entry.id] = entry
            }
            return entries
        }
    }

    public func save(_ state: [String: StateEntry]) throws {
        try withDatabase { database in
            try Self.execute(sql: "BEGIN IMMEDIATE TRANSACTION;", database: database)
            do {
                try Self.execute(sql: "DELETE FROM state_entries;", database: database)
                for entry in state.values {
                    try Self.upsert(entry, database: database)
                }
                try Self.execute(sql: "COMMIT;", database: database)
            } catch {
                try? Self.execute(sql: "ROLLBACK;", database: database)
                throw error
            }
        }
    }

    public func upsert(_ entry: StateEntry) throws {
        try withDatabase { database in
            try Self.upsert(entry, database: database)
        }
    }

    public func markInFlight(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET status = ?, started_at = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(text: ItemStatus.inFlight.rawValue, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                Self.bind(text: id, at: 4, to: statement)
            }
        )
    }

    public func markDone(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET status = ?, agent_phase = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(text: ItemStatus.done.rawValue, at: 1, to: statement)
                Self.bind(text: AgentPhase.done.rawValue, at: 2, to: statement)
                sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                Self.bind(text: id, at: 4, to: statement)
            }
        )
    }

    public func markPending(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET status = ?, started_at = NULL, updated_at = ?, agent_pid = NULL, tokens_used = NULL
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(text: ItemStatus.pending.rawValue, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                Self.bind(text: id, at: 3, to: statement)
            }
        )
    }

    public func updateMetadata(
        id: String,
        sessionId: String?,
        agentPid: Int?,
        tokensUsed: Int?
    ) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET session_id = ?, agent_pid = ?, tokens_used = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(optionalText: sessionId, at: 1, to: statement)
                Self.bind(optionalInt: agentPid, at: 2, to: statement)
                Self.bind(optionalInt: tokensUsed, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
                Self.bind(text: id, at: 5, to: statement)
            }
        )
    }

    public func updateThread(
        id: String,
        sessionId: String?,
        threadPath: String?
    ) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET session_id = ?, thread_path = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(optionalText: sessionId, at: 1, to: statement)
                Self.bind(optionalText: threadPath, at: 2, to: statement)
                sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                Self.bind(text: id, at: 4, to: statement)
            }
        )
    }

    public func updateLinearIssueId(id: String, linearIssueId: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET linear_issue_id = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(text: linearIssueId, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                Self.bind(text: id, at: 3, to: statement)
            }
        )
    }

    public func entry(forPR prNumber: Int) -> StateEntry? {
        try? withDatabase { database in
            let sql = """
            SELECT
                id, status, event_type, details, started_at, updated_at, session_id,
                agent_pid, tokens_used, pr_number, pr_title, thread_path, linear_issue_id,
                agent_phase, last_turn_at, retry_count, consecutive_ci_failures,
                pending_thread_node_ids
            FROM state_entries
            WHERE pr_number = ?
            LIMIT 1;
            """
            let statement = try Self.prepare(sql: sql, database: database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(prNumber))

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try Self.readEntry(from: statement)
        } ?? nil
    }

    public func attachPR(id: String, prNumber: Int, title: String?, threadPath: String?) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET pr_number = ?, pr_title = COALESCE(?, pr_title), thread_path = COALESCE(?, thread_path), updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                sqlite3_bind_int(statement, 1, Int32(prNumber))
                Self.bind(optionalText: title, at: 2, to: statement)
                Self.bind(optionalText: threadPath, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
                Self.bind(text: id, at: 5, to: statement)
            }
        )
    }

    public func clearPR(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET pr_number = NULL, pr_title = NULL, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                Self.bind(text: id, at: 2, to: statement)
            }
        )
    }

    public func updatePhase(id: String, phase: AgentPhase) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET agent_phase = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                Self.bind(text: phase.rawValue, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                Self.bind(text: id, at: 3, to: statement)
            }
        )
    }

    public func markTurnStarted(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET last_turn_at = ?, started_at = ?, status = ?, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                let timestamp = now.timeIntervalSince1970
                sqlite3_bind_double(statement, 1, timestamp)
                sqlite3_bind_double(statement, 2, timestamp)
                Self.bind(text: ItemStatus.inFlight.rawValue, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, timestamp)
                Self.bind(text: id, at: 5, to: statement)
            }
        )
    }

    public func incrementRetry(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET retry_count = retry_count + 1, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                Self.bind(text: id, at: 2, to: statement)
            }
        )
    }

    public func resetRetry(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET retry_count = 0, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                Self.bind(text: id, at: 2, to: statement)
            }
        )
    }

    public func incrementConsecutiveCIFailures(id: String) throws -> Int {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET consecutive_ci_failures = consecutive_ci_failures + 1, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                Self.bind(text: id, at: 2, to: statement)
            }
        )

        return try withDatabase { database in
            let statement = try Self.prepare(
                sql: "SELECT consecutive_ci_failures FROM state_entries WHERE id = ? LIMIT 1;",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            Self.bind(text: id, at: 1, to: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    public func resetConsecutiveCIFailures(id: String) throws {
        let now = Date()
        try update(
            sql: """
            UPDATE state_entries
            SET consecutive_ci_failures = 0, updated_at = ?
            WHERE id = ?;
            """,
            bindings: { statement in
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                Self.bind(text: id, at: 2, to: statement)
            }
        )
    }

    public func allActive() -> [StateEntry] {
        (try? withDatabase { database in
            let sql = """
            SELECT
                id, status, event_type, details, started_at, updated_at, session_id,
                agent_pid, tokens_used, pr_number, pr_title, thread_path, linear_issue_id,
                agent_phase, last_turn_at, retry_count, consecutive_ci_failures,
                pending_thread_node_ids
            FROM state_entries
            WHERE agent_phase != ?;
            """
            let statement = try Self.prepare(sql: sql, database: database)
            defer { sqlite3_finalize(statement) }
            Self.bind(text: AgentPhase.done.rawValue, at: 1, to: statement)

            var entries: [StateEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                entries.append(try Self.readEntry(from: statement))
            }
            return entries
        }) ?? []
    }

    public func isInFlight(id: String) -> Bool {
        (try? withDatabase { database in
            let statement = try Self.prepare(
                sql: "SELECT status FROM state_entries WHERE id = ? LIMIT 1;",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            Self.bind(text: id, at: 1, to: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return false
            }
            return Self.readText(column: 0, from: statement) == ItemStatus.inFlight.rawValue
        }) ?? false
    }

    public func timedOut(id: String, after timeoutSeconds: TimeInterval) -> Bool {
        guard let entry = try? withDatabase({ database -> StateEntry? in
            let sql = """
            SELECT
                id, status, event_type, details, started_at, updated_at, session_id,
                agent_pid, tokens_used, pr_number, pr_title, thread_path, linear_issue_id,
                agent_phase, last_turn_at, retry_count, consecutive_ci_failures,
                pending_thread_node_ids
            FROM state_entries
            WHERE id = ?
            LIMIT 1;
            """
            let statement = try Self.prepare(sql: sql, database: database)
            defer { sqlite3_finalize(statement) }
            Self.bind(text: id, at: 1, to: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try Self.readEntry(from: statement)
        }) else {
            return false
        }

        return entry.timedOut(after: timeoutSeconds)
    }

    public func cleanup() throws {
        let cutoff = Date().addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970
        try update(
            sql: "DELETE FROM state_entries WHERE status = ? AND updated_at < ?;",
            bindings: { statement in
                Self.bind(text: ItemStatus.done.rawValue, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, cutoff)
            }
        )
    }

    private func migrateLegacyStateIfNeeded() throws {
        let stateJSONURL = URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent()
            .appendingPathComponent("state.json")
        let migratedURL = stateJSONURL.appendingPathExtension("migrated")
        guard FileManager.default.fileExists(atPath: stateJSONURL.path) else {
            return
        }

        let legacyStore = StateStore(stateFilePath: stateJSONURL.path)
        let legacyEntries = try legacyStore.load()
        for entry in legacyEntries.values {
            try upsert(entry)
        }

        if FileManager.default.fileExists(atPath: migratedURL.path) {
            try FileManager.default.removeItem(at: migratedURL)
        }
        try FileManager.default.moveItem(at: stateJSONURL, to: migratedURL)
        fputs("Migrated \(legacyEntries.count) entries from state.json to SQLite\n", stderr)
    }

    private func update(sql: String, bindings: (OpaquePointer?) -> Void) throws {
        try withDatabase { database in
            let statement = try Self.prepare(sql: sql, database: database)
            defer { sqlite3_finalize(statement) }
            bindings(statement)
            try Self.stepDone(statement, database: database)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(database)
    }

    private static func upsert(_ entry: StateEntry, database: OpaquePointer) throws {
        let sql = """
        INSERT INTO state_entries (
            id, status, event_type, details, started_at, updated_at, session_id,
            agent_pid, tokens_used, pr_number, pr_title, thread_path, linear_issue_id,
            agent_phase, last_turn_at, retry_count, consecutive_ci_failures,
            pending_thread_node_ids
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            status = excluded.status,
            event_type = excluded.event_type,
            details = excluded.details,
            started_at = excluded.started_at,
            updated_at = excluded.updated_at,
            session_id = excluded.session_id,
            agent_pid = excluded.agent_pid,
            tokens_used = excluded.tokens_used,
            pr_number = excluded.pr_number,
            pr_title = excluded.pr_title,
            thread_path = excluded.thread_path,
            linear_issue_id = excluded.linear_issue_id,
            agent_phase = excluded.agent_phase,
            last_turn_at = excluded.last_turn_at,
            retry_count = excluded.retry_count,
            consecutive_ci_failures = excluded.consecutive_ci_failures,
            pending_thread_node_ids = excluded.pending_thread_node_ids;
        """
        let statement = try prepare(sql: sql, database: database)
        defer { sqlite3_finalize(statement) }

        bind(text: entry.id, at: 1, to: statement)
        bind(text: entry.status.rawValue, at: 2, to: statement)
        bind(text: entry.eventType, at: 3, to: statement)
        bind(text: entry.details, at: 4, to: statement)
        bind(optionalDate: entry.startedAt, at: 5, to: statement)
        sqlite3_bind_double(statement, 6, entry.updatedAt.timeIntervalSince1970)
        bind(optionalText: entry.sessionId, at: 7, to: statement)
        bind(optionalInt: entry.agentPid, at: 8, to: statement)
        bind(optionalInt: entry.tokensUsed, at: 9, to: statement)
        bind(optionalInt: entry.prNumber, at: 10, to: statement)
        bind(optionalText: entry.prTitle, at: 11, to: statement)
        bind(optionalText: entry.threadPath, at: 12, to: statement)
        bind(optionalText: entry.linearIssueId, at: 13, to: statement)
        bind(text: entry.agentPhase.rawValue, at: 14, to: statement)
        bind(optionalDate: entry.lastTurnAt, at: 15, to: statement)
        sqlite3_bind_int(statement, 16, Int32(entry.retryCount))
        sqlite3_bind_int(statement, 17, Int32(entry.consecutiveCIFailures))
        bind(text: try encodePendingThreadNodeIDs(entry.pendingThreadNodeIds), at: 18, to: statement)

        try stepDone(statement, database: database)
    }

    private static func readEntry(from statement: OpaquePointer?) throws -> StateEntry {
        StateEntry(
            id: readText(column: 0, from: statement),
            status: ItemStatus(rawValue: readText(column: 1, from: statement)) ?? .pending,
            eventType: readText(column: 2, from: statement),
            details: readText(column: 3, from: statement),
            startedAt: readDate(column: 4, from: statement),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            sessionId: readOptionalText(column: 6, from: statement),
            agentPid: readOptionalInt(column: 7, from: statement),
            tokensUsed: readOptionalInt(column: 8, from: statement),
            prNumber: readOptionalInt(column: 9, from: statement),
            prTitle: readOptionalText(column: 10, from: statement),
            threadPath: readOptionalText(column: 11, from: statement),
            linearIssueId: readOptionalText(column: 12, from: statement),
            agentPhase: AgentPhase(rawValue: readText(column: 13, from: statement)) ?? .coding,
            lastTurnAt: readDate(column: 14, from: statement),
            retryCount: Int(sqlite3_column_int(statement, 15)),
            consecutiveCIFailures: Int(sqlite3_column_int(statement, 16)),
            pendingThreadNodeIds: try decodePendingThreadNodeIDs(readText(column: 17, from: statement))
        )
    }

    private static func openDatabase(at path: String) throws -> OpaquePointer {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var database: OpaquePointer?
        let result = sqlite3_open(path, &database)
        guard result == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unable to open SQLite database"
            sqlite3_close(database)
            throw SQLiteStateStoreError.databaseOpenFailed(path: path, message: message)
        }
        return database
    }

    private static func execute(sql: String, database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteStateStoreError.sqliteFailure(message: lastErrorMessage(database))
        }
    }

    private static func prepare(sql: String, database: OpaquePointer) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw SQLiteStateStoreError.sqliteFailure(message: lastErrorMessage(database))
        }
        return statement
    }

    private static func stepDone(_ statement: OpaquePointer?, database: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteStateStoreError.sqliteFailure(message: lastErrorMessage(database))
        }
    }

    private static func bind(text: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    }

    private static func bind(optionalText: String?, at index: Int32, to statement: OpaquePointer?) {
        guard let optionalText else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(text: optionalText, at: index, to: statement)
    }

    private static func bind(optionalInt: Int?, at index: Int32, to statement: OpaquePointer?) {
        guard let optionalInt else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(optionalInt))
    }

    private static func bind(optionalDate: Date?, at index: Int32, to statement: OpaquePointer?) {
        guard let optionalDate else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, optionalDate.timeIntervalSince1970)
    }

    private static func readText(column: Int32, from statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: value)
    }

    private static func readOptionalText(column: Int32, from statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return readText(column: column, from: statement)
    }

    private static func readOptionalInt(column: Int32, from statement: OpaquePointer?) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, column))
    }

    private static func readDate(column: Int32, from statement: OpaquePointer?) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func encodePendingThreadNodeIDs(_ ids: [String]) throws -> String {
        let data = try JSONEncoder().encode(ids)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SQLiteStateStoreError.invalidPendingThreadNodeIDs
        }
        return text
    }

    private static func decodePendingThreadNodeIDs(_ text: String) throws -> [String] {
        let data = Data(text.utf8)
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func lastErrorMessage(_ database: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }

    private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS state_entries (
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'pending',
        event_type TEXT NOT NULL DEFAULT '',
        details TEXT NOT NULL DEFAULT '',
        started_at REAL,
        updated_at REAL NOT NULL,
        session_id TEXT,
        agent_pid INTEGER,
        tokens_used INTEGER,
        pr_number INTEGER,
        pr_title TEXT,
        thread_path TEXT,
        linear_issue_id TEXT,
        agent_phase TEXT NOT NULL DEFAULT 'coding',
        last_turn_at REAL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        consecutive_ci_failures INTEGER NOT NULL DEFAULT 0,
        pending_thread_node_ids TEXT NOT NULL DEFAULT '[]'
    );
    """
}

public enum SQLiteStateStoreError: LocalizedError, Equatable {
    case databaseOpenFailed(path: String, message: String)
    case sqliteFailure(message: String)
    case invalidPendingThreadNodeIDs

    public var errorDescription: String? {
        switch self {
        case let .databaseOpenFailed(path, message):
            return "Failed to open SQLite database at \(path): \(message)"
        case let .sqliteFailure(message):
            return "SQLite operation failed: \(message)"
        case .invalidPendingThreadNodeIDs:
            return "Failed to encode pending thread node IDs as JSON"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
