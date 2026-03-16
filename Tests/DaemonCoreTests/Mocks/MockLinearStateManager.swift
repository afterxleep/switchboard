import Foundation
@testable import DaemonCore

final class MockLinearStateManager: LinearStateManaging {
    var inProgressIssueIds: [String] = []
    var movedToInProgressIds: [String] { inProgressIssueIds }
    var inReviewIssueIds: [String] = []
    var doneIssueIds: [String] = []

    func moveToInProgress(issueId: String) async throws {
        inProgressIssueIds.append(issueId)
    }

    func moveToInReview(issueId: String) async throws {
        inReviewIssueIds.append(issueId)
    }

    func moveToDone(issueId: String) async throws {
        doneIssueIds.append(issueId)
    }

    var postedComments: [(issueId: String, body: String)] = []
    func postComment(issueId: String, body: String) async throws {
        postedComments.append((issueId: issueId, body: body))
    }

    func reset() {
        inProgressIssueIds.removeAll()
        inReviewIssueIds.removeAll()
        doneIssueIds.removeAll()
    }
}
