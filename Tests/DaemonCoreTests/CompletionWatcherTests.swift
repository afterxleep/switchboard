import XCTest
@testable import DaemonCore

final class CompletionWatcherTests: XCTestCase {
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

    func test_checkAndProcess_whenDoneFilesExist_marksDoneAndDeletesFiles() throws {
        // Arrange
        let doneDirectoryURL = temporaryDirectoryURL.appendingPathComponent("done", isDirectory: true)
        let stateFileURL = temporaryDirectoryURL.appendingPathComponent("state.json")
        let stateStore = StateStore(stateFilePath: stateFileURL.path)
        let dispatcher = EventDispatcher(stateStore: stateStore)
        let watcher = CompletionWatcher(doneDir: doneDirectoryURL.path)
        let eventId = "gh:pr:42:approved"
        try stateStore.save([
            eventId: StateEntry(
                id: eventId,
                status: .inFlight,
                eventType: "approved",
                details: "PR #42 on feature/db-192 was approved",
                startedAt: Date(),
                updatedAt: Date()
            )
        ])
        try CompletionWatcher.signalDone(id: eventId, doneDir: doneDirectoryURL.path)

        // Act
        try watcher.checkAndProcess(dispatcher: dispatcher)

        // Assert
        let storedEntry = try XCTUnwrap(try stateStore.load()[eventId])
        XCTAssertEqual(storedEntry.status, .done)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            atPath: doneDirectoryURL.path
        )
        XCTAssertTrue(remainingFiles.isEmpty)
    }
}
