import XCTest
@testable import DaemonCore

final class DaemonLoopTests: XCTestCase {
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

    func test_tick_runsPollersDispatchesEventsProcessesDoneAndCleansUp() async throws {
        // Arrange
        let stateStore = makeStore()
        let completionWatcher = MockCompletionWatching()
        completionWatcher.stubbedAction = { dispatcher in
            try dispatcher.markDone(id: "linear:DB-191")
        }
        try stateStore.save([
            "issue-1": StateEntry(
                id: "issue-1",
                status: .pending,
                eventType: "new_issue",
                details: "known linear issue",
                startedAt: nil,
                updatedAt: Date()
            ),
            "linear:DB-191": StateEntry(
                id: "linear:DB-191",
                status: .inFlight,
                eventType: "new_issue",
                details: "complete me",
                startedAt: Date(),
                updatedAt: Date()
            ),
            "linear:stale": StateEntry(
                id: "linear:stale",
                status: .done,
                eventType: "new_issue",
                details: "stale",
                startedAt: nil,
                updatedAt: Date().addingTimeInterval(-(25 * 60 * 60))
            )
        ])
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedEvents = [
            .newIssue(
                id: "issue-2",
                identifier: "DB-192",
                title: "Implement loop",
                description: nil
            )
        ]
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedEvents = [
            .approved(pr: 42, branch: "feature/db-192")
        ]
        let dispatcher = MockEventDispatching()
        let config = DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "daniel-bernal",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 30,
            inFlightTimeoutSeconds: 120,
            stateFilePath: stateStore.stateFilePath
        )
        var loop: DaemonLoop!
        loop = DaemonLoop(
            config: config,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            completionWatcher: completionWatcher
        )

        // Act
        try await loop.tick()

        // Assert
        XCTAssertEqual(linearPoller.receivedStates.count, 1)
        XCTAssertTrue(linearPoller.receivedStates[0].keys.contains("linear:DB-191"))
        XCTAssertTrue(linearPoller.receivedStates[0].keys.contains("linear:stale"))
        XCTAssertEqual(githubPoller.receivedStates.count, 1)
        XCTAssertEqual(
            dispatcher.receivedDispatchedEvents,
            [
                .newIssue(
                    id: "issue-2",
                    identifier: "DB-192",
                    title: "Implement loop",
                    description: nil
                ),
                .approved(pr: 42, branch: "feature/db-192"),
            ]
        )
        XCTAssertEqual(dispatcher.receivedRetryTimeouts, [120])
        XCTAssertEqual(completionWatcher.checkCallCount, 1)
        let state = try stateStore.load()
        XCTAssertNil(state["linear:stale"])
    }

    func test_run_whenStopped_haltsLoop() async {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        let githubPoller = MockGitHubPolling()
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        let config = DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "daniel-bernal",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 0.01,
            inFlightTimeoutSeconds: 120,
            stateFilePath: stateStore.stateFilePath
        )
        var loop: DaemonLoop!
        loop = DaemonLoop(
            config: config,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            completionWatcher: completionWatcher,
            logger: { _ in },
            sleep: { _ in }
        )

        // Act
        let task = Task {
            await loop.run()
        }
        loop.stop()
        await task.value

        // Assert
        XCTAssertEqual(linearPoller.pollCallCount, 0)
    }

    func test_run_whenTickThrows_logsErrorAndContinues() async {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedErrorSequence = [
            MockLinearPolling.MockError.forced,
            nil,
        ]
        let githubPoller = MockGitHubPolling()
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        var loggedMessages: [String] = []
        let config = DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "daniel-bernal",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 0,
            inFlightTimeoutSeconds: 120,
            stateFilePath: stateStore.stateFilePath
        )
        var loop: DaemonLoop!
        loop = DaemonLoop(
            config: config,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            completionWatcher: completionWatcher,
            logger: { loggedMessages.append($0) },
            sleep: { _ in
                if linearPoller.pollCallCount >= 2 {
                    loop.stop()
                }
            }
        )

        // Act
        await loop.run()

        // Assert
        XCTAssertEqual(linearPoller.pollCallCount, 2)
        XCTAssertEqual(loggedMessages.count, 1)
        XCTAssertTrue(loggedMessages[0].contains("forced"))
    }

    private func makeStore() -> StateStore {
        let stateFileURL = temporaryDirectoryURL.appendingPathComponent("state.json")
        return StateStore(stateFilePath: stateFileURL.path)
    }
}
