import Foundation
@testable import DaemonCore

final class MockGitHubPolling: GitHubPolling {
    enum MockError: Error {
        case forced
    }

    var stubbedEvents: [DaemonEvent] = []
    var stubbedErrorSequence: [Error?] = []
    var receivedStates: [[String: StateEntry]] = []
    var pollCallCount = 0
    var stubbedHasUnresolvedThreads = false
    var stubbedHasConflicts = false
    var stubbedCIIsPassing = false
    var stubbedExistingPR: (prNumber: Int, branch: String, title: String)? = nil
    var receivedUnresolvedThreadPRNumbers: [Int] = []
    var receivedConflictPRNumbers: [Int] = []
    var receivedCIPassingPRNumbers: [Int] = []
    var receivedFindOpenPRIdentifiers: [String] = []

    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent] {
        receivedStates.append(state)
        pollCallCount += 1

        if stubbedErrorSequence.isEmpty == false {
            let nextError = stubbedErrorSequence.removeFirst()
            if let nextError {
                throw nextError
            }
        }

        return stubbedEvents
    }

    func hasUnresolvedThreads(prNumber: Int) async throws -> Bool {
        receivedUnresolvedThreadPRNumbers.append(prNumber)
        return stubbedHasUnresolvedThreads
    }

    func hasConflicts(prNumber: Int) async throws -> Bool {
        receivedConflictPRNumbers.append(prNumber)
        return stubbedHasConflicts
    }

    func ciIsPassing(prNumber: Int) async throws -> Bool {
        receivedCIPassingPRNumbers.append(prNumber)
        return stubbedCIIsPassing
    }

    func findOpenPR(for issueIdentifier: String) async throws -> (prNumber: Int, branch: String, title: String)? {
        receivedFindOpenPRIdentifiers.append(issueIdentifier)
        return stubbedExistingPR
    }

    func reset() {
        stubbedEvents = []
        stubbedErrorSequence = []
        receivedStates.removeAll()
        pollCallCount = 0
        stubbedHasUnresolvedThreads = false
        stubbedHasConflicts = false
        stubbedCIIsPassing = false
        stubbedExistingPR = nil
        receivedUnresolvedThreadPRNumbers.removeAll()
        receivedConflictPRNumbers.removeAll()
        receivedCIPassingPRNumbers.removeAll()
        receivedFindOpenPRIdentifiers.removeAll()
    }
}
