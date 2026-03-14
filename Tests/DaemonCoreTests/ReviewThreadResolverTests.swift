import XCTest
@testable import DaemonCore

final class ReviewThreadResolverTests: XCTestCase {
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

    func test_reviewThreadResolver_sendsCorrectGraphQLMutation() async throws {
        let resolver = ReviewThreadResolver(token: "github-token", urlSession: session)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/graphql")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "bearer github-token")
            let body = try XCTUnwrap(request.httpBody)
            let bodyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            let query = try XCTUnwrap(bodyObject["query"])
            XCTAssertTrue(query.contains("resolveReviewThread"))
            XCTAssertTrue(query.contains("threadId"))
            XCTAssertTrue(query.contains("PRT_kwDOThread1"))
            return Self.response(body: #"{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}"#)
        }

        try await resolver.resolve(threadNodeId: "PRT_kwDOThread1")
    }

    private static func response(body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/graphql")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
