import Dispatch
import Foundation
import SQLite3
import XCTest
@testable import DaemonCore

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStateStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        super.tearDown()
    }

    func test_sqliteStateStore_initCreatesDatabaseAndTable() throws {
        // Arrange
        let dbURL = makeDatabaseURL()

        // Act
        _ = try SQLiteStateStore(dbPath: dbURL.path)

        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertTrue(try tableExists(named: "state_entries", in: dbURL))
    }

    func test_sqliteStateStore_upsertAndLoad_roundTripsEntries() throws {
        // Arrange
        let store = try makeStore()
        let entry = makeEntry(
            id: "linear:DB-200",
            status: .inFlight,
            agentPhase: .waitingOnReview,
            consecutiveCIFailures: 2
        )

        // Act
        try store.upsert(entry)
        let loadedEntry = try XCTUnwrap(try store.load()[entry.id])

        // Assert
        XCTAssertEqual(loadedEntry, entry)
    }

    func test_sqliteStateStore_updatePhase_persistsTextAndReloadsEnum() throws {
        // Arrange
        let dbURL = makeDatabaseURL()
        let store = try SQLiteStateStore(dbPath: dbURL.path)
        let entry = makeEntry(id: "linear:DB-201")
        try store.upsert(entry)

        // Act
        try store.updatePhase(id: entry.id, phase: .ciBlocked)
        let loadedEntry = try XCTUnwrap(try store.load()[entry.id])
        let storedPhase = try stringColumn(
            "agent_phase",
            forID: entry.id,
            in: dbURL
        )

        // Assert
        XCTAssertEqual(storedPhase, AgentPhase.ciBlocked.rawValue)
        XCTAssertEqual(loadedEntry.agentPhase, .ciBlocked)
    }

    func test_sqliteStateStore_unknownAgentPhaseValue_gracefullyDegradesToCoding() throws {
        // Arrange
        let dbURL = makeDatabaseURL()
        let store = try SQLiteStateStore(dbPath: dbURL.path)
        try insertRawRow(
            id: "linear:DB-202",
            agentPhase: "unknownFutureCase",
            dbURL: dbURL
        )

        // Act
        let loadedEntry = try XCTUnwrap(try store.load()["linear:DB-202"])

        // Assert
        XCTAssertEqual(loadedEntry.agentPhase, .coding)
    }

    func test_sqliteStateStore_attachPR_persistsPRFields() throws {
        // Arrange
        let store = try makeStore()
        let entry = makeEntry(id: "linear:DB-203")
        try store.upsert(entry)

        // Act
        try store.attachPR(
            id: entry.id,
            prNumber: 321,
            title: "Add SQLite store",
            threadPath: "/tmp/thread.jsonl"
        )
        let loadedEntry = try XCTUnwrap(try store.load()[entry.id])

        // Assert
        XCTAssertEqual(loadedEntry.prNumber, 321)
        XCTAssertEqual(loadedEntry.prTitle, "Add SQLite store")
        XCTAssertEqual(loadedEntry.threadPath, "/tmp/thread.jsonl")
    }

    func test_sqliteStateStore_markDone_setsDoneStatus() throws {
        // Arrange
        let store = try makeStore()
        let entry = makeEntry(id: "linear:DB-204", status: .inFlight, agentPhase: .coding)
        try store.upsert(entry)

        // Act
        try store.markDone(id: entry.id)
        let loadedEntry = try XCTUnwrap(try store.load()[entry.id])

        // Assert
        XCTAssertEqual(loadedEntry.status, .done)
    }

    func test_sqliteStateStore_initMigratesExistingStateJSON() throws {
        // Arrange
        let stateFileURL = temporaryDirectoryURL.appendingPathComponent("state.json")
        let jsonStore = StateStore(stateFilePath: stateFileURL.path)
        let migratedEntry = makeEntry(
            id: "linear:DB-205",
            agentPhase: .ciBlocked,
            consecutiveCIFailures: 7
        )
        let secondEntry = makeEntry(
            id: "linear:DB-206",
            status: .done,
            agentPhase: .done
        )
        try jsonStore.save([
            migratedEntry.id: migratedEntry,
            secondEntry.id: secondEntry,
        ])
        let dbURL = temporaryDirectoryURL.appendingPathComponent("state.db")

        // Act
        let store = try SQLiteStateStore(dbPath: dbURL.path)
        let loadedState = try store.load()

        // Assert
        XCTAssertEqual(loadedState[migratedEntry.id], migratedEntry)
        XCTAssertEqual(loadedState[secondEntry.id], secondEntry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryDirectoryURL
                    .appendingPathComponent("state.json.migrated")
                    .path
            )
        )
    }

    func test_sqliteStateStore_upsert_isThreadSafeAcrossConcurrentWrites() throws {
        // Arrange
        let store = try makeStore()
        let queue = DispatchQueue(label: "sqlite-state-store-tests", attributes: .concurrent)
        let group = DispatchGroup()
        let ids = (0..<50).map { "linear:DB-\($0)" }
        var thrownError: Error?
        let errorLock = NSLock()

        // Act
        for id in ids {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try store.upsert(self.makeEntry(id: id))
                } catch {
                    errorLock.lock()
                    if thrownError == nil {
                        thrownError = error
                    }
                    errorLock.unlock()
                }
            }
        }
        group.wait()
        if let thrownError {
            throw thrownError
        }
        let loadedState = try store.load()

        // Assert
        XCTAssertEqual(loadedState.count, 50)
        XCTAssertEqual(Set(loadedState.keys), Set(ids))
    }

    func test_sqliteStateStore_updatePhase_onMissingID_isNoOp() throws {
        // Arrange
        let store = try makeStore()

        // Act
        try store.updatePhase(id: "linear:missing", phase: .ciBlocked)
        let loadedState = try store.load()

        // Assert
        XCTAssertTrue(loadedState.isEmpty)
    }

    func test_sqliteStateStore_upsert_persistsConsecutiveCIFailures() throws {
        // Arrange
        let store = try makeStore()
        let entry = makeEntry(
            id: "linear:DB-207",
            consecutiveCIFailures: 42
        )

        // Act
        try store.upsert(entry)
        let loadedEntry = try XCTUnwrap(try store.load()[entry.id])

        // Assert
        XCTAssertEqual(loadedEntry.consecutiveCIFailures, 42)
    }

    private func makeStore() throws -> SQLiteStateStore {
        try SQLiteStateStore(dbPath: makeDatabaseURL().path)
    }

    private func makeDatabaseURL() -> URL {
        temporaryDirectoryURL.appendingPathComponent("state.db")
    }

    private func makeEntry(
        id: String,
        status: ItemStatus = .pending,
        agentPhase: AgentPhase = .coding,
        consecutiveCIFailures: Int = 0
    ) -> StateEntry {
        StateEntry(
            id: id,
            status: status,
            eventType: "new_issue",
            details: "Details for \(id)",
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            sessionId: "session-\(id)",
            agentPid: 1234,
            tokensUsed: 5678,
            prNumber: 99,
            prTitle: "PR for \(id)",
            threadPath: "/tmp/\(id).jsonl",
            linearIssueId: "issue-\(id)",
            agentPhase: agentPhase,
            lastTurnAt: Date(timeIntervalSince1970: 1_700_000_300),
            retryCount: 3,
            consecutiveCIFailures: consecutiveCIFailures,
            pendingThreadNodeIds: ["node-1", "node-2"]
        )
    }

    private func tableExists(named tableName: String, in dbURL: URL) throws -> Bool {
        let database = try openDatabase(at: dbURL)
        defer { sqlite3_close(database) }

        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, tableName, -1, sqliteTransient)

        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func stringColumn(
        _ column: String,
        forID id: String,
        in dbURL: URL
    ) throws -> String? {
        let database = try openDatabase(at: dbURL)
        defer { sqlite3_close(database) }

        let sql = "SELECT \(column) FROM state_entries WHERE id = ?;"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard let text = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: text)
    }

    private func insertRawRow(
        id: String,
        agentPhase: String,
        dbURL: URL
    ) throws {
        let database = try openDatabase(at: dbURL)
        defer { sqlite3_close(database) }

        let sql = """
        INSERT INTO state_entries (
            id, status, event_type, details, started_at, updated_at, session_id,
            agent_pid, tokens_used, pr_number, pr_title, thread_path, linear_issue_id,
            agent_phase, last_turn_at, retry_count, consecutive_ci_failures,
            pending_thread_node_ids
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        bind(text: id, at: 1, to: statement)
        bind(text: ItemStatus.pending.rawValue, at: 2, to: statement)
        bind(text: "new_issue", at: 3, to: statement)
        bind(text: "Details", at: 4, to: statement)
        sqlite3_bind_double(statement, 5, 1_700_000_100)
        sqlite3_bind_double(statement, 6, 1_700_000_200)
        bind(text: "session-raw", at: 7, to: statement)
        sqlite3_bind_int(statement, 8, 4321)
        sqlite3_bind_int(statement, 9, 8765)
        sqlite3_bind_int(statement, 10, 0)
        bind(text: "Raw PR", at: 11, to: statement)
        bind(text: "/tmp/raw.jsonl", at: 12, to: statement)
        bind(text: "issue-raw", at: 13, to: statement)
        bind(text: agentPhase, at: 14, to: statement)
        sqlite3_bind_double(statement, 15, 1_700_000_300)
        sqlite3_bind_int(statement, 16, 0)
        sqlite3_bind_int(statement, 17, 0)
        bind(text: "[\"node-raw\"]", at: 18, to: statement)

        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func openDatabase(at dbURL: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        let result = sqlite3_open(dbURL.path, &database)
        guard result == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_close(database)
            throw NSError(domain: "SQLiteStateStoreTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        return database
    }

    private func bind(text: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    }
}
