import Foundation

public final class IssueIdentifierBranchParser: BranchParsing {
    private let regularExpression: NSRegularExpression

    public init(pattern: String = "(?i)db-\\d+") {
        self.regularExpression = try! NSRegularExpression(pattern: pattern)
    }

    public func issueIdentifier(from branchName: String) -> String? {
        guard
            let match = regularExpression.firstMatch(
                in: branchName,
                range: NSRange(branchName.startIndex..., in: branchName)
            ),
            let range = Range(match.range, in: branchName)
        else {
            return nil
        }

        return String(branchName[range]).uppercased()
    }
}
