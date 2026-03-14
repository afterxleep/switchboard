import Foundation

public final class EventDispatcher: EventDispatching {
    private let stateStore: any StateStoring
    private let openClawCommand: String
    private let commandRunner: any CommandRunning

    public init(
        stateStore: any StateStoring,
        openClawCommand: String = "/opt/homebrew/bin/openclaw",
        commandRunner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.stateStore = stateStore
        self.openClawCommand = openClawCommand
        self.commandRunner = commandRunner
    }

    public func dispatch(_ event: DaemonEvent) throws {
        let current = try? stateStore.load()[event.eventId]
        if current?.status == .inFlight || current?.status == .done {
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
        try dispatch(entry: entry, identifier: event.messageIdentifier)
    }

    public func retryTimedOut(timeoutSeconds: TimeInterval) throws {
        let state = try stateStore.load()

        for entry in state.values where entry.status == .inFlight && entry.timedOut(after: timeoutSeconds) {
            print("retrying timed-out event: \(entry.id)")
            try stateStore.markDone(id: entry.id)
            try dispatch(entry: entry, identifier: entry.messageIdentifier)
        }
    }

    public func markDone(id: String) throws {
        try stateStore.markDone(id: id)
    }

    private func dispatch(entry: StateEntry, identifier: String) throws {
        let message = "[\(identifier)] \(entry.eventType): \(entry.details)"
        let result = try commandRunner.run(
            command: openClawCommand,
            arguments: ["system", "event", "--text", message, "--mode", "now"],
            currentDirectoryPath: nil
        )

        guard result.terminationStatus == 0 else {
            throw EventDispatcherError.commandFailed(
                command: openClawCommand,
                status: result.terminationStatus
            )
        }

        try stateStore.upsert(entry)
        try stateStore.markInFlight(id: entry.id)
    }
}

public enum EventDispatcherError: LocalizedError, Equatable {
    case commandFailed(command: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status):
            return "Command failed: \(command) exited with status \(status)"
        }
    }
}
