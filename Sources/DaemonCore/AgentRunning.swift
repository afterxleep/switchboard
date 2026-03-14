import Foundation

public protocol AgentRunning {
    func run(event: DaemonEvent, config: DaemonConfig) async -> AgentResult
}

public struct AgentResult {
    public let success: Bool
    public let tokensUsed: Int
    public let error: String?

    public init(success: Bool, tokensUsed: Int, error: String?) {
        self.success = success
        self.tokensUsed = tokensUsed
        self.error = error
    }
}
