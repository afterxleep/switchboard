import Foundation

public final class DaemonLoop {
    private let config: DaemonConfig
    private let linearPoller: any LinearPolling
    private let githubPoller: any GitHubPolling
    private let dispatcher: any EventDispatching
    private let stateStore: StateStore
    private let completionWatcher: any CompletionWatching
    private let logger: (String) -> Void
    private let sleep: (TimeInterval) async -> Void
    private let stopLock: NSLock
    private var isStopped: Bool

    public init(
        config: DaemonConfig,
        linearPoller: LinearPoller,
        githubPoller: GitHubPoller,
        dispatcher: EventDispatcher,
        stateStore: StateStore
    ) {
        self.config = config
        self.linearPoller = linearPoller
        self.githubPoller = githubPoller
        self.dispatcher = dispatcher
        self.stateStore = stateStore
        self.completionWatcher = CompletionWatcher()
        self.logger = { message in
            fputs("\(message)\n", stderr)
        }
        self.sleep = { interval in
            let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        self.stopLock = NSLock()
        self.isStopped = false
    }

    public init(
        config: DaemonConfig,
        linearPoller: any LinearPolling,
        githubPoller: any GitHubPolling,
        dispatcher: any EventDispatching,
        stateStore: StateStore,
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
        self.logger = logger
        self.sleep = sleep
        self.stopLock = NSLock()
        self.isStopped = false
    }

    public func tick() async throws {
        let currentState = try stateStore.load()
        let linearKnownIds = Set(
            currentState.values.compactMap { entry in
                entry.id.hasPrefix("linear:") ? entry.id : nil
            }
        )
        let linearEvents = try await linearPoller.poll(knownIds: linearKnownIds)
        let githubEvents = try await githubPoller.poll(state: currentState)

        let allEvents = linearEvents + githubEvents
        if allEvents.isEmpty == false {
            logger("dispatching \(allEvents.count) event(s)")
        }
        for event in allEvents {
            try dispatcher.dispatch(event)
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
    }

    private var stopped: Bool {
        stopLock.lock()
        let value = isStopped
        stopLock.unlock()
        return value
    }
}
