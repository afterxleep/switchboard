import Foundation

public final class CodexAppServerClient: CodexAppServerRunning {
    private let codexPath: String
    private let transportFactory: () -> Transporting

    public private(set) var lastThreadId: String?
    public private(set) var lastThreadPath: String?
    public private(set) var lastProcessIdentifier: Int?
    public private(set) var lastTokensUsed: Int
    public private(set) var lastError: String?

    public init(codexPath: String = "/opt/homebrew/bin/codex") {
        self.codexPath = codexPath
        self.transportFactory = { ProcessTransport() }
        self.lastTokensUsed = 0
    }

    init(codexPath: String = "/opt/homebrew/bin/codex", transportFactory: @escaping () -> Transporting) {
        self.codexPath = codexPath
        self.transportFactory = transportFactory
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
        return await performRun(
            workspace: workspace,
            prompt: prompt,
            title: title,
            onEvent: onEvent,
            turnTimeoutSeconds: turnTimeoutSeconds,
            stallTimeoutSeconds: stallTimeoutSeconds
        ) { transport in
            try transport.send([
                "id": 2,
                "method": "thread/start",
                "params": [
                    "approvalPolicy": "never",
                    "sandbox": "none",
                    "cwd": workspace,
                ],
            ])
            return try await self.waitForThread(using: transport, responseId: 2, timeoutSeconds: stallTimeoutSeconds, onEvent: onEvent)
        }
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
        return await performRun(
            workspace: workspace,
            prompt: prompt,
            title: title,
            onEvent: onEvent,
            turnTimeoutSeconds: turnTimeoutSeconds,
            stallTimeoutSeconds: stallTimeoutSeconds
        ) { transport in
            try transport.send([
                "id": 2,
                "method": "thread/resume",
                "params": [
                    "threadId": threadId,
                ],
            ])
            return try await self.waitForThread(using: transport, responseId: 2, timeoutSeconds: stallTimeoutSeconds, onEvent: onEvent)
        }
    }

    private func resetRunState() {
        lastThreadId = nil
        lastThreadPath = nil
        lastProcessIdentifier = nil
        lastTokensUsed = 0
        lastError = nil
    }

    private func performRun(
        workspace: String,
        prompt: String,
        title: String,
        onEvent: @escaping (String) -> Void,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval,
        prepareThread: @escaping (Transporting) async throws -> ThreadContext
    ) async -> Bool {
        let transport = transportFactory()

        do {
            try transport.launch(codexPath: codexPath, workspace: workspace)
            lastProcessIdentifier = transport.processIdentifier

            defer {
                transport.terminate()
            }

            try transport.send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "flowdeck-daemon",
                        "version": "1.0",
                    ],
                    "capabilities": [:],
                ],
            ])
            try await waitForInitialized(using: transport, timeoutSeconds: stallTimeoutSeconds, onEvent: onEvent)

            let thread = try await prepareThread(transport)
            lastThreadId = thread.id
            lastThreadPath = thread.path

            try transport.send([
                "id": 3,
                "method": "turn/start",
                "params": [
                    "threadId": thread.id,
                    "input": [
                        [
                            "type": "text",
                            "text": prompt,
                        ],
                    ],
                    "cwd": workspace,
                    "title": title,
                    "approvalPolicy": "never",
                    "sandboxPolicy": [
                        "type": "none",
                    ],
                ],
            ])

            let completed = try await waitForTurnCompletion(
                using: transport,
                turnTimeoutSeconds: turnTimeoutSeconds,
                stallTimeoutSeconds: stallTimeoutSeconds,
                onEvent: onEvent
            )

            if completed == false && lastError == nil {
                lastError = "turn did not complete successfully"
            }
            return completed
        } catch {
            lastError = String(describing: error)
            onEvent("codex error: \(error)")
            transport.terminate()
            return false
        }
    }

    private func waitForInitialized(
        using transport: Transporting,
        timeoutSeconds: TimeInterval,
        onEvent: @escaping (String) -> Void
    ) async throws {
        while true {
            let message = try await waitForMessage(using: transport, timeoutSeconds: timeoutSeconds)
            onEvent(Self.describe(message: message))

            // Codex returns a response (id: 1, result: {...}) to initialize — not an "initialized" notification.
            if message.id == 1 {
                return
            }
            // Also handle older protocol versions that send an "initialized" notification.
            if message.method == "initialized" {
                return
            }
        }
    }

    private func waitForThread(
        using transport: Transporting,
        responseId: Int,
        timeoutSeconds: TimeInterval,
        onEvent: @escaping (String) -> Void
    ) async throws -> ThreadContext {
        while true {
            let message = try await waitForMessage(using: transport, timeoutSeconds: timeoutSeconds)
            onEvent(Self.describe(message: message))

            if message.method == "item/tool/approvalRequest" {
                try sendApproval(for: message, using: transport)
                continue
            }

            if message.id == responseId {
                if let thread = Self.extractThread(from: message.resultDictionary) {
                    return thread
                }
                throw CodexAppServerClientError.missingThreadId
            }
        }
    }

    private func waitForTurnCompletion(
        using transport: Transporting,
        turnTimeoutSeconds: TimeInterval,
        stallTimeoutSeconds: TimeInterval,
        onEvent: @escaping (String) -> Void
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(turnTimeoutSeconds)

        while true {
            let remainingTurnTime = deadline.timeIntervalSinceNow
            if remainingTurnTime <= 0 {
                throw CodexAppServerClientError.turnTimedOut
            }

            let timeoutSeconds = min(remainingTurnTime, stallTimeoutSeconds)
            let message = try await waitForMessage(using: transport, timeoutSeconds: timeoutSeconds)
            onEvent(Self.describe(message: message))

            if message.method == "item/tool/approvalRequest" {
                try sendApproval(for: message, using: transport)
                continue
            }

            switch message.method {
            case "turn/completed":
                lastTokensUsed = Self.extractTokens(from: message.raw["params"])
                return true
            case "turn/failed", "turn/cancelled":
                lastTokensUsed = Self.extractTokens(from: message.raw["params"])
                lastError = message.method ?? "turn failed"
                return false
            default:
                continue
            }
        }
    }

    private func sendApproval(for message: Message, using transport: Transporting) throws {
        guard let approvalId = message.raw["id"] else {
            throw CodexAppServerClientError.missingApprovalId
        }

        try transport.send([
            "id": approvalId,
            "result": [
                "approved": true,
            ],
        ])
    }

    private func waitForMessage(using transport: Transporting, timeoutSeconds: TimeInterval) async throws -> Message {
        let outcome = try await withThrowingTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                if let message = try await transport.nextMessage() {
                    return .message(message)
                }
                return .endOfStream
            }

            group.addTask {
                let nanoseconds = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                return .timedOut
            }

            let first = try await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        switch outcome {
        case let .message(message):
            return message
        case .endOfStream:
            throw CodexAppServerClientError.unexpectedEndOfStream
        case .timedOut:
            throw CodexAppServerClientError.stalled(timeoutSeconds: timeoutSeconds)
        }
    }

    private static func describe(message: Message) -> String {
        if let method = message.method {
            return "rpc \(method)"
        }
        if let id = message.raw["id"] {
            return "rpc response \(id)"
        }
        return "rpc message"
    }

    private static func extractThread(from result: [String: Any]?) -> ThreadContext? {
        guard let result else {
            return nil
        }

        if let threadId = result["thread_id"] as? String {
            let path = (result["thread"] as? [String: Any])?["path"] as? String
            return ThreadContext(id: threadId, path: path)
        }

        if let thread = result["thread"] as? [String: Any] {
            let id = (thread["id"] as? String) ?? (thread["thread_id"] as? String)
            let path = thread["path"] as? String
            if let id {
                return ThreadContext(id: id, path: path)
            }
        }

        return nil
    }

    private static func extractTokens(from value: Any?) -> Int {
        guard let value else {
            return 0
        }

        if let dictionary = value as? [String: Any] {
            if let total = dictionary["total_tokens"] as? Int {
                return total
            }
            if let total = dictionary["totalTokens"] as? Int {
                return total
            }
            if
                let input = dictionary["input_tokens"] as? Int,
                let output = dictionary["output_tokens"] as? Int
            {
                return input + output
            }
            if
                let input = dictionary["inputTokens"] as? Int,
                let output = dictionary["outputTokens"] as? Int
            {
                return input + output
            }

            for nestedValue in dictionary.values {
                let tokens = extractTokens(from: nestedValue)
                if tokens > 0 {
                    return tokens
                }
            }
        }

        if let array = value as? [Any] {
            for nestedValue in array {
                let tokens = extractTokens(from: nestedValue)
                if tokens > 0 {
                    return tokens
                }
            }
        }

        return 0
    }
}

extension CodexAppServerClient {
    private struct ThreadContext {
        let id: String
        let path: String?
    }

    private enum WaitOutcome {
        case message(Message)
        case endOfStream
        case timedOut
    }

    struct Message {
        let raw: [String: Any]

        var id: Int? {
            if let id = raw["id"] as? Int {
                return id
            }
            if let id = raw["id"] as? String {
                return Int(id)
            }
            return nil
        }

        var method: String? {
            raw["method"] as? String
        }

        var resultDictionary: [String: Any]? {
            raw["result"] as? [String: Any]
        }
    }

    protocol Transporting {
        var processIdentifier: Int? { get }

        func launch(codexPath: String, workspace: String) throws
        func send(_ payload: [String: Any]) throws
        func nextMessage() async throws -> Message?
        func terminate()
    }

    private final class ProcessTransport: Transporting {
        private let process: Process
        private let stdinPipe: Pipe
        private let stdoutPipe: Pipe
        private var readerTask: Task<Void, Never>?
        private var stream: AsyncThrowingStream<Message, Error>?
        private var iterator: AsyncThrowingStream<Message, Error>.AsyncIterator?

        init() {
            self.process = Process()
            self.stdinPipe = Pipe()
            self.stdoutPipe = Pipe()
        }

        var processIdentifier: Int? {
            process.isRunning ? Int(process.processIdentifier) : nil
        }

        func launch(codexPath: String, workspace: String) throws {
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.currentDirectoryURL = URL(fileURLWithPath: workspace, isDirectory: true)
            process.arguments = [
                "app-server",
                "-c",
                "shell_environment_policy.inherit=all",
                "-c",
                "sandbox_permissions=[\"disk-full-read-access\",\"disk-write-access\"]",
            ]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe

            let stream = AsyncThrowingStream<Message, Error> { continuation in
                self.readerTask = Task {
                    do {
                        for try await line in self.stdoutPipe.fileHandleForReading.bytes.lines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                continue
                            }

                            guard let data = trimmed.data(using: .utf8) else {
                                continue
                            }

                            let jsonObject = try JSONSerialization.jsonObject(with: data)
                            guard let dictionary = jsonObject as? [String: Any] else {
                                throw CodexAppServerClientError.invalidMessagePayload(trimmed)
                            }

                            continuation.yield(Message(raw: dictionary))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }

            self.stream = stream
            self.iterator = stream.makeAsyncIterator()
            try process.run()
        }

        func send(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else {
                throw CodexAppServerClientError.invalidOutgoingPayload
            }
            line.append(0x0A)
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        }

        func nextMessage() async throws -> Message? {
            try await iterator?.next()
        }

        func terminate() {
            readerTask?.cancel()
            if process.isRunning {
                process.terminate()
            }
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
        }
    }
}

public enum CodexAppServerClientError: LocalizedError, Equatable {
    case invalidMessagePayload(String)
    case invalidOutgoingPayload
    case missingApprovalId
    case missingThreadId
    case stalled(timeoutSeconds: TimeInterval)
    case turnTimedOut
    case unexpectedEndOfStream

    public var errorDescription: String? {
        switch self {
        case let .invalidMessagePayload(payload):
            return "Invalid app-server message payload: \(payload)"
        case .invalidOutgoingPayload:
            return "Failed to encode app-server request"
        case .missingApprovalId:
            return "Approval request did not include an id"
        case .missingThreadId:
            return "thread/start result did not include thread_id"
        case let .stalled(timeoutSeconds):
            return "app-server stalled for \(Int(timeoutSeconds)) seconds"
        case .turnTimedOut:
            return "turn timed out"
        case .unexpectedEndOfStream:
            return "app-server exited before turn completion"
        }
    }
}
