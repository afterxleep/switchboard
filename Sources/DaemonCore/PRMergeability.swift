import Foundation

public struct PRMergeability: Equatable {
    public let approved: Bool
    public let ciGreen: Bool
    public let noOpenThreads: Bool
    public let noConflicts: Bool

    public init(
        approved: Bool,
        ciGreen: Bool,
        noOpenThreads: Bool,
        noConflicts: Bool
    ) {
        self.approved = approved
        self.ciGreen = ciGreen
        self.noOpenThreads = noOpenThreads
        self.noConflicts = noConflicts
    }

    public var canMerge: Bool {
        approved && ciGreen && noOpenThreads && noConflicts
    }
}
