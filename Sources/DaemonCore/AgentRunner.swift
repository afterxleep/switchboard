import Foundation

public final class AgentRunner: AgentRunning {
    private let workspaceManager: any WorkspaceManaging
    private let codexClient: any CodexAppServerRunning
    private let repoPath: String
    private let workflowTemplate: String
    private let stateStore: StateStore?
    private let logger: (String) -> Void

    public init(
        repoPath: String,
        workflowTemplate: String,
        workspaceManager: any WorkspaceManaging = WorkspaceManager(),
        codexClient: any CodexAppServerRunning = CodexAppServerClient(),
        stateStore: StateStore? = nil,
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.repoPath = repoPath
        self.workflowTemplate = workflowTemplate
        self.workspaceManager = workspaceManager
        self.codexClient = codexClient
        self.stateStore = stateStore
        self.logger = logger
    }

    public func run(event: DaemonEvent, config: DaemonConfig) async -> AgentResult {
        guard case let .newIssue(_, identifier, title, description) = event else {
            return AgentResult(success: false, tokensUsed: 0, error: "unsupported event type: \(event.eventType)")
        }

        do {
            let workspace = try workspaceManager.workspace(for: event, repoPath: repoPath)
            let prompt = renderPrompt(
                identifier: identifier,
                title: title,
                description: description
            )
            let turnTitle = "\(identifier): \(title)"
            let succeeded = await codexClient.run(
                workspace: workspace,
                prompt: prompt,
                title: turnTitle,
                onEvent: { [logger] message in
                    logger("[\(identifier)] \(message)")
                },
                turnTimeoutSeconds: 3600,
                stallTimeoutSeconds: 300
            )

            try stateStore?.updateMetadata(
                id: event.eventId,
                sessionId: codexClient.lastThreadId,
                agentPid: codexClient.lastProcessIdentifier,
                tokensUsed: codexClient.lastTokensUsed
            )

            return AgentResult(
                success: succeeded,
                tokensUsed: codexClient.lastTokensUsed,
                error: codexClient.lastError
            )
        } catch {
            return AgentResult(success: false, tokensUsed: 0, error: String(describing: error))
        }
    }

    private func renderPrompt(identifier: String, title: String, description: String?) -> String {
        workflowTemplate
            .replacingOccurrences(of: "{{ISSUE_IDENTIFIER}}", with: identifier)
            .replacingOccurrences(of: "{{ISSUE_TITLE}}", with: title)
            .replacingOccurrences(of: "{{ISSUE_DESCRIPTION}}", with: description ?? "")
    }
}
