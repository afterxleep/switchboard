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
        let loop = makeLoop(
            stateStore: stateStore,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            completionWatcher: completionWatcher,
            agentRunner: agentRunner,
            linearManager: linearManager,
            workspaceManager: workspaceManager
        )

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
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager()
        )

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
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager()
        )

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
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager()
        )

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
        let prMerger = MockPRMerger()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: MockAgentRunner(),
            linearManager: linearManager,
            prMerger: prMerger
        )

        try await loop.routeForTesting(.ciPassed(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.agentPhase, .waitingOnCI)
        XCTAssertEqual(linearManager.inReviewIssueIds, [])
        XCTAssertEqual(prMerger.receivedMergeRequests.count, 0)
    }

    func test_prOpened_whenReviewerConfigured_requestsReview() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .coding, prNumber: nil, prTitle: nil)
        let reviewRequester = MockPRReviewRequester()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prReviewRequester: reviewRequester,
            githubReviewer: "kai"
        )

        try await loop.routeForTesting(.prOpened(pr: 145, branch: "kai/db-200-add-x", title: "Add X"))

        XCTAssertEqual(reviewRequester.receivedRequests.count, 1)
        XCTAssertEqual(reviewRequester.receivedRequests.first?.pr, 145)
        XCTAssertEqual(reviewRequester.receivedRequests.first?.reviewer, "kai")
        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.agentPhase, .waitingOnCI)
    }

    func test_prOpened_whenReviewerMissing_doesNotRequestReview() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .coding, prNumber: nil, prTitle: nil)
        let reviewRequester = MockPRReviewRequester()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prReviewRequester: reviewRequester
        )

        try await loop.routeForTesting(.prOpened(pr: 145, branch: "kai/db-200-add-x", title: "Add X"))

        XCTAssertTrue(reviewRequester.receivedRequests.isEmpty)
    }

    func test_approved_whenAllConditionsPass_triggersMerge() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: true,
            noOpenThreads: true,
            noConflicts: true
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prMerger: prMerger
        )

        try await loop.routeForTesting(.approved(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertEqual(prMerger.receivedMergeabilityPRNumbers, [145])
        XCTAssertEqual(prMerger.receivedMergeRequests.count, 1)
        XCTAssertEqual(prMerger.receivedMergeRequests.first?.pr, 145)
        XCTAssertEqual(prMerger.receivedMergeRequests.first?.commitMessage, "DB-200: Add X")
    }

    func test_approved_whenCIIsFailing_doesNotMerge() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: false,
            noOpenThreads: true,
            noConflicts: true
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prMerger: prMerger
        )

        try await loop.routeForTesting(.approved(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertTrue(prMerger.receivedMergeRequests.isEmpty)
    }

    func test_approved_whenOpenThreadsRemain_doesNotMerge() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: true,
            noOpenThreads: false,
            noConflicts: true
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prMerger: prMerger
        )

        try await loop.routeForTesting(.approved(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertTrue(prMerger.receivedMergeRequests.isEmpty)
    }

    func test_approved_whenConflictsExist_doesNotMerge() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: true,
            noOpenThreads: true,
            noConflicts: false
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prMerger: prMerger
        )

        try await loop.routeForTesting(.approved(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertTrue(prMerger.receivedMergeRequests.isEmpty)
    }

    func test_ciPassed_whenAlreadyApprovedAndReady_triggersMergeAttempt() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnCI)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedHasUnresolvedThreads = false
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: true,
            noOpenThreads: true,
            noConflicts: true
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prMerger: prMerger
        )

        try await loop.routeForTesting(.ciPassed(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertEqual(prMerger.receivedMergeabilityPRNumbers, [145])
        XCTAssertEqual(prMerger.receivedMergeRequests.count, 1)
    }

    func test_processCompletedAgents_whenFeedbackTurnCompletesAndPRIsReady_triggersMergeAttempt() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnReview)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = true
        githubPoller.stubbedHasUnresolvedThreads = false
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: true, tokensUsed: 5, error: nil, threadId: "thread-2", threadPath: "/tmp/thread-2.jsonl")
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: true,
            noOpenThreads: true,
            noConflicts: true
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager(),
            prMerger: prMerger
        )

        try await loop.routeForTesting(.reviewComment(pr: 145, body: "Please update this", author: "afterxleep"))
        try await Task.sleep(nanoseconds: 100_000_000)
        try await loop.tick()

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.agentPhase, .waitingOnReview)
        XCTAssertEqual(prMerger.receivedMergeabilityPRNumbers, [145])
        XCTAssertEqual(prMerger.receivedMergeRequests.count, 1)
    }

    func test_mergeFailure_isLoggedAndNotFatal() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let prMerger = MockPRMerger()
        prMerger.stubbedMergeability = PRMergeability(
            approved: true,
            ciGreen: true,
            noOpenThreads: true,
            noConflicts: true
        )
        prMerger.stubbedMergeError = MockPRMerger.MockError.forced
        let logs = LogSink()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prMerger: prMerger,
            logger: logs.log(message:)
        )

        try await loop.routeForTesting(.approved(pr: 145, branch: "kai/db-200-add-x"))

        XCTAssertEqual(prMerger.receivedMergeRequests.count, 1)
        XCTAssertTrue(logs.messages.contains(where: { $0.contains("merge readiness check failed for PR #145") }))
    }

    func test_reviewRequestFailure_isLoggedAndNotFatal() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .coding, prNumber: nil, prTitle: nil)
        let reviewRequester = MockPRReviewRequester()
        reviewRequester.stubbedError = MockPRReviewRequester.MockError.forced
        let logs = LogSink()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            prReviewRequester: reviewRequester,
            githubReviewer: "kai",
            logger: logs.log(message:)
        )

        try await loop.routeForTesting(.prOpened(pr: 145, branch: "kai/db-200-add-x", title: "Add X"))

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.prNumber, 145)
        XCTAssertTrue(logs.messages.contains(where: { $0.contains("failed to request reviewer for PR #145") }))
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
        let loop = makeLoop(
            stateStore: stateStore,
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            completionWatcher: completionWatcher,
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager(),
            maxAgentRetries: 1
        )

        try await loop.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await loop.tick()

        XCTAssertFalse(dispatcher.receivedDispatchedEvents.isEmpty)
    }

    func test_runningAgent_blocksDuplicateEvents() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore)
        let agentRunner = MockAgentRunner()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager()
        )

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
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager(),
            workspaceManager: workspaceManager
        )

        try await loop.routeForTesting(.issueCancelled(id: "issue-200", identifier: "DB-200"))

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.status, .done)
        XCTAssertEqual(workspaceManager.receivedCleanupIds, [["linear:DB-200"]])
    }

    func test_reconcile_whenWaitingOnReviewHasUnresolvedThreads_movesIssueBackToInProgress() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnReview)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedHasUnresolvedThreads = true
        let linearManager = MockLinearStateManager()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: MockAgentRunner(),
            linearManager: linearManager
        )

        try await loop.reconcile()

        XCTAssertEqual(try stateStore.load()["linear:DB-200"]?.agentPhase, .addressingFeedback)
        XCTAssertEqual(linearManager.inProgressIssueIds, ["issue-200"])
        XCTAssertEqual(githubPoller.receivedUnresolvedThreadPRNumbers, [145])
    }

    func test_routeForTesting_whenPullRequestOpensWithoutMatchingBranch_keepsStateUnchanged() async throws {
        let stateStore = makeStore()
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-200",
                status: .pending,
                eventType: "new_issue",
                details: "DB-200: Add X",
                startedAt: nil,
                updatedAt: Date(),
                linearIssueId: "issue-200",
                agentPhase: .coding
            )
        )
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: MockGitHubPolling(),
            agentRunner: MockAgentRunner(),
            linearManager: MockLinearStateManager()
        )

        try await loop.routeForTesting(.prOpened(pr: 145, branch: "kai/no-identifier", title: "Add X"))

        XCTAssertNil(try stateStore.load()["linear:DB-200"]?.prNumber)
    }

    private func makeLoop(
        stateStore: StateStore,
        linearPoller: MockLinearPolling = MockLinearPolling(),
        githubPoller: MockGitHubPolling,
        dispatcher: MockEventDispatching = MockEventDispatching(),
        completionWatcher: MockCompletionWatching = MockCompletionWatching(),
        agentRunner: MockAgentRunner,
        linearManager: MockLinearStateManager,
        prReviewRequester: MockPRReviewRequester? = nil,
        prMerger: MockPRMerger? = nil,
        workspaceManager: MockWorkspaceManager = MockWorkspaceManager(),
        maxAgentRetries: Int = 3,
        githubReviewer: String = "",
        logger: @escaping (String) -> Void = { _ in }
    ) -> DaemonLoop {
        DaemonLoop(
            config: DaemonConfig(
                linearApiKey: "linear-token",
                linearTeamSlug: "DB",
                githubToken: "github-token",
                githubRepo: "afterxleep/flowdeck",
                githubReviewer: githubReviewer,
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
            prReviewRequester: prReviewRequester,
            prMerger: prMerger,
            workspaceManager: workspaceManager,
            completionWatcher: completionWatcher,
            logger: logger,
            sleep: { _ in }
        )
    }

    private func makeStore() -> StateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        return StateStore(stateFilePath: url.path)
    }

    private func seedTrackedEntry(
        store: StateStore,
        phase: AgentPhase = .waitingOnReview,
        prNumber: Int? = 145,
        prTitle: String? = "Add X"
    ) throws {
        try store.upsert(
            StateEntry(
                id: "linear:DB-200",
                status: .pending,
                eventType: "new_issue",
                details: "DB-200: Add X",
                startedAt: nil,
                updatedAt: Date(),
                sessionId: "thread-1",
                prNumber: prNumber,
                prTitle: prTitle,
                threadPath: "/tmp/thread-1.jsonl",
                linearIssueId: "issue-200",
                agentPhase: phase
            )
        )
    }
}

private final class LogSink {
    private(set) var messages: [String] = []

    func log(message: String) {
        messages.append(message)
    }
}
