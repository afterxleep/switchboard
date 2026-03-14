import Foundation

public final class DaemonLoop {
    private let config: DaemonConfig
    private let linearPoller: any LinearPolling
    private let githubPoller: any GitHubPolling
    private let dispatcher: any EventDispatching
    private let stateStore: any StateStoring
    private let completionWatcher: any CompletionWatching
    private let agentRunner: (any AgentRunning)?
    private let linearStateManager: (any LinearStateManaging)?
    private let workspaceManager: any WorkspaceManaging
    private let branchParser: any BranchParsing
    private let logger: (String) -> Void
    private let sleep: (TimeInterval) async -> Void
    private let stopLock: NSLock
    private let agentLock: NSLock
    private var isStopped: Bool
    private var runningAgents: [String: Task<Void, Never>]
    private var completedAgentResults: [String: AgentResult]

    public init(
        config: DaemonConfig,
        linearPoller: any LinearPolling,
        githubPoller: any GitHubPolling,
        dispatcher: any EventDispatching,
        stateStore: any StateStoring,
        agentRunner: (any AgentRunning)? = nil,
        linearStateManager: (any LinearStateManaging)? = nil,
        workspaceManager: any WorkspaceManaging = WorkspaceManager(),
        branchParser: any BranchParsing = IssueIdentifierBranchParser(),
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
        self.linearStateManager = linearStateManager
        self.workspaceManager = workspaceManager
        self.branchParser = branchParser
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
        try await processCompletedAgents()
        try await reconcile()
        let currentState = try stateStore.load()

        var allEvents: [DaemonEvent] = []

        do {
            allEvents.append(contentsOf: try await linearPoller.poll(state: currentState))
        } catch {
            logger("linear poll error (continuing): \(error)")
        }

        do {
            allEvents.append(contentsOf: try await githubPoller.poll(state: currentState))
        } catch {
            logger("github poll error (continuing): \(error)")
        }

        let routedEvents = normalize(events: allEvents)
        logger("tick complete: \(routedEvents.count) event(s)")
        for event in routedEvents {
            try await route(event: event)
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

    public func reconcile() async throws {
        let state = try stateStore.load()

        for entry in state.values where entry.status == .inFlight && entry.timedOut(after: config.inFlightTimeoutSeconds) {
            let task = removeRunningAgent(id: entry.id)
            task?.cancel()
            _ = removeCompletedAgentResult(id: entry.id)
            try stateStore.markPending(id: entry.id)
            logger("re-queued timed-out agent: \(entry.id)")
        }

        for entry in state.values where entry.agentPhase == .waitingOnReview {
            guard let prNumber = entry.prNumber else {
                continue
            }
            if try await githubPoller.hasUnresolvedThreads(prNumber: prNumber) {
                try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
                if let linearIssueId = entry.linearIssueId {
                    try? await linearStateManager?.moveToInProgress(issueId: linearIssueId)
                }
            }
        }
    }

    private var stopped: Bool {
        stopLock.lock()
        let value = isStopped
        stopLock.unlock()
        return value
    }

    private func route(event: DaemonEvent) async throws {
        switch event {
        case let .newIssue(id, identifier, _, _):
            guard agentRunner != nil else {
                try dispatcher.dispatch(event)
                return
            }
            let eventId = event.eventId
            guard runningAgent(for: eventId) == nil else {
                return
            }

            let entry = StateEntry(
                id: eventId,
                status: .pending,
                eventType: event.eventType,
                details: event.details,
                startedAt: nil,
                updatedAt: Date(),
                linearIssueId: id,
                agentPhase: .coding
            )
            try stateStore.upsert(entry)
            try stateStore.markTurnStarted(id: eventId)
            try? await linearStateManager?.moveToInProgress(issueId: id)
            startAgent(for: event, entryId: "linear:\(identifier)")

        case let .prOpened(pr, branch, _):
            guard let entry = entryForBranch(branch) else {
                return
            }
            try stateStore.attachPR(id: entry.id, prNumber: pr, threadPath: entry.threadPath)
            try stateStore.updatePhase(id: entry.id, phase: .waitingOnCI)

        case let .prMerged(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            try stateStore.updatePhase(id: entry.id, phase: .merged)
            if let linearIssueId = entry.linearIssueId {
                try? await linearStateManager?.moveToDone(issueId: linearIssueId)
            }
            try workspaceManager.cleanup(completedIds: [entry.id])
            try stateStore.markDone(id: entry.id)

        case let .prClosed(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            try stateStore.updatePhase(id: entry.id, phase: .coding)
            try stateStore.markPending(id: entry.id)

        case let .ciPassed(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            try stateStore.resetConsecutiveCIFailures(id: entry.id)
            if try await githubPoller.hasUnresolvedThreads(prNumber: pr) == false {
                try stateStore.updatePhase(id: entry.id, phase: .waitingOnReview)
                if let linearIssueId = entry.linearIssueId {
                    try? await linearStateManager?.moveToInReview(issueId: linearIssueId)
                }
            }

        case let .ciFailure(pr, _, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            let failureCount = try stateStore.incrementConsecutiveCIFailures(id: entry.id)
            guard failureCount >= config.ciFailureThreshold else {
                return
            }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            if let linearIssueId = entry.linearIssueId {
                try? await linearStateManager?.moveToInProgress(issueId: linearIssueId)
            }
            startAgentIfIdle(event: event, entry: entry)

        case let .reviewComment(pr, _, _),
             let .unresolvedThread(pr, _, _, _, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            if let linearIssueId = entry.linearIssueId {
                try? await linearStateManager?.moveToInProgress(issueId: linearIssueId)
            }
            startAgentIfIdle(event: event, entry: entry)

        case let .conflict(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            startAgentIfIdle(event: event, entry: entry)

        case let .approved(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                if agentRunner == nil {
                    try dispatcher.dispatch(event)
                }
                return
            }
            if entry.agentPhase == .waitingOnReview, try await githubPoller.hasConflicts(prNumber: pr) == false {
                logger("PR approved and ready to merge: #\(pr)")
            }

        case let .issueCancelled(_, identifier):
            let eventId = "linear:\(identifier)"
            removeRunningAgent(id: eventId)?.cancel()
            _ = removeCompletedAgentResult(id: eventId)
            try workspaceManager.cleanup(completedIds: [eventId])
            try stateStore.markDone(id: eventId)
        }
    }

    func routeForTesting(_ event: DaemonEvent) async throws {
        try await route(event: event)
    }

    private func normalize(events: [DaemonEvent]) -> [DaemonEvent] {
        var result: [DaemonEvent] = []
        var firstFeedbackEventByPR: [Int: DaemonEvent] = [:]
        var firstCIFailureByPR: [Int: DaemonEvent] = [:]
        var mergedChecksByPR: [Int: Set<String>] = [:]

        for event in events {
            switch event {
            case let .reviewComment(pr, _, _), let .unresolvedThread(pr, _, _, _, _):
                if firstFeedbackEventByPR[pr] == nil {
                    firstFeedbackEventByPR[pr] = event
                }
            case let .ciFailure(pr, branch, failedChecks):
                mergedChecksByPR[pr, default: []].formUnion(failedChecks)
                firstCIFailureByPR[pr] = .ciFailure(pr: pr, branch: branch, failedChecks: Array(mergedChecksByPR[pr] ?? []))
            default:
                result.append(event)
            }
        }

        result.append(contentsOf: firstFeedbackEventByPR.values)
        result.append(contentsOf: firstCIFailureByPR.values)
        return result
    }

    private func startAgentIfIdle(event: DaemonEvent, entry: StateEntry) {
        guard runningAgent(for: entry.id) == nil else {
            return
        }
        startAgent(for: event, entryId: entry.id)
    }

    private func startAgent(for event: DaemonEvent, entryId: String) {
        guard let agentRunner else {
            return
        }

        do {
            try stateStore.markTurnStarted(id: entryId)
        } catch {
            logger("failed to mark turn started for \(entryId): \(error)")
        }

        let task = Task { [config] in
            let result = await agentRunner.run(event: event, config: config)
            if Task.isCancelled {
                return
            }
            self.storeCompletedAgentResult(id: entryId, result: result)
        }

        storeRunningAgent(id: entryId, task: task)
    }

    private func processCompletedAgents() async throws {
        let completedIds = agentLock.withLock { Array(completedAgentResults.keys) }

        for completedId in completedIds {
            _ = removeRunningAgent(id: completedId)
            guard let result = removeCompletedAgentResult(id: completedId) else {
                continue
            }

            if result.success {
                if let threadId = result.threadId {
                    try stateStore.updateThread(id: completedId, sessionId: threadId, threadPath: result.threadPath)
                }
                try stateStore.resetRetry(id: completedId)
                try stateStore.markPending(id: completedId)

                if let entry = try? stateStore.load()[completedId], entry.agentPhase == .addressingFeedback, let prNumber = entry.prNumber {
                    if try await githubPoller.ciIsPassing(prNumber: prNumber), try await githubPoller.hasUnresolvedThreads(prNumber: prNumber) == false {
                        try stateStore.updatePhase(id: completedId, phase: .waitingOnReview)
                        if let linearIssueId = entry.linearIssueId {
                            try? await linearStateManager?.moveToInReview(issueId: linearIssueId)
                        }
                    }
                }
            } else {
                try stateStore.incrementRetry(id: completedId)
                let entry = try stateStore.load()[completedId]
                if let retryCount = entry?.retryCount, retryCount >= config.maxAgentRetries {
                    if let entry {
                        try dispatcher.dispatch(fallbackEvent(for: entry, error: result.error))
                    }
                } else {
                    try stateStore.markPending(id: completedId)
                }
                logger("agent run failed for \(completedId): \(result.error ?? "unknown error")")
            }
        }
    }

    private func fallbackEvent(for entry: StateEntry, error: String?) -> DaemonEvent {
        if let prNumber = entry.prNumber {
            return .reviewComment(pr: prNumber, body: error ?? "agent failure", author: "daemon")
        }

        return .newIssue(
            id: entry.linearIssueId ?? entry.id,
            identifier: entry.messageIdentifier,
            title: entry.details,
            description: error
        )
    }

    private func entryForBranch(_ branch: String) -> StateEntry? {
        guard let identifier = branchParser.issueIdentifier(from: branch) else {
            return nil
        }
        let state = try? stateStore.load()
        return state?["linear:\(identifier)"]
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
        agentLock.withLock { runningAgents[id] }
    }

    private func storeRunningAgent(id: String, task: Task<Void, Never>) {
        agentLock.withLock {
            runningAgents[id] = task
        }
    }

    private func removeRunningAgent(id: String) -> Task<Void, Never>? {
        agentLock.withLock { runningAgents.removeValue(forKey: id) }
    }

    private func storeCompletedAgentResult(id: String, result: AgentResult) {
        agentLock.withLock {
            completedAgentResults[id] = result
        }
    }

    private func removeCompletedAgentResult(id: String) -> AgentResult? {
        agentLock.withLock { completedAgentResults.removeValue(forKey: id) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
