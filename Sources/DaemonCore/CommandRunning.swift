import Foundation

public protocol CommandRunning {
    func run(
        command: String,
        arguments: [String],
        currentDirectoryPath: String?
    ) throws -> (terminationStatus: Int32, combinedOutput: String)
}
