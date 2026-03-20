import Foundation

public final class LinearPoller: LinearPolling {
    private let apiKey: String
    private let teamSlug: String
    private let assigneeId: String
    private let activeStates: Set<String>
    private let terminalStates: Set<String>
    private let urlSession: URLSession

    public init(
        apiKey: String,
        teamSlug: String,
        assigneeId: String = "",
        activeStates: [String] = ["todo", "in progress", "in review"],
        terminalStates: [String] = ["done", "cancelled", "canceled", "closed", "duplicate"],
        urlSession: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.teamSlug = teamSlug
        self.assigneeId = assigneeId
        self.activeStates = Set(activeStates.map(Self.normalizeStateName))
        self.terminalStates = Set(terminalStates.map(Self.normalizeStateName))
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: config)
        }
    }

    public func poll(state: [String: StateEntry]) async throws -> [DaemonEvent] {
        let issues = try await fetchIssues()
        var events: [DaemonEvent] = issues.compactMap { issue in
            let stateName = Self.normalizeStateName(issue.state.name)
            let eventId = "linear:\(issue.identifier)"

            // Skip events we've already dispatched or processed
            if let entry = state[eventId], entry.status == .inFlight || entry.status == .done {
                return nil
            }

            if state.keys.contains(eventId), terminalStates.contains(stateName) {
                return .issueCancelled(id: issue.id, identifier: issue.identifier)
            }

            if (state[eventId] == nil || state[eventId]?.status == .pending), activeStates.contains(stateName) {
                return .newIssue(
                    id: issue.id,
                    identifier: issue.identifier,
                    title: issue.title,
                    description: issue.description,
                    linkedPRNumber: issue.linkedPRNumber
                )
            }

            return nil
        }

        // Drop state entries for issues no longer assigned to us (unassigned or deleted)
        if assigneeId.isEmpty == false {
            let fetchedIdentifiers = Set(issues.map { $0.identifier })
            for (eventId, entry) in state {
                guard eventId.hasPrefix("linear:"), entry.status != .done else { continue }
                let identifier = String(eventId.dropFirst("linear:".count))
                if !fetchedIdentifiers.contains(identifier) {
                    events.append(.issueCancelled(id: entry.linearIssueId ?? identifier, identifier: identifier))
                }
            }
        }

        return events
    }

    private func fetchIssues() async throws -> [LinearIssue] {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let query: String
        let variables: [String: String]

        if assigneeId.isEmpty == false {
            query = """
            query Issues($teamSlug: String!, $assigneeId: ID!) {
              issues(filter: {
                team: { key: { eq: $teamSlug } }
                state: { type: { in: ["unstarted", "started"] } }
                assignee: { id: { eq: $assigneeId } }
              }) {
                nodes {
                  id
                  identifier
                  title
                  description
                  state { name }
                  attachments { nodes { url } }
                }
              }
            }
            """
            variables = [
                "teamSlug": teamSlug,
                "assigneeId": assigneeId,
            ]
        } else {
            query = """
            query Issues($teamSlug: String!) {
              issues(filter: {team: {key: {eq: $teamSlug}}}) {
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
            variables = ["teamSlug": teamSlug]
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "query": query,
                "variables": variables,
            ]
        )

        let (data, _) = try await urlSession.data(for: request)
        let response = try JSONDecoder().decode(LinearIssuesResponse.self, from: data)
        return response.data.issues.nodes
    }

    private static func normalizeStateName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    let attachments: LinearAttachments?

    var linkedPRNumber: Int? {
        guard let nodes = attachments?.nodes else { return nil }
        for node in nodes {
            if let url = node.url,
               let match = url.range(of: #"/pull/(\d+)$"#, options: .regularExpression) {
                let numStr = url[match].replacingOccurrences(of: "/pull/", with: "")
                return Int(numStr)
            }
        }
        return nil
    }
}

private struct LinearIssueState: Decodable {
    let name: String
}

private struct LinearAttachments: Decodable {
    let nodes: [LinearAttachment]
}

private struct LinearAttachment: Decodable {
    let url: String?
}
