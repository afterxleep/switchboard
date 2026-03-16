import Foundation

public struct DaemonConfig {
    public let linearApiKey: String
    public let linearTeamSlug: String
    public let linearAssigneeId: String
    public let githubToken: String
    public let githubRepo: String
    public let githubReviewer: String
    public let pollIntervalSeconds: TimeInterval
    public let inFlightTimeoutSeconds: TimeInterval
    public let stateFilePath: String
    public let codexCommand: String
    public let workspaceRoot: String
    public let repoPath: String
    public let workflowTemplatePath: String
    public let workflowReviewTemplatePath: String
    public let workflowCITemplatePath: String
    public let workflowConflictTemplatePath: String
    public let linearInProgressStateId: String
    public let linearInReviewStateId: String
    public let linearDoneStateId: String
    public let maxAgentRetries: Int
    public let ciFailureThreshold: Int
    public let maxConsecutiveCIFailures: Int
    public let maxConcurrentAgents: Int
    public let stallTimeoutSeconds: TimeInterval
    public var assigneeLogin: String?

    public init(
        linearApiKey: String,
        linearTeamSlug: String,
        linearAssigneeId: String = "",
        githubToken: String,
        githubRepo: String,
        githubReviewer: String = "",
        pollIntervalSeconds: TimeInterval,
        inFlightTimeoutSeconds: TimeInterval,
        stateFilePath: String,
        codexCommand: String,
        workspaceRoot: String,
        repoPath: String,
        workflowTemplatePath: String,
        workflowReviewTemplatePath: String = "~/.flowdeck-daemon/WORKFLOW_REVIEW.md",
        workflowCITemplatePath: String = "~/.flowdeck-daemon/WORKFLOW_CI.md",
        workflowConflictTemplatePath: String = "~/.flowdeck-daemon/WORKFLOW_CONFLICT.md",
        linearInProgressStateId: String = "1e3cbc8e-f483-4db2-9b56-f9b4c9a56989",
        linearInReviewStateId: String = "6f88a8a8-a3d7-4f30-9980-47cebb6a2c91",
        linearDoneStateId: String = "5f2c9f55-0b3d-4a86-83ff-42b84f88dbf5",
        maxAgentRetries: Int = 3,
        ciFailureThreshold: Int = 2,
        maxConsecutiveCIFailures: Int = 10,
        maxConcurrentAgents: Int = 6,
        stallTimeoutSeconds: TimeInterval = 1800,
        assigneeLogin: String? = nil
    ) {
        self.linearApiKey = linearApiKey
        self.linearTeamSlug = linearTeamSlug
        self.linearAssigneeId = linearAssigneeId
        self.githubToken = githubToken
        self.githubRepo = githubRepo
        self.githubReviewer = githubReviewer
        self.pollIntervalSeconds = pollIntervalSeconds
        self.inFlightTimeoutSeconds = inFlightTimeoutSeconds
        self.stateFilePath = stateFilePath
        self.codexCommand = codexCommand
        self.workspaceRoot = workspaceRoot
        self.repoPath = repoPath
        self.workflowTemplatePath = workflowTemplatePath
        self.workflowReviewTemplatePath = workflowReviewTemplatePath
        self.workflowCITemplatePath = workflowCITemplatePath
        self.workflowConflictTemplatePath = workflowConflictTemplatePath
        self.linearInProgressStateId = linearInProgressStateId
        self.linearInReviewStateId = linearInReviewStateId
        self.linearDoneStateId = linearDoneStateId
        self.maxAgentRetries = maxAgentRetries
        self.ciFailureThreshold = ciFailureThreshold
        self.maxConsecutiveCIFailures = maxConsecutiveCIFailures
        self.maxConcurrentAgents = maxConcurrentAgents
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.assigneeLogin = assigneeLogin
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
            linearAssigneeId: environment["LINEAR_ASSIGNEE_ID"] ?? "",
            githubToken: githubToken,
            githubRepo: environment["GITHUB_REPO"] ?? "afterxleep/flowdeck",
            githubReviewer: environment["GITHUB_REVIEWER"] ?? "",
            pollIntervalSeconds: TimeInterval(environment["POLL_INTERVAL_SECONDS"] ?? "") ?? 30,
            inFlightTimeoutSeconds: TimeInterval(environment["INFLIGHT_TIMEOUT_SECONDS"] ?? "") ?? 1800,
            stateFilePath: "~/.flowdeck-daemon/state.json",
            codexCommand: environment["CODEX_COMMAND"] ?? "/opt/homebrew/bin/codex",
            workspaceRoot: environment["WORKSPACE_ROOT"] ?? "~/.flowdeck-daemon/workspaces",
            repoPath: environment["REPO_PATH"] ?? "~/Developer/flowdeck",
            workflowTemplatePath: environment["WORKFLOW_TEMPLATE_PATH"] ?? "~/.flowdeck-daemon/WORKFLOW.md",
            workflowReviewTemplatePath: environment["WORKFLOW_REVIEW_TEMPLATE_PATH"] ?? "~/.flowdeck-daemon/WORKFLOW_REVIEW.md",
            workflowCITemplatePath: environment["WORKFLOW_CI_TEMPLATE_PATH"] ?? "~/.flowdeck-daemon/WORKFLOW_CI.md",
            workflowConflictTemplatePath: environment["WORKFLOW_CONFLICT_TEMPLATE_PATH"] ?? "~/.flowdeck-daemon/WORKFLOW_CONFLICT.md",
            linearInProgressStateId: environment["LINEAR_IN_PROGRESS_STATE_ID"] ?? "1e3cbc8e-f483-4db2-9b56-f9b4c9a56989",
            linearInReviewStateId: environment["LINEAR_IN_REVIEW_STATE_ID"] ?? "6f88a8a8-a3d7-4f30-9980-47cebb6a2c91",
            linearDoneStateId: environment["LINEAR_DONE_STATE_ID"] ?? "5f2c9f55-0b3d-4a86-83ff-42b84f88dbf5",
            maxAgentRetries: Int(environment["MAX_AGENT_RETRIES"] ?? "") ?? 3,
            ciFailureThreshold: Int(environment["CI_FAILURE_THRESHOLD"] ?? "") ?? 2,
            maxConsecutiveCIFailures: Int(environment["MAX_CONSECUTIVE_CI_FAILURES"] ?? "") ?? 10,
            maxConcurrentAgents: Int(environment["MAX_CONCURRENT_AGENTS"] ?? "") ?? 6,
            stallTimeoutSeconds: TimeInterval(environment["STALL_TIMEOUT_SECONDS"] ?? "") ?? 1800,
            assigneeLogin: environment["FLOWDECK_ASSIGNEE_LOGIN"].flatMap { $0.isEmpty ? nil : $0 }
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
