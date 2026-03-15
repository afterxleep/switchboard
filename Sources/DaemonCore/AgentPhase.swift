import Foundation

public enum AgentPhase: String, Codable {
    case coding
    case waitingOnCI
    case waitingOnReview
    case addressingFeedback
    case ciBlocked
    case merged
    case done

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AgentPhase(rawValue: rawValue) ?? .addressingFeedback
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
