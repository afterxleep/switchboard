import XCTest
@testable import DaemonCore

final class DaemonConfigTests: XCTestCase {
    override func tearDown() {
        unsetenv("LINEAR_API_KEY")
        unsetenv("LINEAR_TEAM_SLUG")
        unsetenv("GITHUB_TOKEN")
        unsetenv("GITHUB_REPO")
        unsetenv("POLL_INTERVAL_SECONDS")
        unsetenv("INFLIGHT_TIMEOUT_SECONDS")
        unsetenv("CODEX_COMMAND")
        unsetenv("WORKSPACE_ROOT")
        unsetenv("REPO_PATH")
        unsetenv("WORKFLOW_TEMPLATE_PATH")
        super.tearDown()
    }

    func test_fromEnvironment_whenOptionalValuesMissing_usesDefaults() throws {
        // Arrange
        setenv("LINEAR_API_KEY", "linear-token", 1)
        setenv("GITHUB_TOKEN", "github-token", 1)

        // Act
        let config = try DaemonConfig.fromEnvironment()

        // Assert
        XCTAssertEqual(config.linearApiKey, "linear-token")
        XCTAssertEqual(config.linearTeamSlug, "DB")
        XCTAssertEqual(config.githubToken, "github-token")
        XCTAssertEqual(config.githubRepo, "afterxleep/flowdeck")
        XCTAssertEqual(config.pollIntervalSeconds, 30)
        XCTAssertEqual(config.inFlightTimeoutSeconds, 1800)
        XCTAssertEqual(
            NSString(string: config.stateFilePath).expandingTildeInPath,
            NSString(string: "~/.flowdeck-daemon/state.json").expandingTildeInPath
        )
        XCTAssertEqual(config.codexCommand, "/opt/homebrew/bin/codex")
        XCTAssertEqual(config.workspaceRoot, "~/.flowdeck-daemon/workspaces")
        XCTAssertEqual(config.repoPath, "~/Developer/flowdeck")
        XCTAssertEqual(config.workflowTemplatePath, "~/.flowdeck-daemon/WORKFLOW.md")
    }

    func test_fromEnvironment_whenOptionalValuesPresent_loadsOverrides() throws {
        // Arrange
        setenv("LINEAR_API_KEY", "linear-token", 1)
        setenv("LINEAR_TEAM_SLUG", "platform", 1)
        setenv("GITHUB_TOKEN", "github-token", 1)
        setenv("GITHUB_REPO", "acme/daemon", 1)
        setenv("POLL_INTERVAL_SECONDS", "45", 1)
        setenv("INFLIGHT_TIMEOUT_SECONDS", "900", 1)
        setenv("CODEX_COMMAND", "/usr/local/bin/codex", 1)
        setenv("WORKSPACE_ROOT", "/tmp/workspaces", 1)
        setenv("REPO_PATH", "/tmp/repo", 1)
        setenv("WORKFLOW_TEMPLATE_PATH", "/tmp/WORKFLOW.md", 1)

        // Act
        let config = try DaemonConfig.fromEnvironment()

        // Assert
        XCTAssertEqual(config.linearTeamSlug, "platform")
        XCTAssertEqual(config.githubRepo, "acme/daemon")
        XCTAssertEqual(config.pollIntervalSeconds, 45)
        XCTAssertEqual(config.inFlightTimeoutSeconds, 900)
        XCTAssertEqual(config.codexCommand, "/usr/local/bin/codex")
        XCTAssertEqual(config.workspaceRoot, "/tmp/workspaces")
        XCTAssertEqual(config.repoPath, "/tmp/repo")
        XCTAssertEqual(config.workflowTemplatePath, "/tmp/WORKFLOW.md")
    }

    func test_fromEnvironment_whenRequiredValuesMissing_throwsError() {
        // Arrange
        unsetenv("LINEAR_API_KEY")
        unsetenv("GITHUB_TOKEN")

        // Act / Assert
        XCTAssertThrowsError(try DaemonConfig.fromEnvironment())
    }
}
