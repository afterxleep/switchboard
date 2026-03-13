import XCTest
@testable import DaemonCore

final class StateStoreTests: XCTestCase {
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

    func test_loadAndSave_roundTripsEntries() throws {
        // Arrange
        let store = makeStore()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let state = [
            "linear:DB-190": StateEntry(
                id: "linear:DB-190",
                status: .pending,
                eventType: "new_issue",
                details: "DB-190",
                startedAt: nil,
                updatedAt: updatedAt
            )
        ]

        // Act
        try store.save(state)
        let loadedState = try store.load()

        // Assert
        XCTAssertEqual(loadedState, state)
    }

    func test_markInFlight_setsStatusAndStartedAt() throws {
        // Arrange
        let store = makeStore()
        let existingEntry = StateEntry(
            id: "linear:DB-190",
            status: .pending,
            eventType: "new_issue",
            details: "DB-190",
            startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save([existingEntry.id: existingEntry])

        // Act
        try store.markInFlight(id: existingEntry.id)
        let markedEntry = try XCTUnwrap(try store.load()[existingEntry.id])

        // Assert
        XCTAssertEqual(markedEntry.status, .inFlight)
        XCTAssertNotNil(markedEntry.startedAt)
        XCTAssertGreaterThanOrEqual(markedEntry.updatedAt, existingEntry.updatedAt)
    }

    func test_markDone_setsStatusAndPreservesStartedAt() throws {
        // Arrange
        let store = makeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let entry = StateEntry(
            id: "linear:DB-190",
            status: .inFlight,
            eventType: "new_issue",
            details: "DB-190",
            startedAt: startedAt,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try store.save([entry.id: entry])

        // Act
        try store.markDone(id: entry.id)
        let markedEntry = try XCTUnwrap(try store.load()[entry.id])

        // Assert
        XCTAssertEqual(markedEntry.status, .done)
        XCTAssertEqual(markedEntry.startedAt, startedAt)
    }

    func test_timedOut_returnsTrueOnlyWhenStartedAtExceedsTimeout() throws {
        // Arrange
        let store = makeStore()
        let timedOutEntry = StateEntry(
            id: "linear:DB-190",
            status: .inFlight,
            eventType: "new_issue",
            details: "DB-190",
            startedAt: Date().addingTimeInterval(-120),
            updatedAt: Date()
        )
        let freshEntry = StateEntry(
            id: "linear:DB-191",
            status: .inFlight,
            eventType: "new_issue",
            details: "DB-191",
            startedAt: Date().addingTimeInterval(-10),
            updatedAt: Date()
        )
        try store.save([
            timedOutEntry.id: timedOutEntry,
            freshEntry.id: freshEntry,
        ])

        // Act
        let timedOut = store.timedOut(id: timedOutEntry.id, after: 60)
        let fresh = store.timedOut(id: freshEntry.id, after: 60)
        let missing = store.timedOut(id: "linear:missing", after: 60)

        // Assert
        XCTAssertTrue(timedOut)
        XCTAssertFalse(fresh)
        XCTAssertFalse(missing)
    }

    func test_cleanup_removesOnlyDoneEntriesOlderThan24Hours() throws {
        // Arrange
        let store = makeStore()
        // Truncate to second precision so ISO8601 roundtrip is lossless
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let staleDone = StateEntry(
            id: "linear:stale",
            status: .done,
            eventType: "new_issue",
            details: "stale",
            startedAt: nil,
            updatedAt: now.addingTimeInterval(-(24 * 60 * 60 + 1))
        )
        let freshDone = StateEntry(
            id: "linear:fresh",
            status: .done,
            eventType: "new_issue",
            details: "fresh",
            startedAt: nil,
            updatedAt: now.addingTimeInterval(-60)
        )
        let pending = StateEntry(
            id: "linear:pending",
            status: .pending,
            eventType: "new_issue",
            details: "pending",
            startedAt: nil,
            updatedAt: now.addingTimeInterval(-(48 * 60 * 60))
        )
        try store.save([
            staleDone.id: staleDone,
            freshDone.id: freshDone,
            pending.id: pending,
        ])

        // Act
        try store.cleanup()
        let loadedState = try store.load()

        // Assert
        XCTAssertNil(loadedState[staleDone.id])
        XCTAssertEqual(loadedState[freshDone.id], freshDone)
        XCTAssertEqual(loadedState[pending.id], pending)
    }

    private func makeStore() -> StateStore {
        let stateFileURL = temporaryDirectoryURL.appendingPathComponent("state.json")
        return StateStore(stateFilePath: stateFileURL.path)
    }
}
