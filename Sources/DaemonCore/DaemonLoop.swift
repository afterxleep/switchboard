import Foundation

public final class DaemonLoop {
    private let config: DaemonConfig
    private let linearPoller: any LinearPolling
    private let githubPoller: any GitHubPolling
    private let dispatcher: any EventDispatching
    private let stateStore: StateStore
    private let completionWatcher: any CompletionWatching
    private let agentRunner: (any AgentRunning)?
    private let logger: (String) -> Void
    private let sleep: (TimeInterval) async -> Void
    private let stopLock: NSLock
    private let agentLock: NSLock
    private var isStopped: Bool
    private var runningAgents: [String: Task<Void, Never>]
    private var completedAgentResults: [String: AgentResult]

    public init(
        config: DaemonConfig,
        linearPoller: LinearPoller,
        githubPoller: GitHubPoller,
        dispatcher: EventDispatcher,
        stateStore: StateStore,
        agentRunner: (any AgentRunning)? = nil
    ) {
        self.config = config
        self.linearPoller = linearPoller
        self.githubPoller = githubPoller
        self.dispatcher = dispatcher
        self.stateStore = stateStore
        self.completionWatcher = CompletionWatcher()
        self.agentRunner = agentRunner
        self.logger = { message in
            fputs("\(message)\n", stderr)
        }
        self.sleep = { interval in
            let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        self.stopLock = NSLock()
        self.agentLock = NSLock()
        self.isStopped = false
        self.runningAgents = [:]
        self.completedAgentResults = [:]
    }

    public init(
        config: DaemonConfig,
        linearPoller: any LinearPolling,
        githubPoller: any GitHubPolling,
        dispatcher: any EventDispatching,
        stateStore: StateStore,
        agentRunner: (any AgentRunning)? = nil,
        completionWatcher: any CompletionWatching = CompletionWatcher(),
        logger: @escaping (String) -> Void = { message in
            fputs("\(message)\n", stderr)
        },
        sleep: @escaping (TimeInterval) async -> Void = { interval in
            let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.config = config
        self.linearPoller = linearPoller
        self.githubPoller = githubPoller
        self.dispatcher = dispatcher
        self.stateStore = stateStore
        self.completionWatcher = completionWatcher
        self.agentRunner = agentRunner
        self.logger = logger
        self.sleep = sleep
        self.stopLock = NSLock()
        self.agentLock = NSLock()
        self.isStopped = false
        self.runningAgents = [:]
        self.completedAgentResults = [:]
    }

    public func tick() async throws {
        logger("tick starting")
        try processCompletedAgents()
        try reconcile()
        let currentState = try stateStore.load()

        var allEvents: [DaemonEvent] = []

        do {
            let linearEvents = try await linearPoller.poll(state: currentState)
            allEvents.append(contentsOf: linearEvents)
        } catch {
            logger("linear poll error (continuing): \(error)")
        }

        do {
            let githubEvents = try await githubPoller.poll(state: currentState)
            allEvents.append(contentsOf: githubEvents)
        } catch {
            logger("github poll error (continuing): \(error)")
        }

        logger("tick complete: \(allEvents.count) event(s)")
        for event in allEvents {
            try route(event: event)
        }

        try dispatcher.retryTimedOut(timeoutSeconds: config.inFlightTimeoutSeconds)
        try completionWatcher.checkAndProcess(dispatcher: dispatcher)
        try stateStore.cleanup()
    }

    public func run() async {
        while stopped == false {
            do {
                try await tick()
            } catch {
                logger("daemon loop error: \(error)")
            }

            if stopped {
                break
            }

            await sleep(config.pollIntervalSeconds)
        }
    }

    public func stop() {
        stopLock.lock()
        isStopped = true
        stopLock.unlock()
        cancelAllAgents()
    }

    public func reconcile() throws {
        let state = try stateStore.load()
        var timedOutIds: [String] = []

        for entry in state.values where entry.status == .inFlight && entry.timedOut(after: config.inFlightTimeoutSeconds) {
            timedOutIds.append(entry.id)
        }

        for timedOutId in timedOutIds {
            let task = removeRunningAgent(id: timedOutId)
            task?.cancel()
            _ = removeCompletedAgentResult(id: timedOutId)
            try stateStore.markPending(id: timedOutId)
            logger("re-queued timed-out agent: \(timedOutId)")
        }
    }

    private var stopped: Bool {
        stopLock.lock()
        let value = isStopped
        stopLock.unlock()
        return value
    }

    private func route(event: DaemonEvent) throws {
        guard case .newIssue = event, let agentRunner else {
            try dispatcher.dispatch(event)
            return
        }

        if runningAgent(for: event.eventId) != nil {
            return
        }

        let entry = StateEntry(
            id: event.eventId,
            status: .pending,
            eventType: event.eventType,
            details: event.details,
            startedAt: nil,
            updatedAt: Date()
        )
        try stateStore.upsert(entry)
        try stateStore.markInFlight(id: event.eventId)

        let task = Task { [config] in
            let result = await agentRunner.run(event: event, config: config)
            if Task.isCancelled {
                return
            }
            self.storeCompletedAgentResult(id: event.eventId, result: result)
        }

        storeRunningAgent(id: event.eventId, task: task)
    }

    private func processCompletedAgents() throws {
        let completedIds = agentLock.withLock {
            Array(completedAgentResults.keys)
        }

        for completedId in completedIds {
            _ = removeRunningAgent(id: completedId)
            let result = removeCompletedAgentResult(id: completedId)

            guard let result else {
                continue
            }

            if result.success {
                try stateStore.markDone(id: completedId)
            } else {
                try stateStore.markPending(id: completedId)
                logger("agent run failed for \(completedId): \(result.error ?? "unknown error")")
            }
        }
    }

    private func cancelAllAgents() {
        let tasks = agentLock.withLock {
            let currentTasks = Array(runningAgents.values)
            runningAgents.removeAll()
            completedAgentResults.removeAll()
            return currentTasks
        }

        for task in tasks {
            task.cancel()
        }
    }

    private func runningAgent(for id: String) -> Task<Void, Never>? {
        agentLock.withLock {
            runningAgents[id]
        }
    }

    private func storeRunningAgent(id: String, task: Task<Void, Never>) {
        agentLock.withLock {
            runningAgents[id] = task
        }
    }

    private func removeRunningAgent(id: String) -> Task<Void, Never>? {
        agentLock.withLock {
            runningAgents.removeValue(forKey: id)
        }
    }

    private func storeCompletedAgentResult(id: String, result: AgentResult) {
        agentLock.withLock {
            completedAgentResults[id] = result
        }
    }

    private func removeCompletedAgentResult(id: String) -> AgentResult? {
        agentLock.withLock {
            completedAgentResults.removeValue(forKey: id)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
