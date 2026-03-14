import Foundation

public protocol PRMerging {
    func merge(pr: Int, commitMessage: String) async throws
    func isMergeable(pr: Int) async throws -> PRMergeability
}
