import Foundation

public enum DaemonEvent: Equatable {
    case newIssue(id: String, identifier: String, title: String, description: String?)
    case issueCancelled(id: String, identifier: String)
    case ciFailure(pr: Int, branch: String, failedChecks: [String])
    case reviewComment(pr: Int, body: String, author: String)
    case approved(pr: Int, branch: String)
    case conflict(pr: Int, branch: String)

    public var eventId: String {
        switch self {
        case let .newIssue(_, identifier, _, _):
            return "linear:\(identifier)"
        case let .issueCancelled(_, identifier):
            return "linear:\(identifier)"
        case let .ciFailure(pr, _, _):
            return "gh:pr:\(pr):ci_failure"
        case let .reviewComment(pr, _, _):
            return "gh:pr:\(pr):review_comment"
        case let .approved(pr, _):
            return "gh:pr:\(pr):approved"
        case let .conflict(pr, _):
            return "gh:pr:\(pr):conflict"
        }
    }

    public var details: String {
        switch self {
        case let .newIssue(_, identifier, title, description):
            if let description, description.isEmpty == false {
                return "\(identifier): \(title) — \(description)"
            }
            return "\(identifier): \(title)"
        case let .issueCancelled(_, identifier):
            return "\(identifier) moved to a terminal state"
        case let .ciFailure(pr, branch, failedChecks):
            return "PR #\(pr) on \(branch) has failing checks: \(failedChecks.joined(separator: ", "))"
        case let .reviewComment(pr, body, author):
            return "\(author) commented on PR #\(pr): \(body)"
        case let .approved(pr, branch):
            return "PR #\(pr) on \(branch) was approved"
        case let .conflict(pr, branch):
            return "PR #\(pr) on \(branch) has merge conflicts"
        }
    }
}
