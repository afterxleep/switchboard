import Foundation
@testable import DaemonCore

final class MockAgentRunner: AgentRunning {
    var receivedEvents: [DaemonEvent] = []
    var receivedConfigs: [DaemonConfig] = []
    var stubbedResult = AgentResult(success: true, tokensUsed: 0, error: nil, threadId: nil, threadPath: nil)

    func run(event: DaemonEvent, config: DaemonConfig) async -> AgentResult {
        receivedEvents.append(event)
        receivedConfigs.append(config)
        return stubbedResult
    }
}
