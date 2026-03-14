import Foundation

public protocol WorkspaceManaging {
    func workspace(for event: DaemonEvent, repoPath: String) throws -> String
    func cleanup(completedIds: [String]) throws
}
