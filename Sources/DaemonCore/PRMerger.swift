import Foundation

public final class PRMerger: PRMerging {
    private let token: String
    private let repo: String
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(
        token: String,
        repo: String,
        urlSession: URLSession? = nil
    ) {
        self.token = token
        self.repo = repo
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.urlSession = URLSession(configuration: configuration)
        }
        self.decoder = JSONDecoder()
    }

    public func merge(pr: Int, commitMessage: String) async throws {
        let path = try pullRequestPath(pr: pr) + "/merge"
        var request = makeRequest(path: path, method: "PUT")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "merge_method": "squash",
                "commit_title": commitMessage,
            ])
        } catch {
            throw PRMergerError.encodingFailed(path: path, details: String(describing: error))
        }

        _ = try await response(for: request, path: path)
    }

    public func postComment(pr: Int, body: String) async throws {
        // Use issue comments endpoint (works for PR comments without requiring a diff position)
        let issuePath = "/repos/\(repo)/issues/\(pr)/comments"
        var request = makeRequest(path: issuePath, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])
        _ = try await response(for: request, path: issuePath)
    }

    public func isMergeable(pr: Int) async throws -> PRMergeability {
        let pullRequest: PullRequest = try await get(path: try pullRequestPath(pr: pr))
        let reviews: [Review] = try await get(path: try pullRequestPath(pr: pr) + "/reviews")
        let checks: CheckRunsResponse = try await get(path: try commitsPath(sha: pullRequest.head.sha) + "/check-runs")
        let threadsResponse: GraphQLResponse<ReviewThreadsData> = try await postGraphQL(
            query: """
            query PullRequestThreads($owner: String!, $repo: String!, $number: Int!) {
              repository(owner: $owner, name: $repo) {
                pullRequest(number: $number) {
                  reviewThreads(first: 100) {
                    nodes {
                      isResolved
                    }
                  }
                }
              }
            }
            """,
            variables: try graphQLVariables(pr: pr)
        )

        return PRMergeability(
            approved: reviews.contains(where: { $0.state.uppercased() == "APPROVED" }),
            ciGreen: checks.checkRuns.isEmpty == false && checks.checkRuns.allSatisfy {
                $0.status.lowercased() == "completed" && $0.conclusion?.lowercased() == "success"
            },
            noOpenThreads: threadsResponse.data.repository.pullRequest.reviewThreads.nodes.allSatisfy(\.isResolved),
            noConflicts: pullRequest.merged == false && pullRequest.mergeable == true
        )
    }

    private func pullRequestPath(pr: Int) throws -> String {
        guard repo.split(separator: "/", maxSplits: 1).count == 2 else {
            throw PRMergerError.invalidRepository(repository: repo)
        }

        return "/repos/\(repo)/pulls/\(pr)"
    }

    private func commitsPath(sha: String) throws -> String {
        guard repo.split(separator: "/", maxSplits: 1).count == 2 else {
            throw PRMergerError.invalidRepository(repository: repo)
        }

        return "/repos/\(repo)/commits/\(sha)"
    }

    private func graphQLVariables(pr: Int) throws -> [String: Any] {
        let components = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            throw PRMergerError.invalidRepository(repository: repo)
        }

        return [
            "owner": components[0],
            "repo": components[1],
            "number": pr,
        ]
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let request = makeRequest(path: path, method: "GET")
        let (data, _) = try await response(for: request, path: path)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PRMergerError.decodingFailed(path: path, details: String(describing: error))
        }
    }

    private func postGraphQL<T: Decodable>(query: String, variables: [String: Any]) async throws -> T {
        let path = "/graphql"
        var request = makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "variables": variables,
            ])
        } catch {
            throw PRMergerError.encodingFailed(path: path, details: String(describing: error))
        }

        let (data, _) = try await response(for: request, path: path)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PRMergerError.decodingFailed(path: path, details: String(describing: error))
        }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = method
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    private func response(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PRMergerError.invalidResponse(path: path)
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw PRMergerError.httpError(path: path, statusCode: httpResponse.statusCode)
            }

            return (data, response)
        } catch let error as PRMergerError {
            throw error
        } catch {
            throw PRMergerError.requestFailed(path: path, details: String(describing: error))
        }
    }
}

private struct PullRequest: Decodable {
    let merged: Bool
    let mergeable: Bool?
    let head: PullRequestHead
}

private struct PullRequestHead: Decodable {
    let sha: String
}

private struct Review: Decodable {
    let state: String
}

private struct CheckRunsResponse: Decodable {
    let checkRuns: [CheckRun]

    private enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

private struct CheckRun: Decodable {
    let status: String
    let conclusion: String?
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T
}

private struct ReviewThreadsData: Decodable {
    let repository: Repository
}

private struct Repository: Decodable {
    let pullRequest: PullRequestThreads
}

private struct PullRequestThreads: Decodable {
    let reviewThreads: ReviewThreadConnection
}

private struct ReviewThreadConnection: Decodable {
    let nodes: [ReviewThread]
}

private struct ReviewThread: Decodable {
    let isResolved: Bool
}
