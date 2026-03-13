import Foundation

public protocol EventDispatching {
    func dispatch(_ event: DaemonEvent) throws
    func retryTimedOut(timeoutSeconds: TimeInterval) throws
    func markDone(id: String) throws
}
