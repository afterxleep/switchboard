import Foundation

public final class LinearPoller {
    private let apiKey: String
    private let teamSlug: String
    private let activeStates: Set<String>
    private let terminalStates: Set<String>
    private let urlSession: URLSession

    public init(
        apiKey: String,
        teamSlug: String,
        activeStates: [String] = ["todo", "in progress"],
        terminalStates: [String] = ["done", "cancelled", "canceled", "closed", "duplicate"],
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.teamSlug = teamSlug
        self.activeStates = Set(activeStates.map(Self.normalizeStateName))
        self.terminalStates = Set(terminalStates.map(Self.normalizeStateName))
        self.urlSession = urlSession
    }

    public func poll(knownIds: Set<String>) async throws -> [DaemonEvent] {
        let issues = try await fetchIssues()
        return issues.compactMap { issue in
            let stateName = Self.normalizeStateName(issue.state.name)
            if knownIds.contains(issue.id), terminalStates.contains(stateName) {
                return .issueCancelled(id: issue.id, identifier: issue.identifier)
            }

            if knownIds.contains(issue.id) == false, activeStates.contains(stateName) {
                return .newIssue(
                    id: issue.id,
                    identifier: issue.identifier,
                    title: issue.title,
                    description: issue.description
                )
            }

            return nil
        }
    }

    private func fetchIssues() async throws -> [LinearIssue] {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let query = """
        query Issues($teamSlug: String!, $stateNames: [String!]) {
          issues(filter: {team: {key: {eq: $teamSlug}}, state: {name: {in: $stateNames}}}) {
            nodes {
              id
              identifier
              title
              description
              state { name }
            }
          }
        }
        """
        let variables = [
            "teamSlug": teamSlug,
            "stateNames": Array(activeStates.union(terminalStates)).sorted(),
        ] as [String: Any]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "query": query,
                "variables": variables,
            ]
        )

        let (data, _) = try await performDataRequest(with: request)
        let response = try JSONDecoder().decode(LinearIssuesResponse.self, from: data)
        return response.data.issues.nodes
    }

    private static func normalizeStateName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func performDataRequest(with request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = urlSession.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

private struct LinearIssuesResponse: Decodable {
    let data: LinearIssuesData
}

private struct LinearIssuesData: Decodable {
    let issues: LinearIssuesNodes
}

private struct LinearIssuesNodes: Decodable {
    let nodes: [LinearIssue]
}

private struct LinearIssue: Decodable {
    let id: String
    let identifier: String
    let title: String
    let description: String?
    let state: LinearIssueState
}

private struct LinearIssueState: Decodable {
    let name: String
}
