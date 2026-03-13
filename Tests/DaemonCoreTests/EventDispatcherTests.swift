import XCTest
@testable import DaemonCore

final class EventDispatcherTests: XCTestCase {
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

    func test_dispatch_whenPending_runsOpenClawAndMarksInFlight() throws {
        // Arrange
        let store = makeStore()
        let argumentsFileURL = temporaryDirectoryURL.appendingPathComponent("openclaw-args.txt")
        let commandURL = try makeOpenClawScript(outputFileURL: argumentsFileURL)
        let dispatcher = EventDispatcher(stateStore: store, openClawCommand: commandURL.path)
        let event = DaemonEvent.newIssue(
            id: "issue-1",
            identifier: "DB-192",
            title: "Implement daemon loop",
            description: nil
        )

        // Act
        try dispatcher.dispatch(event)

        // Assert
        let argumentsText = try String(contentsOf: argumentsFileURL, encoding: .utf8)
        XCTAssertEqual(
            argumentsText.trimmingCharacters(in: .newlines),
            """
            system
            event
            --text
            [DB-192] new_issue: DB-192: Implement daemon loop
            --mode
            now
            """
        )
        let storedEntry = try XCTUnwrap(try store.load()[event.eventId])
        XCTAssertEqual(storedEntry.status, .inFlight)
        XCTAssertEqual(storedEntry.eventType, "new_issue")
        XCTAssertEqual(storedEntry.details, "DB-192: Implement daemon loop")
    }

    func test_dispatch_whenAlreadyInFlight_skipsOpenClaw() throws {
        // Arrange
        let store = makeStore()
        let argumentsFileURL = temporaryDirectoryURL.appendingPathComponent("openclaw-args.txt")
        let commandURL = try makeOpenClawScript(outputFileURL: argumentsFileURL)
        let dispatcher = EventDispatcher(stateStore: store, openClawCommand: commandURL.path)
        let event = DaemonEvent.newIssue(
            id: "issue-1",
            identifier: "DB-192",
            title: "Implement daemon loop",
            description: nil
        )
        try store.save([
            event.eventId: StateEntry(
                id: event.eventId,
                status: .inFlight,
                eventType: "new_issue",
                details: event.details,
                startedAt: Date(),
                updatedAt: Date()
            )
        ])

        // Act
        try dispatcher.dispatch(event)

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: argumentsFileURL.path))
    }

    func test_retryTimedOut_whenEntryTimedOut_redispatchesEvent() throws {
        // Arrange
        let store = makeStore()
        let argumentsFileURL = temporaryDirectoryURL.appendingPathComponent("openclaw-args.txt")
        let commandURL = try makeOpenClawScript(outputFileURL: argumentsFileURL)
        let dispatcher = EventDispatcher(stateStore: store, openClawCommand: commandURL.path)
        let event = DaemonEvent.approved(pr: 42, branch: "feature/db-192")
        try store.save([
            event.eventId: StateEntry(
                id: event.eventId,
                status: .inFlight,
                eventType: event.eventType,
                details: event.details,
                startedAt: Date().addingTimeInterval(-120),
                updatedAt: Date().addingTimeInterval(-120)
            )
        ])

        // Act
        try dispatcher.retryTimedOut(timeoutSeconds: 60)

        // Assert
        let argumentsText = try String(contentsOf: argumentsFileURL, encoding: .utf8)
        XCTAssertTrue(argumentsText.contains("[PR #42] approved: PR #42 on feature/db-192 was approved"))
        let storedEntry = try XCTUnwrap(try store.load()[event.eventId])
        XCTAssertEqual(storedEntry.status, .inFlight)
    }

    func test_markDone_clearsState() throws {
        // Arrange
        let store = makeStore()
        let dispatcher = EventDispatcher(stateStore: store)
        let eventId = "linear:DB-192"
        try store.save([
            eventId: StateEntry(
                id: eventId,
                status: .inFlight,
                eventType: "new_issue",
                details: "DB-192: Implement daemon loop",
                startedAt: Date(),
                updatedAt: Date()
            )
        ])

        // Act
        try dispatcher.markDone(id: eventId)

        // Assert
        let storedEntry = try XCTUnwrap(try store.load()[eventId])
        XCTAssertEqual(storedEntry.status, .done)
    }

    private func makeStore() -> StateStore {
        let stateFileURL = temporaryDirectoryURL.appendingPathComponent("state.json")
        return StateStore(stateFilePath: stateFileURL.path)
    }

    private func makeOpenClawScript(outputFileURL: URL) throws -> URL {
        let scriptURL = temporaryDirectoryURL.appendingPathComponent("mock-openclaw.sh")
        let script = """
        #!/bin/zsh
        printf '%s\n' "$@" > "\(outputFileURL.path)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }
}
