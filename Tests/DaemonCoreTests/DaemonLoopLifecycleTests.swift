import XCTest
@testable import DaemonCore

final class DaemonLoopLifecycleTests: XCTestCase {
    func test_happyPath_newIssueToMerged_marksDone() async throws {
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedEvents = [.newIssue(id: "issue-200", identifier: "DB-200", title: "Add X", description: nil)]
        let githubPoller = MockGitHubPolling()
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: true, tokensUsed: 10, error: nil, threadId: "thread-1", threadPath: "/tmp/thread-1.jsonl")
        let linearManager = MockLinearStateManager()
        let workspaceManager = MockWorkspaceManager()
        let loop = makeLoop(stateStore: stateStore, linearPoller: linearPoller, githubPoller: githubPoller, dispatcher: dispatcher, completionWatcher: completionWatcher, agentRunner: agentRunner, linearManager: linearManager, workspaceManager: workspaceManager)

        try await loop.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        linearPoller.stubbedEvents = []
        try await loop.tick()
        try await loop.routeForTesting(.prOpened(pr: 145, branch: "kai/db-200-add-x", title: "Add X"))
        githubPoller.stubbedHasUnresolvedThreads = false
        try await loop.routeForTesting(.ciPassed(pr: 145, branch: "kai/db-200-add-x"))
        try await loop.routeForTesting(.prMerged(pr: 145, branch: "kai/db-200-add-x"))

        let entry = try XCTUnwrap(try stateStore.load()["linear:DB-200"])
        XCTAssertEqual(entry.sessionId, "thread-1")
        XCTAssertEqual(entry.prNumber, 145)
        XCTAssertEqual(entry.agentPhase, .done)
        XCTAssertEqual(linearManager.inProgressIssueIds, ["issue-200"])
        XCTAssertEqual(linearManager.inReviewIssueIds, ["issue-200"])
        XCTAssertEqual(linearManager.doneIssueIds, ["issue-200"])
        XCTAssertEqual(workspaceManager.receivedCleanupIds, [["linear:DB-200"]])
    }

    func test_reviewComment_triggersResumeAndPhaseChange() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let loop = makeLoop(stateStore: stateStore, githubPoller: MockGitHubPolling(), agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager())

        try await loop.routeForTesting(.reviewComment(pr: 145, body: "Change X to Y", author: "afterxleep"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let entry = try XCTUnwrap(try stateStore.load()["linear:DB-200"])
        XCTAssertEqual(entry.agentPhase, .addressingFeedback)
        XCTAssertEqual(entry.status, .inFlight)
    }

    func test_ciFailure_triggersResumeAfterThreshold() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let githubPoller = MockGitHubPolling()
        let agentRunner = MockAgentRunner()
        let loop = makeLoop(stateStore: stateStore, githubPoller: githubPoller, agentRunner: agentRunner, linearManager: MockLinearStateManager())

        try await loop.routeForTesting(.ciFailure(pr: 145, branch: "kai/db-200-add-x", failedChecks: ["swift test"]))
        XCTAssertEqual(agentRunner.receivedEvents.count, 0)

        try await loop.routeForTesting(.ciFailure(pr: 145, branch: "kai/db-200-add-x", failedChecks: ["swift test"]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(agentRunner.receivedEvents.count, 1)
    }

    func test_conflict_triggersResume() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let agentRunner = MockAgentRunner()
        let loop = makeLoop(stateStore: stateStore, githubPoller: MockGitHubPolling(), agentRunner: agentRunner, linearManager: MockLinearStateManager())

        try await loop.routeForTesting(.conflict(pr: 145, branch: "kai/db-200-add-x"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(agentRunner.receivedEvents, [.conflict(pr: 145, branch: "kai/db-200-add-x")])
    }

    func test_ciPassed_withUnresolvedThreads_doesNotMoveToWaitingOnReview() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnCI)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedHasUnresolvedThreads = true
        let linearManager = MockLinearStateManager()
        let loop = makeLoop(stateStore: stateStore, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: linearManager)

        try await loop.routeForTesting(.ciPassed(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.agentPhase, .waitingOnCI)
        XCTAssertEqual(linearManager.inReviewIssueIds, [])
    }

    func test_agentFailure_incrementsRetryAndDispatchesAtMaxRetries() async throws {
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedEvents = [.newIssue(id: "issue-200", identifier: "DB-200", title: "Add X", description: nil)]
        let githubPoller = MockGitHubPolling()
        let dispatcher = MockEventDispatching()
        let completionWatcher = MockCompletionWatching()
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: false, tokensUsed: 0, error: "boom", threadId: nil, threadPath: nil)
        let loop = makeLoop(stateStore: stateStore, linearPoller: linearPoller, githubPoller: githubPoller, dispatcher: dispatcher, completionWatcher: completionWatcher, agentRunner: agentRunner, linearManager: MockLinearStateManager(), maxAgentRetries: 1)

        try await loop.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await loop.tick()

        XCTAssertFalse(dispatcher.receivedDispatchedEvents.isEmpty)
    }

    func test_runningAgent_blocksDuplicateEvents() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let agentRunner = MockAgentRunner()
        let loop = makeLoop(stateStore: stateStore, githubPoller: MockGitHubPolling(), agentRunner: agentRunner, linearManager: MockLinearStateManager())

        try await loop.routeForTesting(.reviewComment(pr: 145, body: "One", author: "afterxleep"))
        try await loop.routeForTesting(.reviewComment(pr: 145, body: "Two", author: "afterxleep"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(agentRunner.receivedEvents.count, 1)
    }

    func test_issueCancelled_cleansUpWorkspace() async throws {
        let stateStore = makeStore()
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-200",
                status: .inFlight,
                eventType: "new_issue",
                details: "DB-200: Add X",
                startedAt: Date(),
                updatedAt: Date(),
                linearIssueId: "issue-200"
            )
        )
        let workspaceManager = MockWorkspaceManager()
        let loop = makeLoop(stateStore: stateStore, githubPoller: MockGitHubPolling(), agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager(), workspaceManager: workspaceManager)

        try await loop.routeForTesting(.issueCancelled(id: "issue-200", identifier: "DB-200"))

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.status, .done)
        XCTAssertEqual(workspaceManager.receivedCleanupIds, [["linear:DB-200"]])
    }

    private func makeLoop(
        stateStore: StateStore,
        linearPoller: MockLinearPolling = MockLinearPolling(),
        githubPoller: MockGitHubPolling,
        dispatcher: MockEventDispatching = MockEventDispatching(),
        completionWatcher: MockCompletionWatching = MockCompletionWatching(),
        agentRunner: MockAgentRunner,
        linearManager: MockLinearStateManager,
        workspaceManager: MockWorkspaceManager = MockWorkspaceManager(),
        maxAgentRetries: Int = 3
    ) -> DaemonLoop {
        DaemonLoop(
            config: DaemonConfig(
                linearApiKey: "linear-token",
                linearTeamSlug: "DB",
                githubToken: "github-token",
                githubRepo: "afterxleep/flowdeck",
                pollIntervalSeconds: 30,
                inFlightTimeoutSeconds: 120,
                stateFilePath: stateStore.stateFilePath,
                codexCommand: "/opt/homebrew/bin/codex",
                workspaceRoot: "~/.flowdeck-daemon/workspaces",
                repoPath: "~/Developer/flowdeck",
                workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md",
                maxAgentRetries: maxAgentRetries
            ),
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            agentRunner: agentRunner,
            linearStateManager: linearManager,
            workspaceManager: workspaceManager,
            completionWatcher: completionWatcher,
            logger: { _ in },
            sleep: { _ in }
        )
    }

    private func makeStore() -> StateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        return StateStore(stateFilePath: url.path)
    }

    private func seedTrackedEntry(store: StateStore, phase: AgentPhase = .waitingOnReview) throws {
        try store.upsert(
            StateEntry(
                id: "linear:DB-200",
                status: .pending,
                eventType: "new_issue",
                details: "DB-200: Add X",
                startedAt: nil,
                updatedAt: Date(),
                sessionId: "thread-1",
                prNumber: 145,
                threadPath: "/tmp/thread-1.jsonl",
                linearIssueId: "issue-200",
                agentPhase: phase
            )
        )
    }
}
