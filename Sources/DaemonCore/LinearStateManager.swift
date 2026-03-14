import Foundation

public protocol LinearStateManaging {
    func moveToInProgress(issueId: String) async throws
    func moveToInReview(issueId: String) async throws
    func moveToDone(issueId: String) async throws
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

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LinearStateManagerError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let payload = try JSONDecoder().decode(LinearIssueUpdateResponse.self, from: data)
        guard payload.data.issueUpdate.success else {
            throw LinearStateManagerError.updateFailed(issueId: issueId, stateId: stateId)
        }
    }
}

public enum LinearStateManagerError: LocalizedError, Equatable {
    case httpError(statusCode: Int)
    case updateFailed(issueId: String, stateId: String)

    public var errorDescription: String? {
        switch self {
        case let .httpError(statusCode):
            return "Linear API request failed with status \(statusCode)"
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
