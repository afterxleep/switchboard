import Foundation

public protocol LinearStateManaging {
    func moveToInProgress(issueId: String) async throws
    func moveToInReview(issueId: String) async throws
    func moveToDone(issueId: String) async throws
    func postComment(issueId: String, body: String) async throws
}

public final class LinearStateManager: LinearStateManaging {
    private let apiKey: String
    private let inProgressStateId: String
    private let inReviewStateId: String
    private let doneStateId: String
    private let urlSession: URLSession

    public init(
        apiKey: String,
        inProgressStateId: String,
        inReviewStateId: String,
        doneStateId: String,
        urlSession: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.inProgressStateId = inProgressStateId
        self.inReviewStateId = inReviewStateId
        self.doneStateId = doneStateId
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    public func moveToInProgress(issueId: String) async throws {
        try await update(issueId: issueId, stateId: inProgressStateId)
    }

    public func moveToInReview(issueId: String) async throws {
        try await update(issueId: issueId, stateId: inReviewStateId)
    }

    public func moveToDone(issueId: String) async throws {
        try await update(issueId: issueId, stateId: doneStateId)
    }

    public func postComment(issueId: String, body: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": """
            mutation CreateComment($issueId: String!, $body: String!) {
              commentCreate(input: { issueId: $issueId, body: $body }) {
                success
              }
            }
            """,
            "variables": ["issueId": issueId, "body": body],
        ])
        let (_, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw LinearStateManagerError.httpError(issueId: issueId, stateId: "comment", statusCode: http.statusCode)
        }
    }

    private func update(issueId: String, stateId: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": """
            mutation UpdateIssueState($issueId: String!, $stateId: String!) {
              issueUpdate(id: $issueId, input: { stateId: $stateId }) {
                success
              }
            }
            """,
            "variables": [
                "issueId": issueId,
                "stateId": stateId,
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LinearStateManagerError.requestFailed(
                issueId: issueId,
                stateId: stateId,
                details: String(describing: error)
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinearStateManagerError.invalidResponse(issueId: issueId, stateId: stateId)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LinearStateManagerError.httpError(
                issueId: issueId,
                stateId: stateId,
                statusCode: httpResponse.statusCode
            )
        }

        let payload: LinearIssueUpdateResponse
        do {
            payload = try JSONDecoder().decode(LinearIssueUpdateResponse.self, from: data)
        } catch {
            throw LinearStateManagerError.decodingFailed(
                issueId: issueId,
                stateId: stateId,
                details: String(describing: error)
            )
        }

        guard payload.data.issueUpdate.success else {
            throw LinearStateManagerError.updateFailed(issueId: issueId, stateId: stateId)
        }
    }
}

public enum LinearStateManagerError: LocalizedError, Equatable {
    case requestFailed(issueId: String, stateId: String, details: String)
    case invalidResponse(issueId: String, stateId: String)
    case httpError(issueId: String, stateId: String, statusCode: Int)
    case decodingFailed(issueId: String, stateId: String, details: String)
    case updateFailed(issueId: String, stateId: String)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(issueId, stateId, details):
            return "Linear issue update request failed for issue \(issueId) to state \(stateId): \(details)"
        case let .invalidResponse(issueId, stateId):
            return "Linear issue update returned a non-HTTP response for issue \(issueId) to state \(stateId)"
        case let .httpError(issueId, stateId, statusCode):
            return "Linear issue update failed for issue \(issueId) to state \(stateId) with status \(statusCode)"
        case let .decodingFailed(issueId, stateId, details):
            return "Linear issue update response could not be decoded for issue \(issueId) to state \(stateId): \(details)"
        case let .updateFailed(issueId, stateId):
            return "Linear issue update failed for issue \(issueId) to state \(stateId)"
        }
    }
}

private struct LinearIssueUpdateResponse: Decodable {
    let data: LinearIssueUpdateData
}

private struct LinearIssueUpdateData: Decodable {
    let issueUpdate: LinearIssueUpdateResult
}

private struct LinearIssueUpdateResult: Decodable {
    let success: Bool
}
