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
        let pullRequests = try await fetchPullRequests()

        // Poll all PRs concurrently — sequential was O(n × 4) API calls and timed out with large PR counts
        let nestedEvents = try await withThrowingTaskGroup(of: [DaemonEvent].self) { group in
            for pullRequest in pullRequests {
                group.addTask {
                    try await self.eventsForPR(pullRequest, state: state)
                }
            }

            var all: [DaemonEvent] = []
            for try await prEvents in group {
                all.append(contentsOf: prEvents)
            }
            return all
        }

        return nestedEvents
    }

    private func eventsForPR(_ pullRequest: GitHubPullRequest, state: [String: StateEntry]) async throws -> [DaemonEvent] {
        var events: [DaemonEvent] = []

        let failedChecks = try await fetchFailedChecks(sha: pullRequest.head.sha)
        if failedChecks.isEmpty == false {
            let event = DaemonEvent.ciFailure(
                pr: pullRequest.number,
                branch: pullRequest.head.ref,
                failedChecks: failedChecks
            )
            if shouldEmit(event: event, state: state) {
                events.append(event)
            }
        }

        let approved = try await hasApprovedReview(prNumber: pullRequest.number)
        if approved {
            let event = DaemonEvent.approved(pr: pullRequest.number, branch: pullRequest.head.ref)
            if shouldEmit(event: event, state: state) {
                events.append(event)
            }
        }

        let lastPolled = lastPolledDate(for: pullRequest.number, state: state)
        // Inline code review comments
        let reviewComments = try await fetchReviewComments(prNumber: pullRequest.number, lastPolledAt: lastPolled)
        // General PR issue comments (e.g. from `gh pr comment` or reviewer notes)
        let issueComments = try await fetchIssueComments(prNumber: pullRequest.number, lastPolledAt: lastPolled)

        for comment in reviewComments + issueComments {
            let event = DaemonEvent.reviewComment(
                pr: pullRequest.number,
                body: comment.body,
                author: comment.user.login
            )
            if shouldEmit(event: event, state: state) {
                events.append(event)
                break // one event per PR per tick to avoid spam
            }
        }

        if pullRequest.mergeableState?.lowercased() == "dirty" {
            let event = DaemonEvent.conflict(pr: pullRequest.number, branch: pullRequest.head.ref)
            if shouldEmit(event: event, state: state) {
                events.append(event)
            }
        }

        return events
    }

    private func fetchPullRequests() async throws -> [GitHubPullRequest] {
        try await get(path: "/repos/\(repo)/pulls?state=open")
    }

    private func fetchFailedChecks(sha: String) async throws -> [String] {
        let response: GitHubCheckRunsResponse = try await get(path: "/repos/\(repo)/commits/\(sha)/check-runs")
        return response.checkRuns.compactMap { run in
            guard let conclusion = run.conclusion else { return nil }
            return conclusion.lowercased() == "failure" ? run.name : nil
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

    private func filter(comments: [GitHubComment], after date: Date?) -> [GitHubComment] {
        guard let date else { return comments }
        return comments.filter { $0.createdAt > date }
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await urlSession.data(for: request)
        return try decoder.decode(T.self, from: data)
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

private struct GitHubPullRequest: Decodable {
    let number: Int
    let head: GitHubPullRequestHead
    let mergeable: Bool?
    let mergeableState: String?

    private enum CodingKeys: String, CodingKey {
        case number, head, mergeable
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
    let conclusion: String?
}

private struct GitHubReview: Decodable {
    let state: String
}

private struct GitHubComment: Decodable {
    let body: String
    let createdAt: Date
    let user: GitHubUser

    private enum CodingKeys: String, CodingKey {
        case body
        case createdAt = "created_at"
        case user
    }
}

private struct GitHubUser: Decodable {
    let login: String
}
