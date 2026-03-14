import Foundation

public final class WorkspaceManager: WorkspaceManaging {
    private let rootURL: URL
    private let gitCommand: String
    private let fileManager: FileManager

    public init(
        rootPath: String = "~/.flowdeck-daemon/workspaces",
        gitCommand: String = "/usr/bin/git",
        fileManager: FileManager = .default
    ) {
        self.rootURL = URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath, isDirectory: true)
        self.gitCommand = gitCommand
        self.fileManager = fileManager
    }

    public func workspace(for event: DaemonEvent, repoPath: String) throws -> String {
        let workspaceURL = rootURL.appendingPathComponent(Self.workspaceKey(for: event), isDirectory: true)
        if fileManager.fileExists(atPath: workspaceURL.path) {
            return workspaceURL.path
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try runGitWorktreeAdd(workspaceURL: workspaceURL, repoPath: repoPath)
        return workspaceURL.path
    }

    public func cleanup(completedIds: [String]) throws {
        for completedId in completedIds {
            let workspaceURL = rootURL.appendingPathComponent(Self.sanitize(eventId: completedId), isDirectory: true)
            guard fileManager.fileExists(atPath: workspaceURL.path) else {
                continue
            }

            try fileManager.removeItem(at: workspaceURL)
        }
    }

    private func runGitWorktreeAdd(workspaceURL: URL, repoPath: String) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gitCommand)
        process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: repoPath).expandingTildeInPath, isDirectory: true)
        process.arguments = ["worktree", "add", workspaceURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown git error"
            throw WorkspaceManagerError.gitWorktreeAddFailed(
                repoPath: process.currentDirectoryURL?.path ?? repoPath,
                workspacePath: workspaceURL.path,
                details: output
            )
        }
    }

    private static func workspaceKey(for event: DaemonEvent) -> String {
        sanitize(eventId: event.eventId)
    }

    private static func sanitize(eventId: String) -> String {
        eventId.replacingOccurrences(of: ":", with: "-")
    }
}

public enum WorkspaceManagerError: LocalizedError, Equatable {
    case gitWorktreeAddFailed(repoPath: String, workspacePath: String, details: String)

    public var errorDescription: String? {
        switch self {
        case let .gitWorktreeAddFailed(repoPath, workspacePath, details):
            return "git worktree add failed for repo \(repoPath) into \(workspacePath): \(details)"
        }
    }
}
