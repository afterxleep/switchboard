import Foundation

public protocol StateStoring {
    var stateFilePath: String { get }

    func load() throws -> [String: StateEntry]
    func save(_ state: [String: StateEntry]) throws
    func upsert(_ entry: StateEntry) throws
    func markInFlight(id: String) throws
    func markDone(id: String) throws
    func markPending(id: String) throws
    func updateMetadata(
        id: String,
        sessionId: String?,
        agentPid: Int?,
        tokensUsed: Int?
    ) throws
    func updateThread(
        id: String,
        sessionId: String?,
        threadPath: String?
    ) throws
    func updateLinearIssueId(id: String, linearIssueId: String) throws
    func entry(forPR prNumber: Int) -> StateEntry?
    func attachPR(id: String, prNumber: Int, title: String?, threadPath: String?) throws
    func clearPR(id: String) throws
    func updatePhase(id: String, phase: AgentPhase) throws
    func markTurnStarted(id: String) throws
    func incrementRetry(id: String) throws
    func resetRetry(id: String) throws
    func incrementConsecutiveCIFailures(id: String) throws -> Int
    func resetConsecutiveCIFailures(id: String) throws
    func allActive() -> [StateEntry]
    func isInFlight(id: String) -> Bool
    func timedOut(id: String, after timeoutSeconds: TimeInterval) -> Bool
    func cleanup() throws
}
