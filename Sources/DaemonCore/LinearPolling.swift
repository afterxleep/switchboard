import Foundation

public protocol LinearPolling {
    func poll(knownIds: Set<String>) async throws -> [DaemonEvent]
}
