import XCTest
@testable import DaemonCore

final class LinearStateManagerTests: XCTestCase {
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

    func test_moveToInProgress_sendsCorrectMutation() async throws {
        let manager = makeManager()
        MockURLProtocol.requestHandler = { request in
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("\"issueId\":\"issue-1\""))
            XCTAssertTrue(body.contains("\"stateId\":\"in-progress\""))
            return Self.response(body: #"{"data":{"issueUpdate":{"success":true}}}"#)
        }

        try await manager.moveToInProgress(issueId: "issue-1")
    }

    func test_moveToInReview_sendsCorrectMutation() async throws {
        let manager = makeManager()
        MockURLProtocol.requestHandler = { request in
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("\"stateId\":\"in-review\""))
            return Self.response(body: #"{"data":{"issueUpdate":{"success":true}}}"#)
        }

        try await manager.moveToInReview(issueId: "issue-1")
    }

    func test_moveToDone_sendsCorrectMutation() async throws {
        let manager = makeManager()
        MockURLProtocol.requestHandler = { request in
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("\"stateId\":\"done\""))
            return Self.response(body: #"{"data":{"issueUpdate":{"success":true}}}"#)
        }

        try await manager.moveToDone(issueId: "issue-1")
    }

    func test_moveToDone_whenHTTPError_throws() async {
        let manager = makeManager()
        MockURLProtocol.requestHandler = { _ in
            Self.response(body: "{}", statusCode: 500)
        }

        await XCTAssertThrowsErrorAsync(try await manager.moveToDone(issueId: "issue-1")) { error in
            XCTAssertEqual(error as? LinearStateManagerError, .httpError(statusCode: 500))
        }
    }

    private func makeManager() -> LinearStateManager {
        LinearStateManager(
            apiKey: "linear-token",
            inProgressStateId: "in-progress",
            inReviewStateId: "in-review",
            doneStateId: "done",
            urlSession: session
        )
    }

    private static func response(body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.linear.app/graphql")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
