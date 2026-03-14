import Foundation

public protocol PRReviewRequesting {
    func requestReview(pr: Int, reviewer: String) async throws
}
