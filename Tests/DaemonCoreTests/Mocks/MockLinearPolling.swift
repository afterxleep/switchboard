import Foundation
@testable import DaemonCore

final class MockLinearPolling: LinearPolling {
    enum MockError: Error {
        case forced
    }

    var stubbedEvents: [DaemonEvent] = []
    var stubbedErrorSequence: [Error?] = []
    var receivedKnownIds: [Set<String>] = []
    var pollCallCount = 0

    func poll(knownIds: Set<String>) async throws -> [DaemonEvent] {
        receivedKnownIds.append(knownIds)
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
