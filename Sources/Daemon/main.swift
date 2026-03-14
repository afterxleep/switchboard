import DaemonCore
import Dispatch
import Foundation

private var runningLoop: DaemonLoop?

private func parseIntervalOverride(arguments: [String]) -> TimeInterval? {
    guard let flagIndex = arguments.firstIndex(of: "--interval") else {
        return nil
    }

    let valueIndex = arguments.index(after: flagIndex)
    guard valueIndex < arguments.endIndex else {
        fputs("Missing value for --interval\n", stderr)
        exit(1)
    }

    guard let interval = TimeInterval(arguments[valueIndex]) else {
        fputs("Invalid --interval value: \(arguments[valueIndex])\n", stderr)
        exit(1)
    }

    return interval
}

private func makeConfig() -> DaemonConfig {
    do {
        var config = try DaemonConfig.fromEnvironment()
        if let intervalOverride = parseIntervalOverride(arguments: CommandLine.arguments) {
            config = DaemonConfig(
                linearApiKey: config.linearApiKey,
                linearTeamSlug: config.linearTeamSlug,
                linearAssigneeId: config.linearAssigneeId,
                githubToken: config.githubToken,
                githubRepo: config.githubRepo,
                githubReviewer: config.githubReviewer,
                pollIntervalSeconds: intervalOverride,
                inFlightTimeoutSeconds: config.inFlightTimeoutSeconds,
                stateFilePath: config.stateFilePath,
                codexCommand: config.codexCommand,
                workspaceRoot: config.workspaceRoot,
                repoPath: config.repoPath,
                workflowTemplatePath: config.workflowTemplatePath,
                workflowReviewTemplatePath: config.workflowReviewTemplatePath,
                workflowCITemplatePath: config.workflowCITemplatePath,
                workflowConflictTemplatePath: config.workflowConflictTemplatePath,
                linearInProgressStateId: config.linearInProgressStateId,
                linearInReviewStateId: config.linearInReviewStateId,
                linearDoneStateId: config.linearDoneStateId,
                maxAgentRetries: config.maxAgentRetries,
                ciFailureThreshold: config.ciFailureThreshold
            )
        }
        return config
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        fputs("Required environment variables: LINEAR_API_KEY, GITHUB_TOKEN\n", stderr)
        exit(1)
    }
}

private func logJSON(level: String, message: String, metadata: [String: Any]) {
    var payload = metadata
    payload["time"] = ISO8601DateFormatter().string(from: Date())
    payload["level"] = level
    payload["msg"] = message

    guard
        JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else {
        fputs("{\"level\":\"error\",\"msg\":\"failed to encode log payload\"}\n", stderr)
        return
    }

    fputs(text + "\n", stderr)
}

private func installSignalHandlers(loop: DaemonLoop) {
    runningLoop = loop
    signal(SIGINT) { _ in
        runningLoop?.stop()
    }
    signal(SIGTERM) { _ in
        runningLoop?.stop()
    }
}

let config = makeConfig()
let stateStore = StateStore(stateFilePath: config.stateFilePath)
let linearPoller = LinearPoller(
    apiKey: config.linearApiKey,
    teamSlug: config.linearTeamSlug,
    assigneeId: config.linearAssigneeId
)
let githubPoller = GitHubPoller(
    token: config.githubToken,
    repo: config.githubRepo
)
let dispatcher = EventDispatcher(stateStore: stateStore)
let completionWatcher = CompletionWatcher()
let workflowTemplatePath = NSString(string: config.workflowTemplatePath).expandingTildeInPath
let workflowReviewTemplatePath = NSString(string: config.workflowReviewTemplatePath).expandingTildeInPath
let workflowCITemplatePath = NSString(string: config.workflowCITemplatePath).expandingTildeInPath
let workflowConflictTemplatePath = NSString(string: config.workflowConflictTemplatePath).expandingTildeInPath
let linearStateManager = LinearStateManager(
    apiKey: config.linearApiKey,
    inProgressStateId: config.linearInProgressStateId,
    inReviewStateId: config.linearInReviewStateId,
    doneStateId: config.linearDoneStateId
)
let prReviewRequester = PRReviewRequester(
    token: config.githubToken,
    repo: config.githubRepo
)
let prMerger = PRMerger(
    token: config.githubToken,
    repo: config.githubRepo
)
let reviewThreadResolver = ReviewThreadResolver(token: config.githubToken)

if config.linearAssigneeId.isEmpty {
    logJSON(
        level: "warning",
        message: "linear assignee filter disabled; LINEAR_ASSIGNEE_ID is empty",
        metadata: [:]
    )
}

let agentRunner: AgentRunner?
if
    let workflowTemplate = try? String(contentsOfFile: workflowTemplatePath, encoding: .utf8),
    let reviewTemplate = try? String(contentsOfFile: workflowReviewTemplatePath, encoding: .utf8),
    let ciTemplate = try? String(contentsOfFile: workflowCITemplatePath, encoding: .utf8),
    let conflictTemplate = try? String(contentsOfFile: workflowConflictTemplatePath, encoding: .utf8)
{
    agentRunner = AgentRunner(
        repoPath: config.repoPath,
        workflowTemplate: workflowTemplate,
        reviewTemplate: reviewTemplate,
        ciTemplate: ciTemplate,
        conflictTemplate: conflictTemplate,
        workspaceManager: WorkspaceManager(rootPath: config.workspaceRoot),
        codexClient: CodexAppServerClient(codexPath: config.codexCommand),
        stateStore: stateStore,
        logger: { message in
            logJSON(level: "info", message: message, metadata: [:])
        }
    )
} else {
    agentRunner = nil
    logJSON(
        level: "info",
        message: "workflow template missing, falling back to openclaw dispatch",
        metadata: ["path": workflowTemplatePath]
    )
}
let loop = DaemonLoop(
    config: config,
    linearPoller: linearPoller,
    githubPoller: githubPoller,
    dispatcher: dispatcher,
    stateStore: stateStore,
    agentRunner: agentRunner,
    linearStateManager: linearStateManager,
    prReviewRequester: prReviewRequester,
    prMerger: prMerger,
    reviewThreadResolver: reviewThreadResolver,
    workspaceManager: WorkspaceManager(rootPath: config.workspaceRoot),
    completionWatcher: completionWatcher,
    logger: { message in
        // Use "error" level only for actual errors; routine dispatch messages use "info"
        let level = message.lowercased().contains("error") || message.lowercased().contains("fail") ? "error" : "info"
        logJSON(level: level, message: message, metadata: [:])
    }
)

logJSON(
    level: "info",
    message: "daemon starting",
    metadata: [
        "repo": config.githubRepo,
        "teamSlug": config.linearTeamSlug,
        "interval": config.pollIntervalSeconds,
    ]
)

installSignalHandlers(loop: loop)

Task {
    await loop.run()
    exit(EXIT_SUCCESS)
}

dispatchMain()
