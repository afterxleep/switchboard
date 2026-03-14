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
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "linear-token")
            let body = try XCTUnwrap(request.httpBody)
            let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyText.contains("\"teamSlug\":\"DB\""))
            return Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": "Handle wakeups",
                "state": { "name": "Todo" }
              }] } }
            }
            """)
        }

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.newIssue(id: "issue-1", identifier: "DB-190",
                                          title: "Fix daemon", description: "Handle wakeups")])
    }

    func test_poll_whenKnownIssueMovesToTerminalState_returnsIssueCancelledEvent() async throws {
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": null,
                "state": { "name": "CANCELLED" }
              }] } }
            }
            """)
        }

        // Issue is known (pending) and now terminal — should emit issueCancelled
        let state = Self.makeState(id: "linear:DB-190", status: .pending)
        let events = try await poller.poll(state: state)

        XCTAssertEqual(events, [.issueCancelled(id: "issue-1", identifier: "DB-190")])
    }

    func test_poll_whenIssueIsPendingInActiveState_requeuesNewIssueEvent() async throws {
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": null,
                "state": { "name": "in progress" }
              }] } }
            }
            """)
        }

        // Pending issues are eligible for re-queue after reconcile.
        let state = Self.makeState(id: "linear:DB-190", status: .pending)
        let events = try await poller.poll(state: state)

        XCTAssertEqual(
            events,
            [.newIssue(id: "issue-1", identifier: "DB-190", title: "Fix daemon", description: nil)]
        )
    }

    func test_poll_whenIssueIsAlreadyInFlight_skipsEvent() async throws {
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": null,
                "state": { "name": "Todo" }
              }] } }
            }
            """)
        }

        let state = Self.makeState(id: "linear:DB-190", status: .inFlight)
        let events = try await poller.poll(state: state)

        XCTAssertTrue(events.isEmpty)
    }

    func test_poll_whenIssueIsDone_skipsEvent() async throws {
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": null,
                "state": { "name": "CANCELLED" }
              }] } }
            }
            """)
        }

        let state = Self.makeState(id: "linear:DB-190", status: .done)
        let events = try await poller.poll(state: state)

        XCTAssertTrue(events.isEmpty)
    }

    func test_poll_normalizesStateNamesWhenMatchingConfiguredStates() async throws {
        let poller = LinearPoller(
            apiKey: "linear-token", teamSlug: "DB",
            activeStates: ["todo"], terminalStates: ["canceled"],
            urlSession: session
        )
        MockURLProtocol.requestHandler = { _ in
            Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [
                { "id": "issue-active", "identifier": "DB-191", "title": "Case normalization",
                  "description": null, "state": { "name": "TODO" } },
                { "id": "issue-terminal", "identifier": "DB-192", "title": "Cancelled item",
                  "description": null, "state": { "name": "CANCELED" } }
              ] } }
            }
            """)
        }

        // DB-192 is known (pending) and now terminal
        let state = Self.makeState(id: "linear:DB-192", status: .pending)
        let events = try await poller.poll(state: state)

        XCTAssertEqual(events, [
            .newIssue(id: "issue-active", identifier: "DB-191", title: "Case normalization", description: nil),
            .issueCancelled(id: "issue-terminal", identifier: "DB-192"),
        ])
    }

    func test_linearPoller_whenAssigneeIdSet_filtersIssuesByAssignee() async throws {
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", assigneeId: "agent-123", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.httpBody)
            let bodyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(bodyObject["query"] as? String)
            let variables = try XCTUnwrap(bodyObject["variables"] as? [String: String])
            XCTAssertTrue(query.contains("assignee: { id: { eq: $assigneeId } }"))
            XCTAssertTrue(query.contains("state: { type: { in: [\"unstarted\", \"started\"] } }"))
            XCTAssertEqual(variables["teamSlug"], "DB")
            XCTAssertEqual(variables["assigneeId"], "agent-123")
            return Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": null,
                "state": { "name": "Todo" }
              }] } }
            }
            """)
        }

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.newIssue(id: "issue-1", identifier: "DB-190", title: "Fix daemon", description: nil)])
    }

    func test_linearPoller_whenAssigneeIdEmpty_returnsAllIssues() async throws {
        let poller = LinearPoller(apiKey: "linear-token", teamSlug: "DB", assigneeId: "", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.httpBody)
            let bodyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(bodyObject["query"] as? String)
            let variables = try XCTUnwrap(bodyObject["variables"] as? [String: String])
            XCTAssertFalse(query.contains("assignee: { id: { eq: $assigneeId } }"))
            XCTAssertEqual(variables, ["teamSlug": "DB"])
            return Self.makeResponse(body: """
            {
              "data": { "issues": { "nodes": [{
                "id": "issue-1", "identifier": "DB-190",
                "title": "Fix daemon", "description": null,
                "state": { "name": "Todo" }
              }] } }
            }
            """)
        }

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.newIssue(id: "issue-1", identifier: "DB-190", title: "Fix daemon", description: nil)])
    }

    // MARK: - Helpers

    private static func makeState(id: String, status: ItemStatus) -> [String: StateEntry] {
        [id: StateEntry(id: id, status: status, eventType: "new_issue",
                        details: "test", startedAt: nil, updatedAt: Date())]
    }

    private static func makeResponse(body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.linear.app/graphql")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
