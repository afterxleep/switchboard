import Foundation

public final class WorkspaceManager: WorkspaceManaging {
    private let rootURL: URL
    private let gitCommand: String
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning

    public init(
        rootPath: String = "~/.flowdeck-daemon/workspaces",
        gitCommand: String = "/usr/bin/git",
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.rootURL = URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath, isDirectory: true)
        self.gitCommand = gitCommand
        self.fileManager = fileManager
        self.commandRunner = commandRunner
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
        let result = try commandRunner.run(
            command: gitCommand,
            arguments: ["worktree", "add", workspaceURL.path],
            currentDirectoryPath: repoPath
        )

        guard result.terminationStatus == 0 else {
            throw WorkspaceManagerError.gitWorktreeAddFailed(
                repoPath: NSString(string: repoPath).expandingTildeInPath,
                workspacePath: workspaceURL.path,
                details: result.combinedOutput.isEmpty ? "unknown git error" : result.combinedOutput
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
