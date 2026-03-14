import Foundation

public protocol AgentRunning {
    func run(event: DaemonEvent, config: DaemonConfig) async -> AgentResult
}

public struct AgentResult {
    public let success: Bool
    public let tokensUsed: Int
    public let error: String?
    public let threadId: String?
    public let threadPath: String?

    public init(success: Bool, tokensUsed: Int, error: String?, threadId: String? = nil, threadPath: String? = nil) {
        self.success = success
        self.tokensUsed = tokensUsed
        self.error = error
        self.threadId = threadId
        self.threadPath = threadPath
    }
}
