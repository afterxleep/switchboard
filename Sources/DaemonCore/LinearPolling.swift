import Foundation

public protocol LinearPolling {
    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent]
}
