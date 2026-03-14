import Foundation

public protocol ReviewThreadResolving {
    func resolve(threadNodeId: String) async throws
}
