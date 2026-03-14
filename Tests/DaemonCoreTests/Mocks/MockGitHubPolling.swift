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
}
