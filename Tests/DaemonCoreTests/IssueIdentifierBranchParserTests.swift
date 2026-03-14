import XCTest
@testable import DaemonCore

final class IssueIdentifierBranchParserTests: XCTestCase {
    func test_issueIdentifierBranchParser_whenBranchContainsIssueIdentifier_returnsUppercasedIdentifier() {
        // Arrange
        let parser = IssueIdentifierBranchParser()

        // Act
        let identifier = parser.issueIdentifier(from: "kai/db-205-fix-lifecycle")

        // Assert
        XCTAssertEqual(identifier, "DB-205")
    }

    func test_issueIdentifierBranchParser_whenBranchDoesNotContainIssueIdentifier_returnsNil() {
        // Arrange
        let parser = IssueIdentifierBranchParser()

        // Act
        let identifier = parser.issueIdentifier(from: "kai/fix-lifecycle")

        // Assert
        XCTAssertNil(identifier)
    }
}
