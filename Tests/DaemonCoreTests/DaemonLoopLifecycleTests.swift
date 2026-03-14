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

    func test_daemonLoop_afterAgentTurnCompletes_resolvesPendingThreads() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnReview)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = true
        githubPoller.stubbedHasUnresolvedThreads = false
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: true, tokensUsed: 5, error: nil, threadId: "thread-2", threadPath: "/tmp/thread-2.jsonl")
        let resolver = MockReviewThreadResolver()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager(),
            reviewThreadResolver: resolver
        )

        try await loop.routeForTesting(
            .unresolvedThread(
                pr: 145,
                threadId: "9001",
                nodeId: "PRT_kwDOThread1",
                path: "Sources/File.swift",
                body: "Please fix this",
                author: "afterxleep"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        try await loop.tick()

        XCTAssertEqual(resolver.receivedThreadNodeIds, ["PRT_kwDOThread1"])
    }

    func test_daemonLoop_whenResolutionFails_continuesAndLogsError() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnReview)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = false
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: true, tokensUsed: 5, error: nil, threadId: "thread-2", threadPath: "/tmp/thread-2.jsonl")
        let resolver = MockReviewThreadResolver()
        resolver.stubbedErrorSequence = [MockReviewThreadResolver.MockError.forced]
        let logs = LogSink()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager(),
            reviewThreadResolver: resolver,
            logger: logs.log(message:)
        )

        try await loop.routeForTesting(
            .unresolvedThread(
                pr: 145,
                threadId: "9001",
                nodeId: "PRT_kwDOThread1",
                path: "Sources/File.swift",
                body: "Please fix this",
                author: "afterxleep"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        try await loop.tick()

        XCTAssertEqual(resolver.receivedThreadNodeIds, ["PRT_kwDOThread1"])
        XCTAssertTrue(logs.messages.contains(where: { $0.contains("failed to resolve review thread PRT_kwDOThread1") }))
    }

    func test_daemonLoop_clearsNodeIdsAfterResolution() async throws {
        let stateStore = makeStore()
        try seedTrackedEntry(store: stateStore, phase: .waitingOnReview)
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = false
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: true, tokensUsed: 5, error: nil, threadId: "thread-2", threadPath: "/tmp/thread-2.jsonl")
        let resolver = MockReviewThreadResolver()
        let loop = makeLoop(
            stateStore: stateStore,
            githubPoller: githubPoller,
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager(),
            reviewThreadResolver: resolver
        )

        try await loop.routeForTesting(
            .unresolvedThread(
                pr: 145,
                threadId: "9001",
                nodeId: "PRT_kwDOThread1",
                path: "Sources/File.swift",
                body: "Please fix this",
                author: "afterxleep"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        try await loop.tick()

        let entry = try XCTUnwrap(try stateStore.load()["linear:DB-200"])
        XCTAssertTrue(entry.pendingThreadNodeIds.isEmpty)
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

    func test_agentFailure_atMaxRetries_resetsAndRequeuesWithoutDispatch() async throws {
        // Arrange
        let stateStore = makeStore()
        let linearPoller = MockLinearPolling()
        linearPoller.stubbedEvents = [.newIssue(id: "issue-200", identifier: "DB-200", title: "Add X", description: nil)]
        let dispatcher = MockEventDispatching()
        let agentRunner = MockAgentRunner()
        agentRunner.stubbedResult = AgentResult(success: false, tokensUsed: 0, error: "boom", threadId: nil, threadPath: nil)
        let loop = makeLoop(
            stateStore: stateStore,
            linearPoller: linearPoller,
            githubPoller: MockGitHubPolling(),
            dispatcher: dispatcher,
            completionWatcher: MockCompletionWatching(),
            agentRunner: agentRunner,
            linearManager: MockLinearStateManager(),
            maxAgentRetries: 1
        )

        // Act — tick to start agent, wait for it to complete, tick again to process result
        try await loop.tick()
        try await Task.sleep(nanoseconds: 200_000_000)
        try await loop.tick()
        try await Task.sleep(nanoseconds: 200_000_000)
        try await loop.tick()

        // Assert — no synthetic fallback event dispatched (that would create duplicate state entries)
        XCTAssertTrue(dispatcher.receivedDispatchedEvents.isEmpty, "no fallback dispatch expected")
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

    func test_newIssue_whenOpenPRExists_attachesPRInsteadOfSpawningAgent() async throws {
        // Arrange
        let store = makeStore()
        let runner = MockAgentRunner()
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedExistingPR = (prNumber: 55, branch: "kai/db-201-fix-thing", title: "Fix thing")
        let linearManager = MockLinearStateManager()
        let loop = DaemonLoop(
            config: DaemonConfig(
                linearApiKey: "linear-token",
                linearTeamSlug: "DB",
                linearAssigneeId: "",
                githubToken: "github-token",
                githubRepo: "afterxleep/flowdeck",
                githubReviewer: "",
                pollIntervalSeconds: 30,
                inFlightTimeoutSeconds: 120,
                stateFilePath: store.stateFilePath,
                codexCommand: "/opt/homebrew/bin/codex",
                workspaceRoot: "~/.flowdeck-daemon/workspaces",
                repoPath: "~/Developer/flowdeck",
                workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md",
                maxAgentRetries: 3
            ),
            linearPoller: MockLinearPolling(),
            githubPoller: githubPoller,
            dispatcher: MockEventDispatching(),
            stateStore: store,
            agentRunner: runner,
            linearStateManager: linearManager
        )

        // Act
        let newIssueEvent = DaemonEvent.newIssue(id: "issue-201", identifier: "DB-201", title: "Fix thing", description: nil)
        try await loop.routeForTesting(newIssueEvent)

        // Assert — PR attached, no agent spawned
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-201"])
        XCTAssertEqual(entry.prNumber, 55)
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnCI)
        XCTAssertTrue(runner.receivedEvents.isEmpty, "Codex should not be spawned when PR already exists")
        XCTAssertEqual(githubPoller.receivedFindOpenPRIdentifiers, ["DB-201"])
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
        reviewThreadResolver: MockReviewThreadResolver? = nil,
        workspaceManager: MockWorkspaceManager = MockWorkspaceManager(),
        maxAgentRetries: Int = 3,
        maxConcurrentAgents: Int = 10,
        githubReviewer: String = "",
        logger: @escaping (String) -> Void = { _ in }
    ) -> DaemonLoop {
        DaemonLoop(
            config: DaemonConfig(
                linearApiKey: "linear-token",
                linearTeamSlug: "DB",
                linearAssigneeId: "",
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
                maxAgentRetries: maxAgentRetries,
                maxConcurrentAgents: maxConcurrentAgents
            ),
            linearPoller: linearPoller,
            githubPoller: githubPoller,
            dispatcher: dispatcher,
            stateStore: stateStore,
            agentRunner: agentRunner,
            linearStateManager: linearManager,
            prReviewRequester: prReviewRequester,
            prMerger: prMerger,
            reviewThreadResolver: reviewThreadResolver,
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

extension DaemonLoopLifecycleTests {
    // MARK: - linkedPRNumber skips findOpenPR

    func test_newIssue_whenLinkedPRNumber_attachesDirectlyWithoutSearchingGitHub() async throws {
        // Arrange
        let store = makeStore()
        let runner = MockAgentRunner()
        let githubPoller = MockGitHubPolling()
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: runner, linearManager: MockLinearStateManager())

        // Act
        let event = DaemonEvent.newIssue(id: "issue-300", identifier: "DB-300", title: "Fix", description: nil, linkedPRNumber: 77)
        try await loop.routeForTesting(event)

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-300"])
        XCTAssertEqual(entry.prNumber, 77)
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnCI)
        XCTAssertTrue(runner.receivedEvents.isEmpty, "should not spawn Codex for existing PR")
        XCTAssertTrue(githubPoller.receivedFindOpenPRIdentifiers.isEmpty, "should not call findOpenPR when linkedPRNumber provided")
    }

    // MARK: - PR-attach does not move Linear state

    func test_newIssue_whenExistingPRFound_doesNotMoveLinearState() async throws {
        // Arrange
        let store = makeStore()
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedExistingPR = (prNumber: 88, branch: "kai/db-301-fix", title: "Fix")
        let linearManager = MockLinearStateManager()
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: linearManager)

        // Act
        let event = DaemonEvent.newIssue(id: "issue-301", identifier: "DB-301", title: "Fix", description: nil)
        try await loop.routeForTesting(event)

        // Assert
        XCTAssertEqual(linearManager.movedToInProgressIds.count, 0, "should not change Linear state when attaching existing PR")
    }

    // MARK: - Standalone PR tracking

    func test_prOpened_whenNoMatchingLinearEntry_createsStandaloneEntry() async throws {
        // Arrange
        let store = makeStore()
        let loop = makeLoop(stateStore: store, githubPoller: MockGitHubPolling(), agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager())

        // Act
        try await loop.routeForTesting(DaemonEvent.prOpened(pr: 55, branch: "feature/no-issue", title: "Standalone PR"))

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["gh:pr:55"])
        XCTAssertEqual(entry.prNumber, 55)
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnCI)
        XCTAssertNil(entry.linearIssueId)
    }

    // MARK: - reconcile self-heals addressingFeedback

    func test_reconcile_whenAddressingFeedbackHasNoThreadsAndNoConflicts_advancesToWaitingOnCI() async throws {
        // Arrange
        let store = makeStore()
        try store.upsert(StateEntry(
            id: "linear:DB-400",
            status: .pending,
            eventType: "new_issue",
            details: "DB-400",
            startedAt: nil,
            updatedAt: Date(),
            prNumber: 99,
            linearIssueId: "issue-400",
            agentPhase: .addressingFeedback
        ))
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedHasUnresolvedThreads = false
        githubPoller.stubbedHasConflicts = false
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager())

        // Act
        try await loop.reconcile()

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-400"])
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnCI)
    }

    func test_reconcile_whenAddressingFeedbackHasUnresolvedThreads_keepsPhase() async throws {
        // Arrange
        let store = makeStore()
        try store.upsert(StateEntry(
            id: "linear:DB-401",
            status: .pending,
            eventType: "new_issue",
            details: "DB-401",
            startedAt: nil,
            updatedAt: Date(),
            prNumber: 100,
            linearIssueId: "issue-401",
            agentPhase: .addressingFeedback
        ))
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedHasUnresolvedThreads = true
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager())

        // Act
        try await loop.reconcile()

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-401"])
        XCTAssertEqual(entry.agentPhase, AgentPhase.addressingFeedback)
    }

    // MARK: - Concurrency cap

    func test_startAgentIfIdle_whenConcurrencyCapReached_defersAgent() async throws {
        // Arrange — seed two entries, cap at 1
        let store = makeStore()
        for id in ["linear:DB-501", "linear:DB-502"] {
            try store.upsert(StateEntry(
                id: id,
                status: .pending,
                eventType: "new_issue",
                details: id,
                startedAt: nil,
                updatedAt: Date(),
                prNumber: id == "linear:DB-501" ? 101 : 102,
                linearIssueId: id,
                agentPhase: .addressingFeedback
            ))
        }
        let runner = MockAgentRunner()
        let loop = makeLoop(
            stateStore: store,
            githubPoller: MockGitHubPolling(),
            agentRunner: runner,
            linearManager: MockLinearStateManager(),
            maxAgentRetries: 3,
            maxConcurrentAgents: 1
        )

        // Act — route two feedback events
        try await loop.routeForTesting(DaemonEvent.reviewComment(pr: 101, body: "Fix this", author: "afterxleep"))
        try await loop.routeForTesting(DaemonEvent.reviewComment(pr: 102, body: "Fix that", author: "afterxleep"))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Assert — only 1 agent started despite 2 events
        XCTAssertEqual(runner.receivedEvents.count, 1, "concurrency cap should defer the second agent")
    }
    func test_reconcile_whenWaitingOnCIButCIAlreadyPassing_advancesToWaitingOnReview() async throws {
        // Arrange
        let store = makeStore()
        try store.upsert(StateEntry(
            id: "linear:DB-500",
            status: .pending,
            eventType: "new_issue",
            details: "DB-500",
            startedAt: nil,
            updatedAt: Date(),
            prNumber: 200,
            linearIssueId: "issue-500",
            agentPhase: .waitingOnCI
        ))
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = true
        githubPoller.stubbedHasUnresolvedThreads = false
        let linearManager = MockLinearStateManager()
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: linearManager)

        // Act
        try await loop.reconcile()

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-500"])
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnReview)
        XCTAssertEqual(linearManager.inReviewIssueIds, ["issue-500"])
    }

    func test_reconcile_whenWaitingOnCIButCIAlreadyPassingWithThreads_advancesToAddressingFeedback() async throws {
        // Arrange
        let store = makeStore()
        try store.upsert(StateEntry(
            id: "linear:DB-501",
            status: .pending,
            eventType: "new_issue",
            details: "DB-501",
            startedAt: nil,
            updatedAt: Date(),
            prNumber: 201,
            linearIssueId: "issue-501",
            agentPhase: .waitingOnCI
        ))
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = true
        githubPoller.stubbedHasUnresolvedThreads = true
        let linearManager = MockLinearStateManager()
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: linearManager)

        // Act
        try await loop.reconcile()

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-501"])
        XCTAssertEqual(entry.agentPhase, AgentPhase.addressingFeedback)
        XCTAssertEqual(linearManager.inProgressIssueIds, ["issue-501"])
    }

    func test_reconcile_whenWaitingOnCIAndCINotPassing_keepsPhase() async throws {
        // Arrange
        let store = makeStore()
        try store.upsert(StateEntry(
            id: "linear:DB-502",
            status: .pending,
            eventType: "new_issue",
            details: "DB-502",
            startedAt: nil,
            updatedAt: Date(),
            prNumber: 202,
            linearIssueId: "issue-502",
            agentPhase: .waitingOnCI
        ))
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedCIIsPassing = false
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager())

        // Act
        try await loop.reconcile()

        // Assert
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-502"])
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnCI)
    }

    func test_newIssue_whenEntryAlreadyTrackedWithPR_doesNotOverwritePhase() async throws {
        // Arrange — entry already in waitingOnReview
        let store = makeStore()
        try store.upsert(StateEntry(
            id: "linear:DB-600",
            status: .pending,
            eventType: "new_issue",
            details: "DB-600",
            startedAt: nil,
            updatedAt: Date(),
            prNumber: 300,
            linearIssueId: "issue-600",
            agentPhase: .waitingOnReview
        ))
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedExistingPR = (prNumber: 300, branch: "kai/db-600-fix", title: "Fix")
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller, agentRunner: MockAgentRunner(), linearManager: MockLinearStateManager())

        // Act — re-route the same issue (simulates next tick from LinearPoller)
        let event = DaemonEvent.newIssue(id: "issue-600", identifier: "DB-600", title: "Fix", description: nil)
        try await loop.routeForTesting(event)

        // Assert — phase must not be reset to waitingOnCI
        let state = try store.load()
        let entry = try XCTUnwrap(state["linear:DB-600"])
        XCTAssertEqual(entry.agentPhase, AgentPhase.waitingOnReview, "should not overwrite existing tracked entry")
    }

}
