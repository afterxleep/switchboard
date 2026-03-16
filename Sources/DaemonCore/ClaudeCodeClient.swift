import Foundation

public final class ClaudeCodeClient: CodexAppServerRunning {
    private let claudePath: String

    public private(set) var lastThreadId: String?
    public private(set) var lastThreadPath: String?
    public private(set) var lastProcessIdentifier: Int?
    public private(set) var lastTokensUsed: Int
    public private(set) var lastError: String?

    public init(claudePath: String = "/opt/homebrew/bin/claude") {
        self.claudePath = claudePath
        self.lastTokensUsed = 0
    }

    public func run(
        workspace: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval = 3600,
        stallTimeoutSeconds: TimeInterval = 300
    ) async -> Bool {
        resetRunState()
        let arguments = [
            "--print",
            "--permission-mode", "bypassPermissions",
            "--output-format", "stream-json",
            "--no-session-persistence=false",
            prompt,
        ]
        return await execute(
            workspace: workspace,
            arguments: arguments,
            onEvent: onEvent,
            turnTimeoutSeconds: turnTimeoutSeconds,
            stallTimeoutSeconds: stallTimeoutSeconds
        )
    }

    public func resume(
        workspace: String,
        threadId: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval = 3600,
        stallTimeoutSeconds: TimeInterval = 300
    ) async -> Bool {
        resetRunState()
        lastThreadId = threadId
        let arguments = [
            "--resume", threadId,
            "--print",
            "--permission-mode", "bypassPermissions",
            "--output-format", "stream-json",
            prompt,
        ]
        return await execute(
            workspace: workspace,
            arguments: arguments,
            onEvent: onEvent,
            turnTimeoutSeconds: turnTimeoutSeconds,
            stallTimeoutSeconds: stallTimeoutSeconds
        )
    }

    private func resetRunState() {
        lastThreadId = nil
        lastThreadPath = nil
        lastProcessIdentifier = nil
        lastTokensUsed = 0
        lastError = nil
    }

    private func execute(
        workspace: String,
        arguments: [String],
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval
    ) async -> Bool {
        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.currentDirectoryURL = URL(fileURLWithPath: workspace, isDirectory: true)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            lastError = "failed to launch claude: \(error)"
            onEvent("claude launch error: \(error)")
            return false
        }

        lastProcessIdentifier = Int(process.processIdentifier)

        let turnDeadline = Date().addingTimeInterval(turnTimeoutSeconds)
        var lastActivityDate = Date()
        var processExited = false
        var sessionIdExtracted = false

        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            continuation.yield(trimmed)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        var iterator = stream.makeAsyncIterator()

        do {
            while true {
                let remainingTurn = turnDeadline.timeIntervalSinceNow
                if remainingTurn <= 0 {
                    killProcess(process)
                    lastError = "turn timed out after \(Int(turnTimeoutSeconds))s"
                    return false
                }

                let stallCheck = min(remainingTurn, stallTimeoutSeconds)
                let line = try await withThrowingTaskGroup(of: LineReadOutcome.self) { group in
                    group.addTask {
                        if let line = try await iterator.next() {
                            return .line(line)
                        }
                        return .endOfStream
                    }
                    group.addTask {
                        let nanoseconds = UInt64(max(stallCheck, 0) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanoseconds)
                        return .timedOut
                    }

                    let first = try await group.next() ?? .timedOut
                    group.cancelAll()
                    return first
                }

                switch line {
                case let .line(jsonLine):
                    lastActivityDate = Date()
                    processEvent(jsonLine: jsonLine, sessionIdExtracted: &sessionIdExtracted, onEvent: onEvent)

                case .endOfStream:
                    processExited = true
                    break

                case .timedOut:
                    let elapsed = Date().timeIntervalSince(lastActivityDate)
                    if elapsed >= stallTimeoutSeconds {
                        killProcess(process)
                        lastError = "stalled(timeoutSeconds: \(Int(stallTimeoutSeconds)))"
                        return false
                    }
                    continue
                }

                if processExited { break }
            }
        } catch {
            killProcess(process)
            lastError = String(describing: error)
            onEvent("claude error: \(error)")
            return false
        }

        process.waitUntilExit()
        let exitCode = process.terminationStatus

        if exitCode != 0 && lastError == nil {
            lastError = "claude exited with code \(exitCode)"
        }

        computeThreadPath(workspace: workspace)

        return exitCode == 0 && lastError == nil
    }

    private func processEvent(jsonLine: String, sessionIdExtracted: inout Bool, onEvent: @escaping (String) -> Void) {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let eventType = json["type"] as? String ?? ""

        // Extract session_id from system event
        if eventType == "system", !sessionIdExtracted {
            if let sessionId = json["session_id"] as? String {
                lastThreadId = sessionId
                sessionIdExtracted = true
            }
        }

        // Extract tokens from result event
        if eventType == "result" {
            if let usage = json["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                lastTokensUsed = input + output
            }

            let subtype = json["subtype"] as? String ?? ""
            if subtype == "error" {
                let errorMsg = json["error"] as? String ?? "unknown error"
                lastError = errorMsg
            } else if subtype == "error_max_turns" {
                lastError = "error_max_turns"
            }
        }

        // Stream event description to onEvent
        let description = describeEvent(type: eventType, json: json)
        if !description.isEmpty {
            onEvent(description)
        }
    }

    private func describeEvent(type: String, json: [String: Any]) -> String {
        switch type {
        case "system":
            return "claude session started"
        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let first = content.first,
               let text = first["text"] as? String {
                let preview = String(text.prefix(200))
                return "assistant: \(preview)"
            }
            return "assistant message"
        case "tool_use":
            let name = json["name"] as? String ?? "unknown"
            return "tool_use: \(name)"
        case "tool_result":
            return "tool_result"
        case "result":
            let subtype = json["subtype"] as? String ?? ""
            return "result: \(subtype)"
        default:
            return "event: \(type)"
        }
    }

    private func computeThreadPath(workspace: String) {
        guard let sessionId = lastThreadId else { return }
        // Encode workspace path: replace / with - and strip leading -
        var encoded = workspace.replacingOccurrences(of: "/", with: "-")
        while encoded.hasPrefix("-") {
            encoded = String(encoded.dropFirst())
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        lastThreadPath = "\(home)/.claude/projects/\(encoded)/\(sessionId).jsonl"
    }

    private func killProcess(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }

    private enum LineReadOutcome {
        case line(String)
        case endOfStream
        case timedOut
    }
}
