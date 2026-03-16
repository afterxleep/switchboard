import Foundation

public final class AgentRunner: AgentRunning {
    private let workspaceManager: any WorkspaceManaging
    private let codexClient: any CodexAppServerRunning
    private let repoPath: String
    private let workflowTemplate: String
    private let reviewTemplate: String
    private let ciTemplate: String
    private let conflictTemplate: String
    private let stateStore: (any StateStoring)?
    private let logger: (String) -> Void

    public init(
        repoPath: String,
        workflowTemplate: String,
        reviewTemplate: String = "",
        ciTemplate: String = "",
        conflictTemplate: String = "",
        workspaceManager: any WorkspaceManaging = WorkspaceManager(),
        codexClient: any CodexAppServerRunning = CodexAppServerClient(),
        stateStore: (any StateStoring)? = nil,
        logger: @escaping (String) -> Void = { _ in }
    ) {
        self.repoPath = repoPath
        self.workflowTemplate = workflowTemplate
        self.reviewTemplate = reviewTemplate
        self.ciTemplate = ciTemplate
        self.conflictTemplate = conflictTemplate
        self.workspaceManager = workspaceManager
        self.codexClient = codexClient
        self.stateStore = stateStore
        self.logger = logger
    }

    public func run(event: DaemonEvent, config: DaemonConfig) async -> AgentResult {
        do {
            let workspace = try workspaceManager.workspace(for: event, repoPath: repoPath)
            _ = config
            let context = try resolveContext(for: event)
            let turnTitle = "\(context.identifier): \(context.title)"
            let prompt = renderPrompt(event: event, context: context)
            let logEvent: (String) -> Void = { [logger] message in
                logger("[\(context.identifier)] \(message)")
            }

            let succeeded: Bool
            if case .newIssue = event {
                succeeded = await codexClient.run(
                    workspace: workspace,
                    prompt: prompt,
                    title: turnTitle,
                    onEvent: logEvent,
                    turnTimeoutSeconds: 3600,
                    stallTimeoutSeconds: config.stallTimeoutSeconds
                )
            } else if let threadId = context.threadId {
                let resumed = await codexClient.resume(
                    workspace: workspace,
                    threadId: threadId,
                    prompt: prompt,
                    title: turnTitle,
                    onEvent: logEvent,
                    turnTimeoutSeconds: 3600,
                    stallTimeoutSeconds: config.stallTimeoutSeconds
                )
                if resumed {
                    succeeded = true
                } else {
                    let fallbackPrompt = renderFallbackPrompt(event: event, context: context)
                    succeeded = await codexClient.run(
                        workspace: workspace,
                        prompt: fallbackPrompt,
                        title: turnTitle,
                        onEvent: logEvent,
                        turnTimeoutSeconds: 3600,
                        stallTimeoutSeconds: config.stallTimeoutSeconds
                    )
                }
            } else {
                succeeded = await codexClient.run(
                    workspace: workspace,
                    prompt: renderFallbackPrompt(event: event, context: context),
                    title: turnTitle,
                    onEvent: logEvent,
                    turnTimeoutSeconds: 3600,
                    stallTimeoutSeconds: config.stallTimeoutSeconds
                )
            }

            try stateStore?.updateMetadata(
                id: context.entry.id,
                sessionId: codexClient.lastThreadId,
                agentPid: codexClient.lastProcessIdentifier,
                tokensUsed: codexClient.lastTokensUsed
            )
            try stateStore?.updateThread(
                id: context.entry.id,
                sessionId: codexClient.lastThreadId,
                threadPath: codexClient.lastThreadPath
            )

            return AgentResult(
                success: succeeded,
                tokensUsed: codexClient.lastTokensUsed,
                error: codexClient.lastError,
                threadId: codexClient.lastThreadId,
                threadPath: codexClient.lastThreadPath
            )
        } catch {
            return AgentResult(success: false, tokensUsed: 0, error: String(describing: error), threadId: nil, threadPath: nil)
        }
    }

    private func renderPrompt(event: DaemonEvent, context: AgentContext) -> String {
        switch event {
        case let .newIssue(_, _, _, description, _):
            return applyCommonPlaceholders(
                workflowTemplate,
                context: context,
                extra: ["{{ISSUE_DESCRIPTION}}": description ?? ""]
            )
        case let .reviewComment(pr, body, author):
            return applyCommonPlaceholders(
                reviewTemplate,
                context: context,
                extra: [
                    "{{PR_NUMBER}}": String(pr),
                    "{{COMMENT_BODY}}": body,
                    "{{COMMENT_AUTHOR}}": author,
                    "{{COMMENT_PATH}}": "PR discussion",
                ]
            )
        case let .unresolvedThread(pr, _, _, path, body, author):
            return applyCommonPlaceholders(
                reviewTemplate,
                context: context,
                extra: [
                    "{{PR_NUMBER}}": String(pr),
                    "{{COMMENT_BODY}}": body,
                    "{{COMMENT_AUTHOR}}": author,
                    "{{COMMENT_PATH}}": path,
                ]
            )
        case let .ciFailure(pr, _, failedChecks):
            return applyCommonPlaceholders(
                ciTemplate,
                context: context,
                extra: [
                    "{{PR_NUMBER}}": String(pr),
                    "{{FAILED_CHECKS}}": failedChecks.joined(separator: ", "),
                ]
            )
        case let .conflict(pr, branch):
            return applyCommonPlaceholders(
                conflictTemplate,
                context: context,
                extra: [
                    "{{PR_NUMBER}}": String(pr),
                    "{{CONFLICT_BRANCH}}": branch,
                ]
            )
        default:
            return applyCommonPlaceholders(workflowTemplate, context: context, extra: [:])
        }
    }

    private func renderFallbackPrompt(event: DaemonEvent, context: AgentContext) -> String {
        let base = renderPrompt(event: event, context: context)
        return """
        \(base)

        ## Recovery Context

        The previous Codex thread could not be resumed. Continue from the current workspace state and existing PR context.
        """
    }

    private func applyCommonPlaceholders(
        _ template: String,
        context: AgentContext,
        extra: [String: String]
    ) -> String {
        let replacements = [
            "{{ISSUE_IDENTIFIER}}": context.identifier,
            "{{ISSUE_TITLE}}": context.title,
            "{{PR_NUMBER}}": context.prNumber.map(String.init) ?? "",
            "{{COMMENT_BODY}}": "",
            "{{COMMENT_AUTHOR}}": "",
            "{{COMMENT_PATH}}": "",
            "{{FAILED_CHECKS}}": "",
            "{{CONFLICT_BRANCH}}": "",
            "{{ISSUE_DESCRIPTION}}": "",
        ].merging(extra) { _, new in new }

        var rendered = template
        for (placeholder, value) in replacements {
            rendered = rendered.replacingOccurrences(of: placeholder, with: value)
        }

        return rendered
    }

    private func resolveContext(for event: DaemonEvent) throws -> AgentContext {
        guard let stateStore else {
            throw AgentRunnerError.missingStateStore
        }

        let state = try stateStore.load()
        let entry: StateEntry
        let identifier: String

        switch event {
        case let .newIssue(id, issueIdentifier, title, _, _):
            entry = state[event.eventId] ?? StateEntry(
                id: event.eventId,
                status: .pending,
                eventType: event.eventType,
                details: event.details,
                startedAt: nil,
                updatedAt: Date(),
                linearIssueId: id
            )
            identifier = issueIdentifier
            return AgentContext(entry: entry, identifier: identifier, title: title, prNumber: entry.prNumber, threadId: entry.sessionId)
        case let .reviewComment(pr, _, _),
             let .ciFailure(pr, _, _),
             let .conflict(pr, _),
             let .approved(pr, _),
             let .prOpened(pr, _, _),
             let .prClosed(pr, _),
             let .prMerged(pr, _),
             let .ciPassed(pr, _),
             let .unresolvedThread(pr, _, _, _, _, _):
            guard let matchedEntry = state.values.first(where: { $0.prNumber == pr }) else {
                throw AgentRunnerError.missingStateEntry(event: event.eventId)
            }
            entry = matchedEntry
            identifier = matchedEntry.messageIdentifier
        case let .issueCancelled(_, issueIdentifier):
            guard let matchedEntry = state[event.eventId] else {
                throw AgentRunnerError.missingStateEntry(event: event.eventId)
            }
            entry = matchedEntry
            identifier = issueIdentifier
        }

        let title = parseTitle(from: entry.details, fallback: identifier)
        return AgentContext(entry: entry, identifier: identifier, title: title, prNumber: entry.prNumber, threadId: entry.sessionId)
    }

    private func parseTitle(from details: String, fallback: String) -> String {
        guard let separatorRange = details.range(of: ": ") else {
            return fallback
        }
        let titleStart = separatorRange.upperBound
        return String(details[titleStart...]).split(separator: "—", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? fallback
    }
}

public enum AgentRunnerError: LocalizedError, Equatable {
    case missingStateStore
    case missingStateEntry(event: String)

    public var errorDescription: String? {
        switch self {
        case .missingStateStore:
            return "AgentRunner requires a StateStore for lifecycle events"
        case let .missingStateEntry(event):
            return "No state entry found for event \(event)"
        }
    }
}

private struct AgentContext {
    let entry: StateEntry
    let identifier: String
    let title: String
    let prNumber: Int?
    let threadId: String?
}
