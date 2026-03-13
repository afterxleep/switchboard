import Foundation
@testable import DaemonCore

final class MockGitHubPolling: GitHubPolling {
    var stubbedEvents: [DaemonEvent] = []
    var receivedStates: [[String: StateEntry]] = []

    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent] {
        receivedStates.append(state)
        return stubbedEvents
    }
}
