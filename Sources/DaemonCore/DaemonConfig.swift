import Foundation

public struct DaemonConfig {
    public let linearApiKey: String
    public let linearTeamSlug: String
    public let githubToken: String
    public let githubRepo: String
    public let pollIntervalSeconds: TimeInterval
    public let inFlightTimeoutSeconds: TimeInterval
    public let stateFilePath: String
    public let codexCommand: String
    public let workspaceRoot: String
    public let repoPath: String
    public let workflowTemplatePath: String

    public init(
        linearApiKey: String,
        linearTeamSlug: String,
        githubToken: String,
        githubRepo: String,
        pollIntervalSeconds: TimeInterval,
        inFlightTimeoutSeconds: TimeInterval,
        stateFilePath: String,
        codexCommand: String,
        workspaceRoot: String,
        repoPath: String,
        workflowTemplatePath: String
    ) {
        self.linearApiKey = linearApiKey
        self.linearTeamSlug = linearTeamSlug
        self.githubToken = githubToken
        self.githubRepo = githubRepo
        self.pollIntervalSeconds = pollIntervalSeconds
        self.inFlightTimeoutSeconds = inFlightTimeoutSeconds
        self.stateFilePath = stateFilePath
        self.codexCommand = codexCommand
        self.workspaceRoot = workspaceRoot
        self.repoPath = repoPath
        self.workflowTemplatePath = workflowTemplatePath
    }

    public static func fromEnvironment() throws -> DaemonConfig {
        let environment = ProcessInfo.processInfo.environment

        guard let linearApiKey = environment["LINEAR_API_KEY"], linearApiKey.isEmpty == false else {
            throw DaemonConfigError.missingEnvironmentVariable(name: "LINEAR_API_KEY")
        }

        guard let githubToken = environment["GITHUB_TOKEN"], githubToken.isEmpty == false else {
            throw DaemonConfigError.missingEnvironmentVariable(name: "GITHUB_TOKEN")
        }

        return DaemonConfig(
            linearApiKey: linearApiKey,
            linearTeamSlug: environment["LINEAR_TEAM_SLUG"] ?? "DB",
            githubToken: githubToken,
            githubRepo: environment["GITHUB_REPO"] ?? "afterxleep/flowdeck",
            pollIntervalSeconds: TimeInterval(environment["POLL_INTERVAL_SECONDS"] ?? "") ?? 30,
            inFlightTimeoutSeconds: TimeInterval(environment["INFLIGHT_TIMEOUT_SECONDS"] ?? "") ?? 1800,
            stateFilePath: "~/.flowdeck-daemon/state.json",
            codexCommand: environment["CODEX_COMMAND"] ?? "/opt/homebrew/bin/codex",
            workspaceRoot: environment["WORKSPACE_ROOT"] ?? "~/.flowdeck-daemon/workspaces",
            repoPath: environment["REPO_PATH"] ?? "~/Developer/flowdeck",
            workflowTemplatePath: environment["WORKFLOW_TEMPLATE_PATH"] ?? "~/.flowdeck-daemon/WORKFLOW.md"
        )
    }
}

public enum DaemonConfigError: LocalizedError, Equatable {
    case missingEnvironmentVariable(name: String)

    public var errorDescription: String? {
        switch self {
        case let .missingEnvironmentVariable(name):
            return "Missing required environment variable: \(name)"
        }
    }
}
