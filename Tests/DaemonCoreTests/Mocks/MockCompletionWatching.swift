import Foundation
@testable import DaemonCore

final class MockCompletionWatching: CompletionWatching {
    var checkCallCount = 0
    var stubbedAction: ((EventDispatching) throws -> Void)?

    func checkAndProcess(dispatcher: EventDispatching) throws {
        checkCallCount += 1
        try stubbedAction?(dispatcher)
    }

    func reset() {
        checkCallCount = 0
        stubbedAction = nil
    }
}
