import Foundation

public enum PRReviewRequesterError: LocalizedError, Equatable {
    case invalidRepository(repository: String)
    case encodingFailed(pr: Int, reviewer: String, details: String)
    case requestFailed(path: String, details: String)
    case invalidResponse(path: String)
    case httpError(path: String, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepository(repository):
            return "GitHub repository must be in owner/name format: \(repository)"
        case let .encodingFailed(pr, reviewer, details):
            return "Review request encoding failed for PR #\(pr) and reviewer \(reviewer): \(details)"
        case let .requestFailed(path, details):
            return "GitHub request failed for \(path): \(details)"
        case let .invalidResponse(path):
            return "GitHub request returned a non-HTTP response for \(path)"
        case let .httpError(path, statusCode):
            return "GitHub request failed for \(path) with status \(statusCode)"
        }
    }
}
