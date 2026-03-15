import XCTest
@testable import DaemonCore

final class AgentPhaseTests: XCTestCase {
    func test_agentPhase_codableRoundTrip() throws {
        let data = try JSONEncoder().encode(AgentPhase.waitingOnReview)
        let decoded = try JSONDecoder().decode(AgentPhase.self, from: data)
        XCTAssertEqual(decoded, .waitingOnReview)
    }

    func test_agentPhase_whenUnknownValue_decodesAsAddressingFeedback() throws {
        let decoded = try JSONDecoder().decode(AgentPhase.self, from: Data(#""ciBlockedForever""#.utf8))
        XCTAssertEqual(decoded, .addressingFeedback)
    }

    func test_stateEntry_whenAgentPhaseUnknownValue_decodesAsCoding() throws {
        let data = Data(
            """
            {
              "id": "linear:DB-999",
              "status": "pending",
              "eventType": "new_issue",
              "details": "DB-999",
              "updatedAt": 0,
              "agentPhase": "ciBlockedForever"
            }
            """.utf8
        )

        let entry = try JSONDecoder().decode(StateEntry.self, from: data)
        XCTAssertEqual(entry.agentPhase, .coding)
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
