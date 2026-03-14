import Foundation
@testable import DaemonCore

final class MockEventDispatching: EventDispatching {
    var receivedDispatchedEvents: [DaemonEvent] = []
    var receivedRetryTimeouts: [TimeInterval] = []
    var receivedMarkedDoneIds: [String] = []

    func dispatch(_ event: DaemonEvent) throws {
        receivedDispatchedEvents.append(event)
    }

    func retryTimedOut(timeoutSeconds: TimeInterval) throws {
        receivedRetryTimeouts.append(timeoutSeconds)
    }

    func markDone(id: String) throws {
        receivedMarkedDoneIds.append(id)
    }

    func reset() {
        receivedDispatchedEvents.removeAll()
        receivedRetryTimeouts.removeAll()
        receivedMarkedDoneIds.removeAll()
    }
}
