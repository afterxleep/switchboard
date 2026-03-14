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
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
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
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
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
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
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
        XCTAssertTrue(loggedMessages.contains(where: { $0.contains("forced") }))
    }

    func test_tick_continuesWhenGitHubPollerThrows() async throws {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedEvents = [
            .newIssue(id: "issue-1", identifier: "DB-200", title: "Survives GitHub failure", description: nil)
        ]
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedErrorSequence = [URLError(.notConnectedToInternet)]
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        var loggedMessages: [String] = []
        let config = DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "daniel-bernal",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 30,
            inFlightTimeoutSeconds: 120,
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
        )
        let loop = DaemonLoop(
            config: config,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            completionWatcher: completionWatcher,
            logger: { loggedMessages.append($0) }
        )

        // Act — tick must NOT throw
        try await loop.tick()

        // Assert
        XCTAssertEqual(linearPoller.pollCallCount, 1)
        XCTAssertEqual(
            dispatcher.receivedDispatchedEvents,
            [.newIssue(id: "issue-1", identifier: "DB-200", title: "Survives GitHub failure", description: nil)]
        )
        XCTAssertTrue(loggedMessages.contains(where: { $0.contains("github poll error") }))
    }

    func test_tick_continuesWhenLinearPollerThrows() async throws {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedErrorSequence = [MockLinearPolling.MockError.forced]
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedEvents = [.approved(pr: 99, branch: "feature/resilient")]
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        var loggedMessages: [String] = []
        let config = DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "daniel-bernal",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 30,
            inFlightTimeoutSeconds: 120,
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
        )
        let loop = DaemonLoop(
            config: config,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            completionWatcher: completionWatcher,
            logger: { loggedMessages.append($0) }
        )

        // Act — tick must NOT throw
        try await loop.tick()

        // Assert
        XCTAssertEqual(githubPoller.pollCallCount, 1)
        XCTAssertEqual(
            dispatcher.receivedDispatchedEvents,
            [.approved(pr: 99, branch: "feature/resilient")]
        )
        XCTAssertTrue(loggedMessages.contains(where: { $0.contains("linear poll error") }))
    }

    func test_run_continuesAfterTickError() async {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedErrorSequence = [MockLinearPolling.MockError.forced, nil]
        linearPoller.stubbedEvents = [
            .newIssue(id: "issue-1", identifier: "DB-201", title: "Second tick works", description: nil)
        ]
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedErrorSequence = [MockGitHubPolling.MockError.forced, nil]
        githubPoller.stubbedEvents = [.approved(pr: 50, branch: "feature/recovery")]
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
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
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

        // Assert — both ticks executed
        XCTAssertEqual(linearPoller.pollCallCount, 2)
        XCTAssertEqual(githubPoller.pollCallCount, 2)
        // First tick: both pollers threw, no events dispatched
        // Second tick: both pollers succeed, events dispatched
        XCTAssertEqual(dispatcher.receivedDispatchedEvents, [
            .newIssue(id: "issue-1", identifier: "DB-201", title: "Second tick works", description: nil),
            .approved(pr: 50, branch: "feature/recovery"),
        ])
    }

    func test_tick_whenAgentRunnerPresent_routesNewIssueToAgentRunner() async throws {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedEvents = [
            .newIssue(id: "issue-7", identifier: "DB-196", title: "Agent path", description: "Run codex")
        ]
        let githubPoller = MockGitHubPolling()
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: true, tokensUsed: 144, error: nil)
        let config = DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "daniel-bernal",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 30,
            inFlightTimeoutSeconds: 120,
            stateFilePath: stateStore.stateFilePath,
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
        )
        let loop = DaemonLoop(
            config: config,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            agentRunner: agentRunner,
            completionWatcher: completionWatcher,
            logger: { _ in }
        )

        // Act
        try await loop.tick()
        linearPoller.stubbedEvents = []
        try? await Task.sleep(nanoseconds: 50_000_000)
        try await loop.tick()

        // Assert
        XCTAssertTrue(dispatcher.receivedDispatchedEvents.isEmpty)
        XCTAssertEqual(
            agentRunner.receivedEvents,
            [.newIssue(id: "issue-7", identifier: "DB-196", title: "Agent path", description: "Run codex")]
        )
        let state = try stateStore.load()
        XCTAssertEqual(state["linear:DB-196"]?.status, .done)
    }

    private func makeStore() -> StateStore {
        let stateFileURL = temporaryDirectoryURL.appendingPathComponent("state.json")
        return StateStore(stateFilePath: stateFileURL.path)
    }
}
