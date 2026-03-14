import XCTest
@testable import DaemonCore

final class PRMergerTests: XCTestCase {
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

    func test_isMergeable_whenAllConditionsPass_returnsMergeableState() async throws {
        let merger = makeMerger()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls/145":
                return Self.response(body: #"{"merged":false,"mergeable":true,"head":{"sha":"abc123"}}"#, url: request.url!)
            case "/repos/afterxleep/flowdeck/pulls/145/reviews":
                return Self.response(body: #"[{"state":"APPROVED"}]"#, url: request.url!)
            case "/repos/afterxleep/flowdeck/commits/abc123/check-runs":
                return Self.response(body: #"{"check_runs":[{"status":"completed","conclusion":"success"}]}"#, url: request.url!)
            case "/graphql":
                return Self.response(body: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true}]}}}}}"#, url: request.url!)
            default:
                XCTFail("Unexpected path \(request.url?.path ?? "nil")")
                return Self.response(body: "{}", url: request.url!)
            }
        }

        let mergeability = try await merger.isMergeable(pr: 145)

        XCTAssertEqual(
            mergeability,
            PRMergeability(approved: true, ciGreen: true, noOpenThreads: true, noConflicts: true)
        )
        XCTAssertTrue(mergeability.canMerge)
    }

    func test_isMergeable_whenChecksPending_returnsNonMergeableState() async throws {
        let merger = makeMerger()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/repos/afterxleep/flowdeck/pulls/145":
                return Self.response(body: #"{"merged":false,"mergeable":true,"head":{"sha":"abc123"}}"#, url: request.url!)
            case "/repos/afterxleep/flowdeck/pulls/145/reviews":
                return Self.response(body: #"[{"state":"APPROVED"}]"#, url: request.url!)
            case "/repos/afterxleep/flowdeck/commits/abc123/check-runs":
                return Self.response(body: #"{"check_runs":[{"status":"queued","conclusion":null}]}"#, url: request.url!)
            case "/graphql":
                return Self.response(body: #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#, url: request.url!)
            default:
                XCTFail("Unexpected path \(request.url?.path ?? "nil")")
                return Self.response(body: "{}", url: request.url!)
            }
        }

        let mergeability = try await merger.isMergeable(pr: 145)

        XCTAssertFalse(mergeability.ciGreen)
        XCTAssertFalse(mergeability.canMerge)
    }

    func test_merge_sendsSquashPayload() async throws {
        let merger = makeMerger()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/repos/afterxleep/flowdeck/pulls/145/merge")
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("\"merge_method\":\"squash\""))
            XCTAssertTrue(body.contains("\"commit_title\":\"DB-200: Add X\""))
            return Self.response(body: #"{"merged":true}"#, url: request.url!)
        }

        try await merger.merge(pr: 145, commitMessage: "DB-200: Add X")
    }

    func test_merge_whenHTTPError_throwsContextualError() async {
        let merger = makeMerger()
        MockURLProtocol.requestHandler = { request in
            Self.response(body: "{}", statusCode: 409, url: request.url!)
        }

        await XCTAssertThrowsErrorAsync(try await merger.merge(pr: 145, commitMessage: "DB-200: Add X")) { error in
            XCTAssertEqual(
                error as? PRMergerError,
                .httpError(path: "/repos/afterxleep/flowdeck/pulls/145/merge", statusCode: 409)
            )
        }
    }

    private func makeMerger() -> PRMerger {
        PRMerger(
            token: "github-token",
            repo: "afterxleep/flowdeck",
            urlSession: session
        )
    }

    private static func response(body: String, statusCode: Int = 200, url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
