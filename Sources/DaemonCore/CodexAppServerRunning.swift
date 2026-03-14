import Foundation

public protocol CodexAppServerRunning {
    var lastThreadId: String? { get }
    var lastThreadPath: String? { get }
    var lastProcessIdentifier: Int? { get }
    var lastTokensUsed: Int { get }
    var lastError: String? { get }

    func run(
        workspace: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval
    ) async -> Bool

    func resume(
        workspace: String,
        threadId: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval
    ) async -> Bool
}
