import Foundation

public protocol BranchParsing {
    func issueIdentifier(from branchName: String) -> String?
}
