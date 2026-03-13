import Foundation

public protocol GitHubPolling {
    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent]
}
