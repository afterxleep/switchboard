import Foundation

public protocol GitHubPolling {
    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent]
    func hasUnresolvedThreads(prNumber: Int) async throws -> Bool
    func hasConflicts(prNumber: Int) async throws -> Bool
    func ciIsPassing(prNumber: Int) async throws -> Bool
    func findOpenPR(for issueIdentifier: String) async throws -> (prNumber: Int, branch: String, title: String)?
}
