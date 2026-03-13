import XCTest
@testable import DaemonCore

final class LinearPollerTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func test_poll_whenUnknownActiveIssueExists_returnsNewIssueEvent() async throws {
        // Arrange
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "linear-token")
            let body = try XCTUnwrap(request.httpBody)
            let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyText.contains("\"teamSlug\":\"DB\""))

            return Self.makeResponse(
                body: """
                {
                  "data": {
                    "issues": {
                      "nodes": [
                        {
                          "id": "issue-1",
                          "identifier": "DB-190",
                          "title": "Fix daemon",
                          "description": "Handle wakeups",
                          "state": { "name": "Todo" }
                        }
                      ]
                    }
                  }
                }
                """
            )
        }

        // Act
        let events = try await poller.poll(knownIds: [])

        // Assert
        XCTAssertEqual(
            events,
            [
                .newIssue(
                    id: "issue-1",
                    identifier: "DB-190",
                    title: "Fix daemon",
                    description: "Handle wakeups"
                )
            ]
        )
    }

    func test_poll_whenKnownIssueMovesToTerminalState_returnsIssueCancelledEvent() async throws {
        // Arrange
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(
                body: """
                {
                  "data": {
                    "issues": {
                      "nodes": [
                        {
                          "id": "issue-1",
                          "identifier": "DB-190",
                          "title": "Fix daemon",
                          "description": null,
                          "state": { "name": "CANCELLED" }
                        }
                      ]
                    }
                  }
                }
                """
            )
        }

        // Act
        let events = try await poller.poll(knownIds: ["issue-1"])

        // Assert
        XCTAssertEqual(events, [.issueCancelled(id: "issue-1", identifier: "DB-190")])
    }

    func test_poll_whenIssueAlreadyKnownInActiveState_skipsDuplicateNewIssueEvent() async throws {
        // Arrange
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(
                body: """
                {
                  "data": {
                    "issues": {
                      "nodes": [
                        {
                          "id": "issue-1",
                          "identifier": "DB-190",
                          "title": "Fix daemon",
                          "description": null,
                          "state": { "name": "in progress" }
                        }
                      ]
                    }
                  }
                }
                """
            )
        }

        // Act
        let events = try await poller.poll(knownIds: ["issue-1"])

        // Assert
        XCTAssertTrue(events.isEmpty)
    }

    func test_poll_normalizesStateNamesWhenMatchingConfiguredStates() async throws {
        // Arrange
        let poller = LinearPoller(
            apiKey: "linear-token",
            teamSlug: "DB",
            activeStates: ["todo"],
            terminalStates: ["canceled"],
            urlSession: session
        )
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(
                body: """
                {
                  "data": {
                    "issues": {
                      "nodes": [
                        {
                          "id": "issue-active",
                          "identifier": "DB-191",
                          "title": "Case normalization",
                          "description": null,
                          "state": { "name": "TODO" }
                        },
                        {
                          "id": "issue-terminal",
                          "identifier": "DB-192",
                          "title": "Cancelled item",
                          "description": null,
                          "state": { "name": "CANCELED" }
                        }
                      ]
                    }
                  }
                }
                """
            )
        }

        // Act
        let events = try await poller.poll(knownIds: ["issue-terminal"])

        // Assert
        XCTAssertEqual(
            events,
            [
                .newIssue(
                    id: "issue-active",
                    identifier: "DB-191",
                    title: "Case normalization",
                    description: nil
                ),
                .issueCancelled(id: "issue-terminal", identifier: "DB-192"),
            ]
        )
    }

    private static func makeResponse(body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.linear.app/graphql")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
