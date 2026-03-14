import Foundation

public enum DaemonEvent: Equatable {
    case newIssue(id: String, identifier: String, title: String, description: String?, linkedPRNumber: Int? = nil)
    case issueCancelled(id: String, identifier: String)
    case prOpened(pr: Int, branch: String, title: String)
    case prClosed(pr: Int, branch: String)
    case prMerged(pr: Int, branch: String)
    case ciPassed(pr: Int, branch: String)
    case ciFailure(pr: Int, branch: String, failedChecks: [String])
    case reviewComment(pr: Int, body: String, author: String)
    case unresolvedThread(pr: Int, threadId: String, nodeId: String, path: String, body: String, author: String)
    case approved(pr: Int, branch: String)
    case conflict(pr: Int, branch: String)

    public var eventId: String {
        switch self {
        case let .newIssue(_, identifier, _, _, _):
            return "linear:\(identifier)"
        case let .issueCancelled(_, identifier):
            return "linear:\(identifier)"
        case let .prOpened(pr, _, _):
            return "gh:pr:\(pr):opened"
        case let .prClosed(pr, _):
            return "gh:pr:\(pr):closed"
        case let .prMerged(pr, _):
            return "gh:pr:\(pr):merged"
        case let .ciPassed(pr, _):
            return "gh:pr:\(pr):ci_passed"
        case let .ciFailure(pr, _, _):
            return "gh:pr:\(pr):ci_failure"
        case let .reviewComment(pr, _, _):
            return "gh:pr:\(pr):review_comment"
        case let .unresolvedThread(pr, threadId, _, _, _, _):
            return "gh:pr:\(pr):thread:\(threadId)"
        case let .approved(pr, _):
            return "gh:pr:\(pr):approved"
        case let .conflict(pr, _):
            return "gh:pr:\(pr):conflict"
        }
    }

    public var eventType: String {
        switch self {
        case .newIssue:
            return "new_issue"
        case .issueCancelled:
            return "issue_cancelled"
        case .prOpened:
            return "pr_opened"
        case .prClosed:
            return "pr_closed"
        case .prMerged:
            return "pr_merged"
        case .ciPassed:
            return "ci_passed"
        case .ciFailure:
            return "ci_failure"
        case .reviewComment:
            return "review_comment"
        case .unresolvedThread:
            return "unresolved_thread"
        case .approved:
            return "approved"
        case .conflict:
            return "conflict"
        }
    }

    public var messageIdentifier: String {
        switch self {
        case let .newIssue(_, identifier, _, _, _):
            return identifier
        case let .issueCancelled(_, identifier):
            return identifier
        case let .prOpened(pr, _, _):
            return "PR #\(pr)"
        case let .prClosed(pr, _):
            return "PR #\(pr)"
        case let .prMerged(pr, _):
            return "PR #\(pr)"
        case let .ciPassed(pr, _):
            return "PR #\(pr)"
        case let .ciFailure(pr, _, _):
            return "PR #\(pr)"
        case let .reviewComment(pr, _, _):
            return "PR #\(pr)"
        case let .unresolvedThread(pr, _, _, _, _, _):
            return "PR #\(pr)"
        case let .approved(pr, _):
            return "PR #\(pr)"
        case let .conflict(pr, _):
            return "PR #\(pr)"
        }
    }

    public var details: String {
        switch self {
        case let .newIssue(_, identifier, title, description, _):
            if let description, description.isEmpty == false {
                return "\(identifier): \(title) — \(description)"
            }
            return "\(identifier): \(title)"
        case let .issueCancelled(_, identifier):
            return "\(identifier) moved to a terminal state"
        case let .prOpened(pr, branch, title):
            return "PR #\(pr) opened on \(branch): \(title)"
        case let .prClosed(pr, branch):
            return "PR #\(pr) on \(branch) was closed without merging"
        case let .prMerged(pr, branch):
            return "PR #\(pr) on \(branch) was merged"
        case let .ciPassed(pr, branch):
            return "PR #\(pr) on \(branch) passed CI"
        case let .ciFailure(pr, branch, failedChecks):
            return "PR #\(pr) on \(branch) has failing checks: \(failedChecks.joined(separator: ", "))"
        case let .reviewComment(pr, body, author):
            return "\(author) commented on PR #\(pr): \(body)"
        case let .unresolvedThread(pr, _, _, path, body, author):
            return "\(author) left an unresolved thread on PR #\(pr) at \(path): \(body)"
        case let .approved(pr, branch):
            return "PR #\(pr) on \(branch) was approved"
        case let .conflict(pr, branch):
            return "PR #\(pr) on \(branch) has merge conflicts"
        }
    }
}
