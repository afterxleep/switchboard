import Foundation
@testable import DaemonCore

final class MockPRMerger: PRMerging {
    enum MockError: Error {
        case forced
    }

    var stubbedMergeability = PRMergeability(
        approved: false,
        ciGreen: false,
        noOpenThreads: false,
        noConflicts: false
    )
    var stubbedMergeError: Error?
    var stubbedIsMergeableError: Error?
    var receivedMergeabilityPRNumbers: [Int] = []
    var receivedMergeRequests: [(pr: Int, commitMessage: String)] = []

    func merge(pr: Int, commitMessage: String) async throws {
        receivedMergeRequests.append((pr: pr, commitMessage: commitMessage))
        if let stubbedMergeError {
            throw stubbedMergeError
        }
    }

    func isMergeable(pr: Int) async throws -> PRMergeability {
        receivedMergeabilityPRNumbers.append(pr)
        if let stubbedIsMergeableError {
            throw stubbedIsMergeableError
        }
        return stubbedMergeability
    }

    func reset() {
        stubbedMergeability = PRMergeability(
            approved: false,
            ciGreen: false,
            noOpenThreads: false,
            noConflicts: false
        )
        stubbedMergeError = nil
        stubbedIsMergeableError = nil
        receivedMergeabilityPRNumbers.removeAll()
        receivedMergeRequests.removeAll()
    }
}
