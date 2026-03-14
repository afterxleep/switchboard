import XCTest
@testable import DaemonCore

final class StateStoreLifecycleTests: XCTestCase {
    func test_entryForPR_whenUnknownPR_returnsNil() throws {
        let store = makeStore()
        try store.save([:])
        XCTAssertNil(store.entry(forPR: 99))
    }

    func test_attachPR_setsPRNumberAndCanBeLookedUp() throws {
        let store = makeStore()
        let entry = StateEntry(id: "linear:DB-196", status: .pending, eventType: "new_issue", details: "DB-196: Add lifecycle", startedAt: nil, updatedAt: Date())
        try store.save([entry.id: entry])

        try store.attachPR(id: entry.id, prNumber: 145, threadPath: "/tmp/thread.jsonl")

        XCTAssertEqual(store.entry(forPR: 145)?.threadPath, "/tmp/thread.jsonl")
    }

    func test_updatePhase_preservesOtherFields() throws {
        let store = makeStore()
        let entry = StateEntry(id: "linear:DB-196", status: .pending, eventType: "new_issue", details: "DB-196: Add lifecycle", startedAt: nil, updatedAt: Date(), sessionId: "thread-1", prNumber: 145)
        try store.save([entry.id: entry])

        try store.updatePhase(id: entry.id, phase: .waitingOnReview)

        let updated = try XCTUnwrap(try store.load()[entry.id])
        XCTAssertEqual(updated.agentPhase, .waitingOnReview)
        XCTAssertEqual(updated.sessionId, "thread-1")
        XCTAssertEqual(updated.prNumber, 145)
    }

    func test_allActive_excludesDoneEntries() throws {
        let store = makeStore()
        try store.save([
            "active": StateEntry(id: "active", status: .pending, eventType: "new_issue", details: "active", startedAt: nil, updatedAt: Date(), agentPhase: .coding),
            "done": StateEntry(id: "done", status: .done, eventType: "new_issue", details: "done", startedAt: nil, updatedAt: Date(), agentPhase: .done),
        ])

        XCTAssertEqual(store.allActive().map(\.id), ["active"])
    }

    private func makeStore() -> StateStore {
        let stateFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        return StateStore(stateFilePath: stateFileURL.path)
    }
}
