import XCTest
@testable import DaemonCore

final class AgentRunnerLifecycleTests: XCTestCase {
    func test_newIssue_usesNewThread() async throws {
        let stateStore = StateStore(stateFilePath: makeStateFilePath())
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-196",
                status: .inFlight,
                eventType: "new_issue",
                details: "DB-196: Expand daemon",
                startedAt: Date(),
                updatedAt: Date(),
                linearIssueId: "issue-1"
            )
        )
        let workspaceManager = MockWorkspaceManager()
        workspaceManager.stubbedWorkspacePath = "/tmp/db-196"
        let codexClient = MockCodexAppServerClient()
        codexClient.lastThreadId = "thread-123"
        codexClient.lastThreadPath = "/tmp/thread-123.jsonl"
        codexClient.lastProcessIdentifier = 4242
        codexClient.lastTokensUsed = 321
        let runner = makeRunner(stateStore: stateStore, workspaceManager: workspaceManager, codexClient: codexClient)

        let result = await runner.run(
            event: .newIssue(id: "issue-1", identifier: "DB-196", title: "Expand daemon", description: "Run codex app-server directly."),
            config: makeConfig()
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(codexClient.receivedResumeThreadIds, [])
        XCTAssertEqual(codexClient.receivedPrompts, ["# Task\nDB-196: Expand daemon\n\nRun codex app-server directly."])
        XCTAssertEqual(result.threadId, "thread-123")
        XCTAssertEqual(result.threadPath, "/tmp/thread-123.jsonl")
    }

    func test_reviewComment_usesResume() async throws {
        let stateStore = StateStore(stateFilePath: makeStateFilePath())
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-196",
                status: .pending,
                eventType: "new_issue",
                details: "DB-196: Expand daemon",
                startedAt: nil,
                updatedAt: Date(),
                sessionId: "thread-123",
                prNumber: 42,
                linearIssueId: "issue-1"
            )
        )
        let codexClient = MockCodexAppServerClient()
        codexClient.stubbedResumeResult = true
        let runner = makeRunner(stateStore: stateStore, workspaceManager: MockWorkspaceManager(), codexClient: codexClient)

        _ = await runner.run(
            event: .reviewComment(pr: 42, body: "Please rename this method.", author: "afterxleep"),
            config: makeConfig()
        )

        XCTAssertEqual(codexClient.receivedResumeThreadIds, ["thread-123"])
        XCTAssertTrue(codexClient.receivedPrompts[0].contains("Please rename this method."))
    }

    func test_ciFailure_usesResume() async throws {
        let stateStore = StateStore(stateFilePath: makeStateFilePath())
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-196",
                status: .pending,
                eventType: "new_issue",
                details: "DB-196: Expand daemon",
                startedAt: nil,
                updatedAt: Date(),
                sessionId: "thread-123",
                prNumber: 42,
                linearIssueId: "issue-1"
            )
        )
        let codexClient = MockCodexAppServerClient()
        let runner = makeRunner(stateStore: stateStore, workspaceManager: MockWorkspaceManager(), codexClient: codexClient)

        _ = await runner.run(
            event: .ciFailure(pr: 42, branch: "kai/db-196-expand-daemon", failedChecks: ["swift test"]),
            config: makeConfig()
        )

        XCTAssertEqual(codexClient.receivedResumeThreadIds, ["thread-123"])
        XCTAssertTrue(codexClient.receivedPrompts[0].contains("swift test"))
    }

    func test_resumeFailure_fallsBackToNewThreadWithRecoveryContext() async throws {
        let stateStore = StateStore(stateFilePath: makeStateFilePath())
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-196",
                status: .pending,
                eventType: "new_issue",
                details: "DB-196: Expand daemon",
                startedAt: nil,
                updatedAt: Date(),
                sessionId: "thread-123",
                prNumber: 42,
                linearIssueId: "issue-1"
            )
        )
        let codexClient = MockCodexAppServerClient()
        codexClient.stubbedResumeResult = false
        codexClient.stubbedRunResult = true
        let runner = makeRunner(stateStore: stateStore, workspaceManager: MockWorkspaceManager(), codexClient: codexClient)

        _ = await runner.run(
            event: .reviewComment(pr: 42, body: "Please rename this method.", author: "afterxleep"),
            config: makeConfig()
        )

        XCTAssertEqual(codexClient.receivedResumeThreadIds, ["thread-123"])
        XCTAssertEqual(codexClient.receivedPrompts.count, 2)
        XCTAssertTrue(codexClient.receivedPrompts[1].contains("Recovery Context"))
    }

    func test_run_whenStateStoreIsMissing_returnsFailureWithContextualError() async {
        // Arrange
        let runner = AgentRunner(
            repoPath: "~/Developer/flowdeck",
            workflowTemplate: "# Task\n{{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}\n\n{{ISSUE_DESCRIPTION}}",
            workspaceManager: MockWorkspaceManager(),
            codexClient: MockCodexAppServerClient(),
            stateStore: nil
        )

        // Act
        let result = await runner.run(
            event: .newIssue(id: "issue-1", identifier: "DB-196", title: "Expand daemon", description: nil),
            config: makeConfig()
        )

        // Assert
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, String(describing: AgentRunnerError.missingStateStore))
    }

    private func makeRunner(
        stateStore: StateStore,
        workspaceManager: MockWorkspaceManager,
        codexClient: MockCodexAppServerClient
    ) -> AgentRunner {
        AgentRunner(
            repoPath: "~/Developer/flowdeck",
            workflowTemplate: "# Task\n{{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}\n\n{{ISSUE_DESCRIPTION}}",
            reviewTemplate: "Review {{ISSUE_IDENTIFIER}} PR #{{PR_NUMBER}}\n{{COMMENT_AUTHOR}} on {{COMMENT_PATH}}\n{{COMMENT_BODY}}",
            ciTemplate: "CI {{ISSUE_IDENTIFIER}} PR #{{PR_NUMBER}}\n{{FAILED_CHECKS}}",
            conflictTemplate: "Conflict {{ISSUE_IDENTIFIER}} PR #{{PR_NUMBER}}\n{{CONFLICT_BRANCH}}",
            workspaceManager: workspaceManager,
            codexClient: codexClient,
            stateStore: stateStore
        )
    }

    private func makeStateFilePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
            .path
    }

    private func makeConfig() -> DaemonConfig {
        DaemonConfig(
            linearApiKey: "linear-token",
            linearTeamSlug: "DB",
            githubToken: "github-token",
            githubRepo: "afterxleep/flowdeck",
            pollIntervalSeconds: 30,
            inFlightTimeoutSeconds: 120,
            stateFilePath: "~/.flowdeck-daemon/state.json",
            codexCommand: "/opt/homebrew/bin/codex",
            workspaceRoot: "~/.flowdeck-daemon/workspaces",
            repoPath: "~/Developer/flowdeck",
            workflowTemplatePath: "~/.flowdeck-daemon/WORKFLOW.md"
        )
    }
}
