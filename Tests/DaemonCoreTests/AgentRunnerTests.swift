import XCTest
@testable import DaemonCore

final class AgentRunnerTests: XCTestCase {
    func test_run_whenNewIssue_rendersPromptAndReturnsCodexResult() async throws {
        // Arrange
        let stateStore = StateStore(stateFilePath: makeStateFilePath())
        try stateStore.upsert(
            StateEntry(
                id: "linear:DB-196",
                status: .inFlight,
                eventType: "new_issue",
                details: "DB-196: Expand daemon",
                startedAt: Date(),
                updatedAt: Date()
            )
        )
        let workspaceManager = MockWorkspaceManager()
        workspaceManager.stubbedWorkspacePath = "/tmp/db-196"
        let codexClient = MockCodexAppServerClient()
        codexClient.lastThreadId = "thread-123"
        codexClient.lastProcessIdentifier = 4242
        codexClient.lastTokensUsed = 321
        let template = """
        # Task
        {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}

        {{ISSUE_DESCRIPTION}}
        """
        let runner = AgentRunner(
            repoPath: "~/Developer/flowdeck",
            workflowTemplate: template,
            workspaceManager: workspaceManager,
            codexClient: codexClient,
            stateStore: stateStore
        )
        let event = DaemonEvent.newIssue(
            id: "issue-1",
            identifier: "DB-196",
            title: "Expand daemon",
            description: "Run codex app-server directly."
        )
        let config = makeConfig()

        // Act
        let result = await runner.run(event: event, config: config)

        // Assert
        XCTAssertEqual(workspaceManager.receivedEvents, [event])
        XCTAssertEqual(workspaceManager.receivedRepoPaths, ["~/Developer/flowdeck"])
        XCTAssertEqual(codexClient.receivedWorkspaces, ["/tmp/db-196"])
        XCTAssertEqual(
            codexClient.receivedPrompts,
            ["# Task\nDB-196: Expand daemon\n\nRun codex app-server directly."]
        )
        XCTAssertEqual(codexClient.receivedTitles, ["DB-196: Expand daemon"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tokensUsed, 321)

        let state = try stateStore.load()
        XCTAssertEqual(state["linear:DB-196"]?.sessionId, "thread-123")
        XCTAssertEqual(state["linear:DB-196"]?.agentPid, 4242)
        XCTAssertEqual(state["linear:DB-196"]?.tokensUsed, 321)
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
