import XCTest
@testable import DaemonCore

final class CodexAppServerClientTests: XCTestCase {
    func test_run_whenTurnCompletes_returnsTrueAndAutoApprovesTools() async {
        // Arrange
        let transport = MockTransport(
            messages: [
                ["id": 1, "result": [:]],
                ["method": "initialized"],
                ["id": 2, "result": ["thread_id": "thread-1"]],
                ["id": 3, "result": [:]],
                ["id": 99, "method": "item/tool/approvalRequest", "params": [:]],
                ["method": "turn/completed", "params": ["usage": ["total_tokens": 321]]],
            ]
        )
        let client = CodexAppServerClient(codexPath: "/opt/homebrew/bin/codex") {
            transport
        }

        // Act
        let succeeded = await client.run(
            workspace: "/tmp/workspace",
            prompt: "Solve the issue",
            title: "DB-196: Expand daemon",
            onEvent: { _ in },
            turnTimeoutSeconds: 60,
            stallTimeoutSeconds: 60
        )

        // Assert
        XCTAssertTrue(succeeded)
        XCTAssertEqual(client.lastThreadId, "thread-1")
        XCTAssertEqual(client.lastProcessIdentifier, 1234)
        XCTAssertEqual(client.lastTokensUsed, 321)
        XCTAssertEqual(transport.launchCallCount, 1)
        XCTAssertEqual(transport.sentPayloads.count, 4)
        XCTAssertEqual(transport.sentPayloads[3]["id"] as? Int, 99)
    }

    func test_run_whenTurnFails_returnsFalse() async {
        // Arrange
        let transport = MockTransport(
            messages: [
                ["id": 1, "result": [:]],
                ["method": "initialized"],
                ["id": 2, "result": ["thread_id": "thread-2"]],
                ["method": "turn/failed", "params": [:]],
            ]
        )
        let client = CodexAppServerClient(codexPath: "/opt/homebrew/bin/codex") {
            transport
        }

        // Act
        let succeeded = await client.run(
            workspace: "/tmp/workspace",
            prompt: "Solve the issue",
            title: "DB-196: Expand daemon",
            onEvent: { _ in },
            turnTimeoutSeconds: 60,
            stallTimeoutSeconds: 60
        )

        // Assert
        XCTAssertFalse(succeeded)
        XCTAssertEqual(client.lastError, "turn/failed")
    }
}

private final class MockTransport: CodexAppServerClient.Transporting {
    let processIdentifier: Int? = 1234
    private var messages: [CodexAppServerClient.Message]

    var launchCallCount = 0
    var sentPayloads: [[String: Any]] = []

    init(messages: [[String: Any]]) {
        self.messages = messages.map { CodexAppServerClient.Message(raw: $0) }
    }

    func launch(codexPath: String, workspace: String) throws {
        launchCallCount += 1
    }

    func send(_ payload: [String: Any]) throws {
        sentPayloads.append(payload)
    }

    func nextMessage() async throws -> CodexAppServerClient.Message? {
        guard messages.isEmpty == false else {
            return nil
        }
        return messages.removeFirst()
    }

    func terminate() {}
}
