import Foundation

public final class GitHubPoller: GitHubPolling {
    private let token: String
    private let repo: String
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(token: String, repo: String, urlSession: URLSession? = nil) {
        self.token = token
        self.repo = repo
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: config)
        }
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func poll(state: [String: StateEntry]) async throws -> [DaemonEvent] {
        let openPullRequests = try await fetchPullRequests(state: "open")
        let recentlyClosedPullRequests = try await fetchPullRequests(state: "closed")

        var events: [DaemonEvent] = []
        let trackedPRNumbers = Set(state.values.compactMap(\.prNumber))

        for pullRequest in openPullRequests where shouldTrack(branch: pullRequest.head.ref) {
            if trackedPRNumbers.contains(pullRequest.number) == false {
                events.append(.prOpened(pr: pullRequest.number, branch: pullRequest.head.ref, title: pullRequest.title ?? ""))
            }
        }

        for entry in state.values {
            guard let prNumber = entry.prNumber else {
                continue
            }

            let pullRequest = openPullRequests.first(where: { $0.number == prNumber })
                ?? recentlyClosedPullRequests.first(where: { $0.number == prNumber })

            if let pullRequest, pullRequest.mergedAt != nil, entry.agentPhase != .done, entry.agentPhase != .merged {
                events.append(.prMerged(pr: prNumber, branch: pullRequest.head.ref))
            } else if let pullRequest, pullRequest.state.lowercased() == "closed", pullRequest.mergedAt == nil, entry.agentPhase != .done {
                events.append(.prClosed(pr: prNumber, branch: pullRequest.head.ref))
            }

            guard let pullRequest else {
                continue
            }

            if entry.agentPhase == .waitingOnCI, try await checksAllSucceeded(sha: pullRequest.head.sha) {
                events.append(.ciPassed(pr: prNumber, branch: pullRequest.head.ref))
            }

            let failedChecks = try await fetchFailedChecks(sha: pullRequest.head.sha)
            if failedChecks.isEmpty == false {
                events.append(.ciFailure(pr: prNumber, branch: pullRequest.head.ref, failedChecks: failedChecks))
            }

            if try await hasApprovedReview(prNumber: prNumber) {
                events.append(.approved(pr: prNumber, branch: pullRequest.head.ref))
            }

            if pullRequest.mergeableState?.lowercased() == "dirty" {
                events.append(.conflict(pr: prNumber, branch: pullRequest.head.ref))
            }

            let lastPolled = lastPolledDate(for: pullRequest.number, state: state)
            for comment in try await fetchReviewComments(prNumber: prNumber, lastPolledAt: lastPolled) {
                events.append(.reviewComment(pr: prNumber, body: comment.body, author: comment.user.login))
            }
            for comment in try await fetchIssueComments(prNumber: prNumber, lastPolledAt: lastPolled) {
                events.append(.reviewComment(pr: prNumber, body: comment.body, author: comment.user.login))
            }
            for thread in try await fetchUnresolvedThreads(prNumber: prNumber) {
                events.append(.unresolvedThread(
                    pr: prNumber,
                    threadId: thread.id,
                    nodeId: thread.nodeId,
                    path: thread.path ?? "unknown",
                    body: thread.body,
                    author: thread.author.login
                ))
            }
        }

        return deduplicate(events: events, state: state)
    }

    public func hasUnresolvedThreads(prNumber: Int) async throws -> Bool {
        try await fetchUnresolvedThreads(prNumber: prNumber).isEmpty == false
    }

    public func hasConflicts(prNumber: Int) async throws -> Bool {
        guard let pullRequest = try await fetchPullRequests(state: "open").first(where: { $0.number == prNumber }) else {
            return false
        }
        return pullRequest.mergeableState?.lowercased() == "dirty"
    }

    public func ciIsPassing(prNumber: Int) async throws -> Bool {
        guard let pullRequest = try await fetchPullRequests(state: "open").first(where: { $0.number == prNumber }) else {
            return false
        }
        return try await checksAllSucceeded(sha: pullRequest.head.sha)
    }

    public func findOpenPR(for issueIdentifier: String) async throws -> (prNumber: Int, branch: String, title: String)? {
        let open = try await fetchPullRequests(state: "open")
        let lower = issueIdentifier.lowercased()
        guard let pr = open.first(where: { $0.head.ref.lowercased().contains(lower) }) else {
            return nil
        }
        return (pr.number, pr.head.ref, pr.title ?? "")
    }

    private func fetchPullRequests(state: String) async throws -> [GitHubPullRequest] {
        try await get(path: "/repos/\(repo)/pulls?state=\(state)")
    }

    private func fetchFailedChecks(sha: String) async throws -> [String] {
        let response: GitHubCheckRunsResponse = try await get(path: "/repos/\(repo)/commits/\(sha)/check-runs")
        return response.checkRuns.compactMap { run in
            guard let conclusion = run.conclusion else {
                return nil
            }
            return conclusion.lowercased() == "failure" ? run.name : nil
        }
    }

    private func checksAllSucceeded(sha: String) async throws -> Bool {
        let response: GitHubCheckRunsResponse = try await get(path: "/repos/\(repo)/commits/\(sha)/check-runs")
        guard response.checkRuns.isEmpty == false else {
            return false
        }

        return response.checkRuns.allSatisfy { run in
            run.status.lowercased() == "completed" && run.conclusion?.lowercased() == "success"
        }
    }

    private func hasApprovedReview(prNumber: Int) async throws -> Bool {
        let reviews: [GitHubReview] = try await get(path: "/repos/\(repo)/pulls/\(prNumber)/reviews")
        return reviews.contains { $0.state.uppercased() == "APPROVED" }
    }

    private func fetchReviewComments(prNumber: Int, lastPolledAt: Date?) async throws -> [GitHubComment] {
        let comments: [GitHubComment] = try await get(path: "/repos/\(repo)/pulls/\(prNumber)/comments")
        return filter(comments: comments, after: lastPolledAt)
    }

    private func fetchIssueComments(prNumber: Int, lastPolledAt: Date?) async throws -> [GitHubComment] {
        let comments: [GitHubComment] = try await get(path: "/repos/\(repo)/issues/\(prNumber)/comments")
        return filter(comments: comments, after: lastPolledAt)
    }

    private func fetchUnresolvedThreads(prNumber: Int) async throws -> [GitHubReviewThread] {
        let reviewComments: [GitHubComment] = try await get(path: "/repos/\(repo)/pulls/\(prNumber)/comments")
        let reviewCommentNodeIds = Dictionary(uniqueKeysWithValues: reviewComments.map { ($0.id, $0.nodeId) })
        let payload: GitHubGraphQLResponse<GitHubPullRequestThreadsData> = try await postGraphQL(query: """
        query PullRequestThreads($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) {
                nodes {
                  id
                  isResolved
                  path
                  comments(first: 20) {
                    nodes {
                      databaseId
                      body
                      author {
                        login
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """, variables: graphQLVariables(prNumber: prNumber))

        let threads = payload.data.repository.pullRequest.reviewThreads.nodes
        return threads.compactMap { thread in
            guard
                thread.isResolved == false,
                let comment = thread.comments.nodes.last,
                let commentId = comment.databaseId,
                let nodeId = reviewCommentNodeIds[commentId]
            else {
                return nil
            }
            return GitHubReviewThread(id: String(commentId), nodeId: nodeId, path: thread.path, body: comment.body, author: comment.author)
        }
    }

    private func graphQLVariables(prNumber: Int) -> [String: Any] {
        let components = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return [
                "owner": "",
                "repo": "",
                "number": prNumber,
            ]
        }

        return [
            "owner": components[0],
            "repo": components[1],
            "number": prNumber,
        ]
    }

    private func filter(comments: [GitHubComment], after date: Date?) -> [GitHubComment] {
        guard let date else {
            return comments
        }
        return comments.filter { $0.createdAt > date }
    }

    private func deduplicate(events: [DaemonEvent], state: [String: StateEntry]) -> [DaemonEvent] {
        var seen = Set<String>()
        var result: [DaemonEvent] = []

        for event in events {
            guard seen.insert(event.eventId).inserted else {
                continue
            }

            if shouldEmit(event: event, state: state) {
                result.append(event)
            }
        }

        return result
    }

    private func shouldTrack(branch: String) -> Bool {
        branch.hasPrefix("kai/") || branch.hasPrefix("feature/")
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await response(for: request, path: path)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubPollerError.decodingFailed(path: path, details: String(describing: error))
        }
    }

    private func postGraphQL<T: Decodable>(query: String, variables: [String: Any]) async throws -> T {
        let path = "/graphql"
        guard repo.split(separator: "/", maxSplits: 1).count == 2 else {
            throw GitHubPollerError.invalidRepository(repository: repo)
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "variables": variables,
            ])
        } catch {
            throw GitHubPollerError.graphQLEncodingFailed(
                repository: repo,
                details: String(describing: error)
            )
        }

        let (data, _) = try await response(for: request, path: path)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubPollerError.decodingFailed(path: path, details: String(describing: error))
        }
    }

    private func response(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubPollerError.invalidResponse(path: path)
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw GitHubPollerError.httpError(path: path, statusCode: httpResponse.statusCode)
            }

            return (data, response)
        } catch let error as GitHubPollerError {
            throw error
        } catch {
            throw GitHubPollerError.requestFailed(path: path, details: String(describing: error))
        }
    }

    private func lastPolledDate(for prNumber: Int, state: [String: StateEntry]) -> Date? {
        state["gh:\(repo):pr:\(prNumber):last_polled"]?.updatedAt
    }

    private func shouldEmit(event: DaemonEvent, state: [String: StateEntry]) -> Bool {
        guard let entry = state[event.eventId] else {
            return true
        }

        return entry.status != .inFlight && entry.status != .done
    }
}

public enum GitHubPollerError: LocalizedError, Equatable {
    case invalidRepository(repository: String)
    case graphQLEncodingFailed(repository: String, details: String)
    case requestFailed(path: String, details: String)
    case invalidResponse(path: String)
    case httpError(path: String, statusCode: Int)
    case decodingFailed(path: String, details: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepository(repository):
            return "GitHub repository must be in owner/name format: \(repository)"
        case let .graphQLEncodingFailed(repository, details):
            return "GitHub GraphQL request encoding failed for repository \(repository): \(details)"
        case let .requestFailed(path, details):
            return "GitHub request failed for \(path): \(details)"
        case let .invalidResponse(path):
            return "GitHub request returned a non-HTTP response for \(path)"
        case let .httpError(path, statusCode):
            return "GitHub request failed for \(path) with status \(statusCode)"
        case let .decodingFailed(path, details):
            return "GitHub response decoding failed for \(path): \(details)"
        }
    }
}

private struct GitHubPullRequest: Decodable {
    let number: Int
    let title: String?
    let state: String
    let mergedAt: Date?
    let head: GitHubPullRequestHead
    let mergeableState: String?

    private enum CodingKeys: String, CodingKey {
        case number, title, state, head
        case mergedAt = "merged_at"
        case mergeableState = "mergeable_state"
    }
}

private struct GitHubPullRequestHead: Decodable {
    let ref: String
    let sha: String
}

private struct GitHubCheckRunsResponse: Decodable {
    let checkRuns: [GitHubCheckRun]

    private enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

private struct GitHubCheckRun: Decodable {
    let name: String
    let status: String
    let conclusion: String?
}

private struct GitHubReview: Decodable {
    let state: String
}

private struct GitHubComment: Decodable {
    let id: Int
    let nodeId: String
    let body: String
    let createdAt: Date
    let user: GitHubUser

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeId = "node_id"
        case body
        case createdAt = "created_at"
        case user
    }
}

private struct GitHubUser: Decodable {
    let login: String
}

private struct GitHubGraphQLResponse<T: Decodable>: Decodable {
    let data: T
}

private struct GitHubPullRequestThreadsData: Decodable {
    let repository: GitHubRepository
}

private struct GitHubRepository: Decodable {
    let pullRequest: GitHubGraphQLPullRequest
}

private struct GitHubGraphQLPullRequest: Decodable {
    let reviewThreads: GitHubReviewThreadConnection
}

private struct GitHubReviewThreadConnection: Decodable {
    let nodes: [GitHubReviewThreadNode]
}

private struct GitHubReviewThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let path: String?
    let comments: GitHubReviewThreadCommentConnection
}

private struct GitHubReviewThreadCommentConnection: Decodable {
    let nodes: [GitHubReviewThreadComment]
}

private struct GitHubReviewThreadComment: Decodable {
    let databaseId: Int?
    let body: String
    let author: GitHubUser
}

private struct GitHubReviewThread {
    let id: String
    let nodeId: String
    let path: String?
    let body: String
    let author: GitHubUser
}
