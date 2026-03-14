import Foundation

public final class ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        command: String,
        arguments: [String],
        currentDirectoryPath: String?
    ) throws -> (terminationStatus: Int32, combinedOutput: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(
                fileURLWithPath: NSString(string: currentDirectoryPath).expandingTildeInPath,
                isDirectory: true
            )
        }
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }
}
