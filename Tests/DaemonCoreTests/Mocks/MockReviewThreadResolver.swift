import Foundation
@testable import DaemonCore

final class MockReviewThreadResolver: ReviewThreadResolving {
    enum MockError: Error {
        case forced
    }

    var receivedThreadNodeIds: [String] = []
    var stubbedErrorSequence: [Error?] = []

    func resolve(threadNodeId: String) async throws {
        receivedThreadNodeIds.append(threadNodeId)

        if stubbedErrorSequence.isEmpty == false {
            let nextError = stubbedErrorSequence.removeFirst()
            if let nextError {
                throw nextError
            }
        }
    }

    func reset() {
        receivedThreadNodeIds.removeAll()
        stubbedErrorSequence.removeAll()
    }
}
