import XCTest
@testable import DaemonCore

final class GitHubPollerTests: XCTestCase {
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

    func test_poll_whenStatusChecksFail_returnsCiFailureEvent() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                return Self.makeResponse(
                    body: """
                    [
                      {
                        "number": 42,
                        "head": { "ref": "feature/db-191", "sha": "abc123" },
                        "mergeable": "MERGEABLE"
                      }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/statuses/abc123":
                return Self.makeResponse(
                    body: """
                    [
                      { "state": "failure", "context": "ci / unit-tests" },
                      { "state": "success", "context": "lint" }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/pulls/42/reviews":
                return Self.makeResponse(body: "[]")
            case "/repos/afterxleep/flowdeck/pulls/42/comments":
                return Self.makeResponse(body: "[]")
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.makeResponse(body: "[]", statusCode: 404)
            }
        }

        // Act
        let events = try await poller.poll(state: [:])

        // Assert
        XCTAssertEqual(events, [.ciFailure(pr: 42, branch: "feature/db-191", failedChecks: ["ci / unit-tests"])])
    }

    func test_poll_whenApprovedReviewExists_returnsApprovedEvent() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                return Self.makeResponse(
                    body: """
                    [
                      {
                        "number": 42,
                        "head": { "ref": "feature/db-191", "sha": "abc123" },
                        "mergeable": "MERGEABLE"
                      }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/statuses/abc123":
                return Self.makeResponse(body: "[]")
            case "/repos/afterxleep/flowdeck/pulls/42/reviews":
                return Self.makeResponse(
                    body: """
                    [
                      { "state": "APPROVED" }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/pulls/42/comments":
                return Self.makeResponse(body: "[]")
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.makeResponse(body: "[]", statusCode: 404)
            }
        }

        // Act
        let events = try await poller.poll(state: [:])

        // Assert
        XCTAssertEqual(events, [.approved(pr: 42, branch: "feature/db-191")])
    }

    func test_poll_whenCommentsAreOlderThanLastPoll_skipsReviewCommentEvents() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let lastPolledKey = "gh:afterxleep/flowdeck:pr:42:last_polled"
        let state = [
            lastPolledKey: StateEntry(
                id: lastPolledKey,
                status: .pending,
                eventType: "last_polled",
                details: "timestamp",
                startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        ]
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                return Self.makeResponse(
                    body: """
                    [
                      {
                        "number": 42,
                        "head": { "ref": "feature/db-191", "sha": "abc123" },
                        "mergeable": "MERGEABLE"
                      }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/statuses/abc123":
                return Self.makeResponse(body: "[]")
            case "/repos/afterxleep/flowdeck/pulls/42/reviews":
                return Self.makeResponse(body: "[]")
            case "/repos/afterxleep/flowdeck/pulls/42/comments":
                return Self.makeResponse(
                    body: """
                    [
                      {
                        "body": "Looks good",
                        "created_at": "2023-11-14T22:21:39Z",
                        "user": { "login": "kai" }
                      }
                    ]
                    """
                )
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.makeResponse(body: "[]", statusCode: 404)
            }
        }

        // Act
        let events = try await poller.poll(state: state)

        // Assert
        XCTAssertTrue(events.isEmpty)
    }

    func test_poll_whenPrHasConflicts_returnsConflictEvent() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                return Self.makeResponse(
                    body: """
                    [
                      {
                        "number": 42,
                        "head": { "ref": "feature/db-191", "sha": "abc123" },
                        "mergeable": "CONFLICTING"
                      }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/statuses/abc123":
                return Self.makeResponse(body: "[]")
            case "/repos/afterxleep/flowdeck/pulls/42/reviews":
                return Self.makeResponse(body: "[]")
            case "/repos/afterxleep/flowdeck/pulls/42/comments":
                return Self.makeResponse(body: "[]")
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.makeResponse(body: "[]", statusCode: 404)
            }
        }

        // Act
        let events = try await poller.poll(state: [:])

        // Assert
        XCTAssertEqual(events, [.conflict(pr: 42, branch: "feature/db-191")])
    }

    func test_poll_skipsEventsAlreadyMarkedInFlightOrDone() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let state = [
            "gh:pr:42:ci_failure": StateEntry(
                id: "gh:pr:42:ci_failure",
                status: .inFlight,
                eventType: "ci_failure",
                details: "existing",
                startedAt: Date(),
                updatedAt: Date()
            ),
            "gh:pr:42:approved": StateEntry(
                id: "gh:pr:42:approved",
                status: .done,
                eventType: "approved",
                details: "existing",
                startedAt: Date(),
                updatedAt: Date()
            ),
        ]
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                return Self.makeResponse(
                    body: """
                    [
                      {
                        "number": 42,
                        "head": { "ref": "feature/db-191", "sha": "abc123" },
                        "mergeable": "MERGEABLE"
                      }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/statuses/abc123":
                return Self.makeResponse(
                    body: """
                    [
                      { "state": "failure", "context": "ci / unit-tests" }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/pulls/42/reviews":
                return Self.makeResponse(
                    body: """
                    [
                      { "state": "APPROVED" }
                    ]
                    """
                )
            case "/repos/afterxleep/flowdeck/pulls/42/comments":
                return Self.makeResponse(body: "[]")
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.makeResponse(body: "[]", statusCode: 404)
            }
        }

        // Act
        let events = try await poller.poll(state: state)

        // Assert
        XCTAssertTrue(events.isEmpty)
    }

    private static func makeResponse(body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
