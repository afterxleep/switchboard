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
    private let prReviewRequester: (any PRReviewRequesting)?
    private let prMerger: (any PRMerging)?
    private let reviewThreadResolver: (any ReviewThreadResolving)?
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
        prReviewRequester: (any PRReviewRequesting)? = nil,
        prMerger: (any PRMerging)? = nil,
        reviewThreadResolver: (any ReviewThreadResolving)? = nil,
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
        self.prReviewRequester = prReviewRequester
        self.prMerger = prMerger
        self.reviewThreadResolver = reviewThreadResolver
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

    // MARK: - Reconcile (timeout recovery only)

    public func reconcile() async throws {
        let state = try stateStore.load()

        for entry in state.values where entry.status == .inFlight && entry.timedOut(after: config.inFlightTimeoutSeconds) {
            let task = removeRunningAgent(id: entry.id)
            task?.cancel()
            _ = removeCompletedAgentResult(id: entry.id)
            var resetEntry = entry
            resetEntry.status = .pending
            resetEntry.startedAt = nil
            resetEntry.updatedAt = Date()
            resetEntry.sessionId = nil
            resetEntry.agentPid = nil
            resetEntry.tokensUsed = nil
            resetEntry.agentPhase = .coding
            try stateStore.upsert(resetEntry)
            logger("reconcile: reset timed-out entry \(entry.id)")
        }
    }

    private var stopped: Bool {
        stopLock.lock()
        let value = isStopped
        stopLock.unlock()
        return value
    }

    // MARK: - Event routing (all phase transitions happen here)

    private func route(event: DaemonEvent) async throws {
        switch event {
        case let .newIssue(id, identifier, _, _, linkedPRNumber):
            guard agentRunner != nil else {
                try dispatcher.dispatch(event)
                return
            }
            let eventId = event.eventId
            guard runningAgent(for: eventId) == nil else {
                return
            }

            // Use PR linked directly on the Linear issue, then fall back to branch-name search
            let existingPR: (prNumber: Int, branch: String, title: String)?
            if let prNum = linkedPRNumber {
                let isOpen = (try? await githubPoller.isPROpen(prNumber: prNum)) ?? false
                existingPR = isOpen ? (prNum, "", "") : nil
            } else {
                existingPR = try? await githubPoller.findOpenPR(for: identifier)
            }

            if let existing = existingPR {
                // If an entry already exists with this PR attached, don't overwrite its phase
                let currentState = try stateStore.load()
                if let current = currentState[eventId], current.prNumber != nil {
                    return  // Already tracked — let events manage phase transitions
                }
                let existingRetryCount = currentState[eventId]?.retryCount ?? 0
                let entry = StateEntry(
                    id: eventId,
                    status: .inFlight,
                    eventType: event.eventType,
                    details: event.details,
                    startedAt: Date(),
                    updatedAt: Date(),
                    prNumber: existing.prNumber,
                    prTitle: existing.title,
                    linearIssueId: id,
                    agentPhase: .waitingOnCI,
                    retryCount: existingRetryCount
                )
                try stateStore.upsert(entry)
                logger("attached existing PR #\(existing.prNumber) to \(identifier)")
                return
            }

            // Preserve retry count from existing entry — never overwrite with 0
            let existingEntry = try? stateStore.load()[eventId]
            let preservedRetryCount = existingEntry?.retryCount ?? 0
            if preservedRetryCount >= config.maxAgentRetries {
                logger("newIssue \(identifier): retry limit reached (\(preservedRetryCount)) — skipping")
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
                agentPhase: existingEntry?.agentPhase ?? .coding,
                retryCount: preservedRetryCount
            )
            try stateStore.upsert(entry)
            try stateStore.markTurnStarted(id: eventId)
            try? await linearStateManager?.moveToInProgress(issueId: id)
            startAgent(for: event, entryId: "linear:\(identifier)")

        case let .prOpened(pr, branch, title):
            if let entry = entryForBranch(branch) {
                // Known issue — attach PR and move to CI monitoring
                try stateStore.attachPR(id: entry.id, prNumber: pr, title: title, threadPath: entry.threadPath)
                try stateStore.updatePhase(id: entry.id, phase: .waitingOnCI)
            } else if stateStore.entry(forPR: pr) == nil {
                // Standalone PR with no linked Linear issue — monitor it as its own task
                let entryId = "gh:pr:\(pr)"
                guard (try? stateStore.load()[entryId]) == nil else { break }
                let entry = StateEntry(
                    id: entryId,
                    status: .inFlight,
                    eventType: event.eventType,
                    details: title,
                    startedAt: Date(),
                    updatedAt: Date(),
                    prNumber: pr,
                    prTitle: title,
                    agentPhase: .waitingOnCI
                )
                try stateStore.upsert(entry)
                logger("standalone PR #\(pr) (\(branch)) — monitoring without Linear issue")
            }
            guard config.githubReviewer.isEmpty == false else {
                break
            }
            do {
                try await prReviewRequester?.requestReview(pr: pr, reviewer: config.githubReviewer)
            } catch {
                logger("failed to request reviewer for PR #\(pr): \(error)")
            }

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
            try stateStore.clearPR(id: entry.id)
            try stateStore.updatePhase(id: entry.id, phase: .coding)
            try stateStore.markPending(id: entry.id)
            startAgentIfIdle(event: fallbackEvent(for: entry, error: "PR #\(pr) was closed without merging — please reopen or create a new PR"), entry: entry)

        case let .ciPassed(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            try stateStore.resetConsecutiveCIFailures(id: entry.id)
            // If ciBlocked, unblock: reset counter and move to waitingOnCI
            if entry.agentPhase == .ciBlocked {
                try stateStore.updatePhase(id: entry.id, phase: .waitingOnCI)
                logger("CI passed for ciBlocked entry \(entry.id) — unblocked, moving to waitingOnCI")
            }
            if try await githubPoller.hasUnresolvedThreads(prNumber: pr) == false {
                try stateStore.updatePhase(id: entry.id, phase: .waitingOnReview)
                if let linearIssueId = entry.linearIssueId {
                    try? await linearStateManager?.moveToInReview(issueId: linearIssueId)
                }
            }
            do {
                try await attemptMergeIfReady(prNumber: pr, stateId: entry.id)
            } catch {
                logger("merge readiness check failed for PR #\(pr): \(error)")
            }

        case let .ciFailure(pr, _, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            // Don't touch ciBlocked entries — they stay parked
            guard entry.agentPhase != .ciBlocked else {
                return
            }
            let failureCount = try stateStore.incrementConsecutiveCIFailures(id: entry.id)
            // Check ceiling first — if hit, park in ciBlocked permanently
            if failureCount >= config.maxConsecutiveCIFailures {
                try stateStore.updatePhase(id: entry.id, phase: .ciBlocked)
                logger("CI failure ceiling reached for \(entry.id) (\(failureCount) consecutive failures) — parking in ciBlocked")
                return
            }
            guard failureCount >= config.ciFailureThreshold else {
                return
            }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            if let linearIssueId = entry.linearIssueId {
                try? await linearStateManager?.moveToInProgress(issueId: linearIssueId)
            }
            startAgentIfIdle(event: event, entry: entry)

        case let .reviewComment(pr, _, _):
            guard let entry = stateStore.entry(forPR: pr) else { return }
            // Mark as done — prevents historical comments from replaying on subsequent ticks
            try stateStore.upsert(StateEntry(
                id: event.eventId, status: .done, eventType: event.eventType,
                details: "", startedAt: nil, updatedAt: Date()
            ))
            // Don't touch ciBlocked entries — they stay parked until CI passes
            guard entry.agentPhase != .ciBlocked else { return }
            // Skip if agent is already actively addressing feedback for this PR
            guard entry.agentPhase != .addressingFeedback || runningAgent(for: entry.id) == nil else { return }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            if let linearIssueId = entry.linearIssueId {
                try? await linearStateManager?.moveToInProgress(issueId: linearIssueId)
            }
            startAgentIfIdle(event: event, entry: entry)

        case let .unresolvedThread(pr, _, _, _, _, _):
            guard let entry = stateStore.entry(forPR: pr) else { return }
            // Don't touch ciBlocked entries
            guard entry.agentPhase != .ciBlocked else { return }
            // Use inFlight marker so a retry is possible if the agent fails without resolving the thread
            let existing = try? stateStore.load()[event.eventId]
            guard existing == nil || existing?.status == .pending else { return }
            try stateStore.upsert(StateEntry(
                id: event.eventId, status: .inFlight, eventType: event.eventType,
                details: "", startedAt: Date(), updatedAt: Date()
            ))
            guard entry.agentPhase != .addressingFeedback || runningAgent(for: entry.id) == nil else { return }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            if let linearIssueId = entry.linearIssueId {
                try? await linearStateManager?.moveToInProgress(issueId: linearIssueId)
            }
            startAgentIfIdle(event: event, entry: entry)

        case let .conflict(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                return
            }
            // Don't touch ciBlocked entries
            guard entry.agentPhase != .ciBlocked else { return }
            try stateStore.updatePhase(id: entry.id, phase: .addressingFeedback)
            startAgentIfIdle(event: event, entry: entry)

        case let .approved(pr, _):
            guard let entry = stateStore.entry(forPR: pr) else {
                if agentRunner == nil {
                    try dispatcher.dispatch(event)
                }
                return
            }
            do {
                try await attemptMergeIfReady(prNumber: pr, stateId: entry.id)
            } catch {
                logger("merge readiness check failed for PR #\(pr): \(error)")
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

    // MARK: - Event normalization

    private func normalize(events: [DaemonEvent]) -> [DaemonEvent] {
        var result: [DaemonEvent] = []
        var firstFeedbackEventByPR: [Int: DaemonEvent] = [:]
        var firstCIFailureByPR: [Int: DaemonEvent] = [:]
        var mergedChecksByPR: [Int: Set<String>] = [:]

        for event in events {
            switch event {
            case let .reviewComment(pr, _, _), let .unresolvedThread(pr, _, _, _, _, _):
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

    // MARK: - Agent lifecycle

    private func startAgentIfIdle(event: DaemonEvent, entry: StateEntry) {
        // Always load fresh state — ignore the passed-in entry for all checks
        guard let current = try? stateStore.load()[entry.id] else { return }

        if current.retryCount >= config.maxAgentRetries {
            logger("agent retry limit reached for \(entry.id) — skipping until manually reset")
            return
        }
        if current.agentPhase == .ciBlocked {
            logger("entry \(entry.id) is ciBlocked — skipping agent start")
            return
        }
        if current.consecutiveCIFailures >= config.maxConsecutiveCIFailures {
            logger("CI ceiling active for \(entry.id) — skipping agent start")
            return
        }

        // Atomic concurrency reservation: check count AND insert placeholder under lock
        let reserved = agentLock.withLock { () -> Bool in
            guard runningAgents[entry.id] == nil else { return false }
            guard runningAgents.count < config.maxConcurrentAgents else { return false }
            // Insert a placeholder task to atomically reserve the slot
            runningAgents[entry.id] = Task {}
            return true
        }

        guard reserved else {
            let currentCount = agentLock.withLock { runningAgents.count }
            if runningAgent(for: entry.id) != nil {
                // Already running — silent skip
            } else {
                logger("concurrency cap reached (\(currentCount)/\(config.maxConcurrentAgents)) — deferring agent for \(entry.id)")
            }
            return
        }

        persistPendingThreadNodeIds(for: event, entry: current)
        startAgent(for: event, entryId: entry.id)
    }

    private func startAgent(for event: DaemonEvent, entryId: String) {
        guard let agentRunner else {
            return
        }
        if (try? stateStore.load()[entryId])?.retryCount ?? 0 >= config.maxAgentRetries {
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

                if var entry = try? stateStore.load()[completedId] {
                    for nodeId in entry.pendingThreadNodeIds {
                        do {
                            try await reviewThreadResolver?.resolve(threadNodeId: nodeId)
                        } catch {
                            logger("failed to resolve review thread \(nodeId): \(error)")
                        }
                    }

                    entry.pendingThreadNodeIds.removeAll()
                    try stateStore.upsert(entry)

                    if entry.agentPhase == .addressingFeedback, let prNumber = entry.prNumber {
                        if
                            try await githubPoller.ciIsPassing(prNumber: prNumber),
                            try await githubPoller.hasUnresolvedThreads(prNumber: prNumber) == false,
                            try await githubPoller.hasConflicts(prNumber: prNumber) == false
                        {
                            try stateStore.updatePhase(id: completedId, phase: .waitingOnReview)
                            if let linearIssueId = entry.linearIssueId {
                                try? await linearStateManager?.moveToInReview(issueId: linearIssueId)
                            }
                            do {
                                try await attemptMergeIfReady(prNumber: prNumber, stateId: completedId)
                            } catch {
                                logger("merge readiness check failed for PR #\(prNumber): \(error)")
                            }
                        }
                    }
                }
            } else {
                try stateStore.incrementRetry(id: completedId)
                let entry = try stateStore.load()[completedId]
                if let retryCount = entry?.retryCount, retryCount >= config.maxAgentRetries {
                    try stateStore.markPending(id: completedId)
                    logger("agent exhausted retries for \(completedId) — parked until manually reset")
                } else {
                    try stateStore.markPending(id: completedId)
                }
                // Reset any inFlight unresolvedThread markers for this entry's PR so they can re-trigger
                if let prNumber = entry?.prNumber {
                    let state = try stateStore.load()
                    let threadPrefix = "gh:pr:\(prNumber):thread:"
                    for (key, marker) in state where key.hasPrefix(threadPrefix) && marker.status == .inFlight {
                        try stateStore.markPending(id: key)
                    }
                }
                logger("agent run failed for \(completedId): \(result.error ?? "unknown error")")
            }
        }
    }

    // MARK: - Helpers

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

    private func persistPendingThreadNodeIds(for event: DaemonEvent, entry: StateEntry) {
        guard case let .unresolvedThread(_, _, nodeId, _, _, _) = event else {
            return
        }

        var updatedEntry = entry
        if updatedEntry.pendingThreadNodeIds.contains(nodeId) == false {
            updatedEntry.pendingThreadNodeIds.append(nodeId)
        }

        do {
            try stateStore.upsert(updatedEntry)
        } catch {
            logger("failed to persist pending thread node IDs for \(entry.id): \(error)")
        }
    }

    private func entryForBranch(_ branch: String) -> StateEntry? {
        guard let identifier = branchParser.issueIdentifier(from: branch) else {
            return nil
        }
        let state = try? stateStore.load()
        return state?["linear:\(identifier)"]
    }

    private func attemptMergeIfReady(prNumber: Int, stateId: String) async throws {
        guard let prMerger else {
            return
        }

        guard let entry = try stateStore.load()[stateId] else {
            return
        }

        let mergeability = try await prMerger.isMergeable(pr: prNumber)
        guard mergeability.canMerge else {
            logger("PR #\(prNumber) not mergeable yet: \(mergeability)")
            return
        }

        let commitMessage = "\(entry.messageIdentifier): \(entry.prTitle ?? "Update PR #\(prNumber)")"
        try await prMerger.merge(pr: prNumber, commitMessage: commitMessage)
        logger("merge requested for PR #\(prNumber)")
    }

    // MARK: - Agent tracking (thread-safe)

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

    @discardableResult
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
