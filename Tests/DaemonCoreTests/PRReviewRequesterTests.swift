import XCTest
@testable import DaemonCore

final class PRReviewRequesterTests: XCTestCase {
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

    func test_requestReview_sendsReviewerPayload() async throws {
        let requester = makeRequester()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/afterxleep/flowdeck/pulls/145/requested_reviewers")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("\"reviewers\":[\"kai\"]"))
            return Self.response(body: #"{"requested_reviewers":[]}"#)
        }

        try await requester.requestReview(pr: 145, reviewer: "kai")
    }

    func test_requestReview_whenHTTPError_throwsContextualError() async {
        let requester = makeRequester()
        MockURLProtocol.requestHandler = { _ in
            Self.response(body: "{}", statusCode: 422)
        }

        await XCTAssertThrowsErrorAsync(try await requester.requestReview(pr: 145, reviewer: "kai")) { error in
            XCTAssertEqual(
                error as? PRReviewRequesterError,
                .httpError(path: "/repos/afterxleep/flowdeck/pulls/145/requested_reviewers", statusCode: 422)
            )
        }
    }

    private func makeRequester() -> PRReviewRequester {
        PRReviewRequester(
            token: "github-token",
            repo: "afterxleep/flowdeck",
            urlSession: session
        )
    }

    private static func response(body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/afterxleep/flowdeck/pulls/145/requested_reviewers")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
