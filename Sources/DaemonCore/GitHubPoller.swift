import Foundation

public final class GitHubPoller: GitHubPolling {
    private let token: String
    private let repo: String
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(token: String, repo: String, urlSession: URLSession = .shared) {
        self.token = token
        self.repo = repo
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func poll(state: [String: StateEntry]) async throws -> [DaemonEvent] {
        let pullRequests = try await fetchPullRequests()
        var events: [DaemonEvent] = []

        for pullRequest in pullRequests {
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

            let reviewComments = try await fetchReviewComments(
                prNumber: pullRequest.number,
                lastPolledAt: lastPolledDate(for: pullRequest.number, state: state)
            )
            for comment in reviewComments {
                let event = DaemonEvent.reviewComment(
                    pr: pullRequest.number,
                    body: comment.body,
                    author: comment.user.login
                )
                if shouldEmit(event: event, state: state) {
                    events.append(event)
                }
            }

            if pullRequest.mergeable?.uppercased() == "CONFLICTING" {
                let event = DaemonEvent.conflict(pr: pullRequest.number, branch: pullRequest.head.ref)
                if shouldEmit(event: event, state: state) {
                    events.append(event)
                }
            }
        }

        return events
    }

    private func fetchPullRequests() async throws -> [GitHubPullRequest] {
        try await get(path: "/repos/\(repo)/pulls?state=open")
    }

    private func fetchFailedChecks(sha: String) async throws -> [String] {
        let statuses: [GitHubStatus] = try await get(path: "/repos/\(repo)/statuses/\(sha)")
        return statuses.compactMap { status in
            status.state.lowercased() == "failure" ? status.context : nil
        }
    }

    private func hasApprovedReview(prNumber: Int) async throws -> Bool {
        let reviews: [GitHubReview] = try await get(path: "/repos/\(repo)/pulls/\(prNumber)/reviews")
        return reviews.contains { $0.state.uppercased() == "APPROVED" }
    }

    private func fetchReviewComments(prNumber: Int, lastPolledAt: Date?) async throws -> [GitHubComment] {
        let comments: [GitHubComment] = try await get(path: "/repos/\(repo)/pulls/\(prNumber)/comments")
        guard let lastPolledAt else {
            return comments
        }

        return comments.filter { $0.createdAt > lastPolledAt }
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await performDataRequest(with: request)
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

private struct GitHubPullRequest: Decodable {
    let number: Int
    let head: GitHubPullRequestHead
    let mergeable: String?
}

private struct GitHubPullRequestHead: Decodable {
    let ref: String
    let sha: String
}

private struct GitHubStatus: Decodable {
    let state: String
    let context: String
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
