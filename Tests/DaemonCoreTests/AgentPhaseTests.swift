import XCTest
@testable import DaemonCore

final class AgentPhaseTests: XCTestCase {
    func test_agentPhase_codableRoundTrip() throws {
        let data = try JSONEncoder().encode(AgentPhase.waitingOnReview)
        let decoded = try JSONDecoder().decode(AgentPhase.self, from: data)
        XCTAssertEqual(decoded, .waitingOnReview)
    }

    func test_agentPhase_allLifecycleCasesExist() {
        XCTAssertEqual(
            [
                AgentPhase.coding,
                .waitingOnCI,
                .waitingOnReview,
                .addressingFeedback,
                .ciBlocked,
                .merged,
                .done,
            ].map(\.rawValue),
            ["coding", "waitingOnCI", "waitingOnReview", "addressingFeedback", "ciBlocked", "merged", "done"]
        )
    }
}
