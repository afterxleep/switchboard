import Foundation
@testable import DaemonCore

final class MockPRReviewRequester: PRReviewRequesting {
    enum MockError: Error {
        case forced
    }

    var receivedRequests: [(pr: Int, reviewer: String)] = []
    var stubbedError: Error?

    func requestReview(pr: Int, reviewer: String) async throws {
        receivedRequests.append((pr: pr, reviewer: reviewer))
        if let stubbedError {
            throw stubbedError
        }
    }

    func reset() {
        receivedRequests.removeAll()
        stubbedError = nil
    }
}
