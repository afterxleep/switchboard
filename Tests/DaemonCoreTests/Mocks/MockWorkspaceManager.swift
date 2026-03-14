import Foundation
@testable import DaemonCore

final class MockWorkspaceManager: WorkspaceManaging {
    var receivedEvents: [DaemonEvent] = []
    var receivedRepoPaths: [String] = []
    var receivedCleanupIds: [[String]] = []
    var stubbedWorkspacePath = "/tmp/workspace"

    func workspace(for event: DaemonEvent, repoPath: String) throws -> String {
        receivedEvents.append(event)
        receivedRepoPaths.append(repoPath)
        return stubbedWorkspacePath
    }

    func cleanup(completedIds: [String]) throws {
        receivedCleanupIds.append(completedIds)
    }

    func reset() {
        receivedEvents.removeAll()
        receivedRepoPaths.removeAll()
        receivedCleanupIds.removeAll()
        stubbedWorkspacePath = "/tmp/workspace"
    }
}
