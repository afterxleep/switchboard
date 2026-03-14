import Foundation

public enum PRMergerError: LocalizedError, Equatable {
    case invalidRepository(repository: String)
    case encodingFailed(path: String, details: String)
    case requestFailed(path: String, details: String)
    case invalidResponse(path: String)
    case httpError(path: String, statusCode: Int)
    case decodingFailed(path: String, details: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepository(repository):
            return "GitHub repository must be in owner/name format: \(repository)"
        case let .encodingFailed(path, details):
            return "GitHub request encoding failed for \(path): \(details)"
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
