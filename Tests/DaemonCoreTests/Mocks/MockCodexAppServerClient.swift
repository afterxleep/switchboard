import Foundation
@testable import DaemonCore

final class MockCodexAppServerClient: CodexAppServerRunning {
    var lastThreadId: String?
    var lastThreadPath: String?
    var lastProcessIdentifier: Int?
    var lastTokensUsed = 0
    var lastError: String?

    var receivedWorkspaces: [String] = []
    var receivedPrompts: [String] = []
    var receivedTitles: [String] = []
    var receivedResumeThreadIds: [String] = []
    var stubbedRunResult = true
    var stubbedResumeResult = true

    func run(
        workspace: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval
    ) async -> Bool {
        receivedWorkspaces.append(workspace)
        receivedPrompts.append(prompt)
        receivedTitles.append(title)
        return stubbedRunResult
    }

    func resume(
        workspace: String,
        threadId: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval
    ) async -> Bool {
        receivedWorkspaces.append(workspace)
        receivedPrompts.append(prompt)
        receivedTitles.append(title)
        receivedResumeThreadIds.append(threadId)
        return stubbedResumeResult
    }
}
