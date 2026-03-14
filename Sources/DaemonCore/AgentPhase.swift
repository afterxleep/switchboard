import Foundation

public enum AgentPhase: String, Codable {
    case coding
    case waitingOnCI
    case waitingOnReview
    case addressingFeedback
    case merged
    case done
}
