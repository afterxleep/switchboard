import Foundation

public final class ReviewThreadResolver: ReviewThreadResolving {
    private let token: String
    private let urlSession: URLSession

    public init(token: String, urlSession: URLSession? = nil) {
        self.token = token
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    public func resolve(threadNodeId: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "query": """
                mutation { resolveReviewThread(input: {threadId: \"\(threadNodeId)\"}) { thread { isResolved } } }
                """,
            ]
        )

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ReviewThreadResolverError.requestFailed(threadNodeId: threadNodeId)
        }
    }
}

public enum ReviewThreadResolverError: LocalizedError, Equatable {
    case requestFailed(threadNodeId: String)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(threadNodeId):
            return "Failed to resolve review thread \(threadNodeId)"
        }
    }
}
