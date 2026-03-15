import XCTest
@testable import DaemonCore

final class ReconcileTests: XCTestCase {
    func test_reconcile_whenAddressingFeedbackAndNoThreads_keepsPhaseUnchanged() async throws {
        let store = makeStore()
        try store.upsert(
            StateEntry(
                id: "linear:DB-177",
                status: .pending,
                eventType: "new_issue",
                details: "DB-177: Fix bug",
                startedAt: nil,
                updatedAt: Date(),
                prNumber: 177,
                linearIssueId: "issue-177",
                agentPhase: .addressingFeedback
            )
        )
        let githubPoller = MockGitHubPolling()
        githubPoller.stubbedHasUnresolvedThreads = false
        let loop = makeLoop(stateStore: store, githubPoller: githubPoller)

        try await loop.reconcile()

        let entry = try XCTUnwrap(try store.load()["linear:DB-177"])
        XCTAssertEqual(entry.agentPhase, .addressingFeedback)
    }

    func test_reconcile_whenInFlightEntryTimedOut_resetsToPendingCoding() async throws {
        let store = makeStore()
        try store.upsert(
            StateEntry(
                id: "linear:DB-178",
                status: .inFlight,
                eventType: "new_issue",
                details: "DB-178: Resume work",
                startedAt: Date().addingTimeInterval(-(2 * 60 * 60 + 1)),
                updatedAt: Date().addingTimeInterval(-(2 * 60 * 60 + 1)),
                sessionId: "thread-178",
                agentPid: 178,
                prNumber: 178,
                linearIssueId: "issue-178",
                agentPhase: .waitingOnCI
            )
        )
        let logs = LogSink()
        let loop = makeLoop(stateStore: store, githubPoller: MockGitHubPolling(), logger: logs.log(message:))

        try await loop.reconcile()

        let entry = try XCTUnwrap(try store.load()["linear:DB-178"])
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(entry.agentPhase, .coding)
        XCTAssertNil(entry.startedAt)
        XCTAssertNil(entry.sessionId)
        XCTAssertNil(entry.agentPid)
        XCTAssertTrue(logs.messages.contains(where: { $0.contains("reconcile: reset timed-out entry linear:DB-178") }))
    }

    func test_reconcile_whenCiBlocked_keepsPhaseUnchanged() async throws {
        let store = makeStore()
        try store.upsert(
            StateEntry(
                id: "linear:DB-179",
                status: .pending,
                eventType: "new_issue",
                details: "DB-179: Waiting on CI",
                startedAt: nil,
                updatedAt: Date(),
                prNumber: 179,
                linearIssueId: "issue-179",
                agentPhase: .ciBlocked,
                consecutiveCIFailures: 10
            )
        )
        let loop = makeLoop(stateStore: store, githubPoller: MockGitHubPolling())

        try await loop.reconcile()

        let entry = try XCTUnwrap(try store.load()["linear:DB-179"])
        XCTAssertEqual(entry.agentPhase, .ciBlocked)
    }

    func test_reconcile_whenWaitingOnCI_keepsPhaseUnchanged() async throws {
        let store = makeStore()
        try store.upsert(
            StateEntry(
                id: "linear:DB-180",
                status: .pending,
                eventType: "new_issue",
                details: "DB-180: Waiting on CI",
                startedAt: nil,
                updatedAt: Date(),
                prNumber: 180,
                linearIssueId: "issue-180",
                agentPhase: .waitingOnCI
            )
        )
        let loop = makeLoop(stateStore: store, githubPoller: MockGitHubPolling())

        try await loop.reconcile()

        let entry = try XCTUnwrap(try store.load()["linear:DB-180"])
        XCTAssertEqual(entry.agentPhase, .waitingOnCI)
    }

    private func makeLoop(
        stateStore: StateStore,
        githubPoller: MockGitHubPolling,
        logger: @escaping (String) -> Void = { _ in }
    ) -> DaemonLoop {
        DaemonLoop(
            config: DaemonConfig(
                linearApiKey: "linear-token",
                linearTeamSlug: "DB",
                linearAssigneeId: "",
                githubToken: "github-token",
                githubRepo: "afterxleep/flowdeck",
                githubReviewer: "",
                pollIntervalSeconds: 30,
                inFlightTimeoutSeconds: 120,
                stateFilePath: stateStore.stateFilePath,
                codexCommand: "/opt/homebrew/bin/codex",
                workspaceRoot: "~/.flowdeck-daemon/workspaces",
                repoPath: "~/Developer/flowdeck",
                workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md",
                maxAgentRetries: 3
            ),
            linearPoller: MockLinearPolling(),
            githubPoller: githubPoller,
            dispatcher: MockEventDispatching(),
            stateStore: stateStore,
            agentRunner: MockAgentRunner(),
            linearStateManager: MockLinearStateManager(),
            completionWatcher: MockCompletionWatching(),
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
}

private final class LogSink {
    private(set) var messages: [String] = []

    func log(message: String) {
        messages.append(message)
    }
}
