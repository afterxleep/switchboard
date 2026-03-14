import Foundation
@testable import DaemonCore

final class MockLinearStateManager: LinearStateManaging {
    var inProgressIssueIds: [String] = []
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

    func reset() {
        inProgressIssueIds.removeAll()
        inReviewIssueIds.removeAll()
        doneIssueIds.removeAll()
    }
}
