import XCTest
@testable import DaemonCore

final class GitHubPollerPREventsTests: XCTestCase {
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

    func test_poll_emitsPROpenedForNewKaiPR() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: #"[{"number":145,"title":"Add lifecycle","state":"open","merged_at":null,"head":{"ref":"kai/db-200-add-x","sha":"abc123"},"mergeable_state":"clean"}]"#,
            closedPRs: "[]",
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: "[]",
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        )

        let events = try await poller.poll(state: [:])

        XCTAssertEqual(events, [.prOpened(pr: 145, branch: "kai/db-200-add-x", title: "Add lifecycle")])
    }

    func test_poll_emitsPRMergedForTrackedPR() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let state = [
            "linear:DB-200": StateEntry(id: "linear:DB-200", status: .pending, eventType: "new_issue", details: "DB-200: Add lifecycle", startedAt: nil, updatedAt: Date(), prNumber: 145, agentPhase: .waitingOnReview),
        ]
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: "[]",
            closedPRs: #"[{"number":145,"title":"Add lifecycle","state":"closed","merged_at":"2026-03-14T12:00:00Z","head":{"ref":"kai/db-200-add-x","sha":"abc123"},"mergeable_state":"clean"}]"#,
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: "[]",
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        )

        let events = try await poller.poll(state: state)

        XCTAssertEqual(events, [.prMerged(pr: 145, branch: "kai/db-200-add-x")])
    }

    func test_poll_emitsCIPassedWhenAllChecksSucceed() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let state = [
            "linear:DB-200": StateEntry(id: "linear:DB-200", status: .pending, eventType: "new_issue", details: "DB-200: Add lifecycle", startedAt: nil, updatedAt: Date(), prNumber: 145, agentPhase: .waitingOnCI),
        ]
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: #"[{"number":145,"title":"Add lifecycle","state":"open","merged_at":null,"head":{"ref":"kai/db-200-add-x","sha":"abc123"},"mergeable_state":"clean"}]"#,
            closedPRs: "[]",
            checkRuns: #"{"check_runs":[{"name":"swift test","status":"completed","conclusion":"success"}]}"#,
            reviews: "[]",
            prComments: "[]",
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        )

        let events = try await poller.poll(state: state)

        XCTAssertTrue(events.contains(.ciPassed(pr: 145, branch: "kai/db-200-add-x")))
    }

    func test_poll_emitsPRClosedForClosedWithoutMerge() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let state = [
            "linear:DB-200": StateEntry(id: "linear:DB-200", status: .pending, eventType: "new_issue", details: "DB-200: Add lifecycle", startedAt: nil, updatedAt: Date(), prNumber: 145),
        ]
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: "[]",
            closedPRs: #"[{"number":145,"title":"Add lifecycle","state":"closed","merged_at":null,"head":{"ref":"kai/db-200-add-x","sha":"abc123"},"mergeable_state":"clean"}]"#,
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: "[]",
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        )

        let events = try await poller.poll(state: state)

        XCTAssertEqual(events, [.prClosed(pr: 145, branch: "kai/db-200-add-x")])
    }

    func test_poll_doesNotEmitDuplicatePROpenedForTrackedPR() async throws {
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        let state = [
            "linear:DB-200": StateEntry(id: "linear:DB-200", status: .pending, eventType: "new_issue", details: "DB-200: Add lifecycle", startedAt: nil, updatedAt: Date(), prNumber: 145),
        ]
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: #"[{"number":145,"title":"Add lifecycle","state":"open","merged_at":null,"head":{"ref":"kai/db-200-add-x","sha":"abc123"},"mergeable_state":"clean"}]"#,
            closedPRs: "[]",
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: "[]",
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        )

        let events = try await poller.poll(state: state)

        XCTAssertFalse(events.contains(.prOpened(pr: 145, branch: "kai/db-200-add-x", title: "Add lifecycle")))
    }

    func test_hasConflicts_whenPullRequestIsDirty_returnsTrue() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: #"[{"number":145,"title":"Add lifecycle","state":"open","merged_at":null,"head":{"ref":"kai/db-200-add-x","sha":"abc123"},"mergeable_state":"dirty"}]"#,
            closedPRs: "[]",
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: "[]",
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#
        )

        // Act
        let hasConflicts = try await poller.hasConflicts(prNumber: 145)

        // Assert
        XCTAssertTrue(hasConflicts)
    }

    func test_hasUnresolvedThreads_whenGraphQLIncludesOpenThread_returnsTrue() async throws {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = Self.makeHandler(
            openPRs: "[]",
            closedPRs: "[]",
            checkRuns: #"{"check_runs":[]}"#,
            reviews: "[]",
            prComments: #"[{"id":9001,"node_id":"PRRC_kwDOTest","body":"Please fix","created_at":"2026-03-14T12:00:00Z","user":{"login":"reviewer"}}]"#,
            issueComments: "[]",
            threads: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread-1","isResolved":false,"path":"Sources/File.swift","comments":{"nodes":[{"databaseId":9001,"body":"Please fix","author":{"login":"reviewer"}}]}}]}}}}}"#
        )

        // Act
        let hasThreads = try await poller.hasUnresolvedThreads(prNumber: 145)

        // Assert
        XCTAssertTrue(hasThreads)
    }

    func test_poll_whenGitHubReturnsHTTPError_throwsContextualError() async {
        // Arrange
        let poller = GitHubPoller(token: "github-token", repo: "afterxleep/flowdeck", urlSession: session)
        MockURLProtocol.requestHandler = { _ in
            Self.response(body: "{}", statusCode: 503)
        }

        // Act / Assert
        await XCTAssertThrowsErrorAsync(try await poller.poll(state: [:])) { error in
            XCTAssertEqual(
                error as? GitHubPollerError,
                .httpError(path: "/repos/afterxleep/flowdeck/pulls?state=open", statusCode: 503)
            )
        }
    }

    private static func makeHandler(
        openPRs: String,
        closedPRs: String,
        checkRuns: String,
        reviews: String,
        prComments: String,
        issueComments: String,
        threads: String
    ) -> ((URLRequest) throws -> (HTTPURLResponse, Data)) {
        { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls":
                let state = request.url?.query?.contains("state=closed") == true ? closedPRs : openPRs
                return Self.response(body: state)
            case "/repos/afterxleep/flowdeck/commits/abc123/check-runs":
                return Self.response(body: checkRuns)
            case "/repos/afterxleep/flowdeck/pulls/145/reviews":
                return Self.response(body: reviews)
            case "/repos/afterxleep/flowdeck/pulls/145/comments":
                return Self.response(body: prComments)
            case "/repos/afterxleep/flowdeck/issues/145/comments":
                return Self.response(body: issueComments)
            case "/graphql":
                return Self.response(body: threads)
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return Self.response(body: "[]", statusCode: 404)
            }
        }
    }

    private static func response(body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
