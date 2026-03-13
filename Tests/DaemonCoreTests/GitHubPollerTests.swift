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

    // MARK: - CI Failure

    func test_poll_whenStatusChecksFail_returnsCiFailureEvent() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = Self.makeHandler(
            prs: Self.singlePR,
            checkRuns: """
            {"check_runs":[
              {"name":"ci / unit-tests","conclusion":"failure"},
              {"name":"lint","conclusion":"success"}
            ]}
            """,
            reviews: "[]", prComments: "[]", issueComments: "[]"
        )

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.ciFailure(pr: 42, branch: "feature/db-191", failedChecks: ["ci / unit-tests"])])
    }

    // MARK: - Approved

    func test_poll_whenApprovedReviewExists_returnsApprovedEvent() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = Self.makeHandler(
            prs: Self.singlePR,
            checkRuns: #"{"check_runs":[]}"#,
            reviews: #"[{"state":"APPROVED"}]"#,
            prComments: "[]", issueComments: "[]"
        )

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.approved(pr: 42, branch: "feature/db-191")])
    }

    // MARK: - Review Comments

    func test_poll_whenCommentsAreOlderThanLastPoll_skipsReviewCommentEvents() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let lastPolledKey = "gh:afterxleep/flowdeck:pr:42:last_polled"
        let state = [
            lastPolledKey: StateEntry(id: lastPolledKey, status: .pending, eventType: "last_polled",
                                      details: "ts", startedAt: nil,
                                      updatedAt: Date(timeIntervalSince1970: 1_700_000_500))
        ]
        MockURLProtocol.requestHandler = Self.makeHandler(
            prs: Self.singlePR,
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: """
            [{"body":"Looks good","created_at":"2023-11-14T22:21:39Z","user":{"login":"kai"}}]
            """,
            issueComments: "[]"
        )

        let events = try await poller.poll(state: state)

        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Conflict

    func test_poll_whenPrHasConflicts_returnsConflictEvent() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = Self.makeHandler(
            prs: """
            [{"number":42,"head":{"ref":"feature/db-191","sha":"abc123"},
              "mergeable":false,"mergeable_state":"dirty"}]
            """,
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]", prComments: "[]", issueComments: "[]"
        )

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.conflict(pr: 42, branch: "feature/db-191")])
    }

    // MARK: - Skip inFlight/done

    func test_poll_skipsEventsAlreadyMarkedInFlightOrDone() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let state: [String: StateEntry] = [
            "gh:pr:42:ci_failure": StateEntry(id: "gh:pr:42:ci_failure", status: .inFlight,
                                               eventType: "ci_failure", details: "existing",
                                               startedAt: Date(), updatedAt: Date()),
            "gh:pr:42:approved": StateEntry(id: "gh:pr:42:approved", status: .done,
                                             eventType: "approved", details: "existing",
                                             startedAt: Date(), updatedAt: Date()),
        ]
        MockURLProtocol.requestHandler = Self.makeHandler(
            prs: Self.singlePR,
            checkRuns: #"{"check_runs":[{"name":"ci / unit-tests","conclusion":"failure"}]}"#,
            reviews: #"[{"state":"APPROVED"}]"#,
            prComments: "[]", issueComments: "[]"
        )

        let events = try await poller.poll(state: state)

        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Helpers

    private static let singlePR = """
    [{"number":42,"head":{"ref":"feature/db-191","sha":"abc123"},
      "mergeable":true,"mergeable_state":"clean"}]
    """

    private static func makeHandler(
        prs: String,
        checkRuns: String,
        reviews: String,
        prComments: String,
        issueComments: String
    ) -> ((URLRequest) throws -> (HTTPURLResponse, Data)) {
        return { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                return Self.makeResponse(body: prs)
            case "/repos/afterxleep/flowdeck/commits/abc123/check-runs":
                return Self.makeResponse(body: checkRuns)
            case "/repos/afterxleep/flowdeck/pulls/42/reviews":
                return Self.makeResponse(body: reviews)
            case "/repos/afterxleep/flowdeck/pulls/42/comments":
                return Self.makeResponse(body: prComments)
            case "/repos/afterxleep/flowdeck/issues/42/comments":
                return Self.makeResponse(body: issueComments)
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.makeResponse(body: "[]", statusCode: 404)
            }
        }
    }

    private static func makeResponse(body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: statusCode, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
