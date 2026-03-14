import Foundation

public final class PRReviewRequester: PRReviewRequesting {
    private let token: String
    private let repo: String
    private let urlSession: URLSession

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
    }

    public func requestReview(pr: Int, reviewer: String) async throws {
        let path = try reviewersPath(pr: pr)
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "POST"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["reviewers": [reviewer]])
        } catch {
            throw PRReviewRequesterError.encodingFailed(
                pr: pr,
                reviewer: reviewer,
                details: String(describing: error)
            )
        }

        _ = try await response(for: request, path: path)
    }

    private func reviewersPath(pr: Int) throws -> String {
        guard repo.split(separator: "/", maxSplits: 1).count == 2 else {
            throw PRReviewRequesterError.invalidRepository(repository: repo)
        }

        return "/repos/\(repo)/pulls/\(pr)/requested_reviewers"
    }

    private func response(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PRReviewRequesterError.invalidResponse(path: path)
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw PRReviewRequesterError.httpError(path: path, statusCode: httpResponse.statusCode)
            }

            return (data, response)
        } catch let error as PRReviewRequesterError {
            throw error
        } catch {
            throw PRReviewRequesterError.requestFailed(path: path, details: String(describing: error))
        }
    }
}
