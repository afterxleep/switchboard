import Foundation

public final class EventDispatcher: EventDispatching {
    private let stateStore: StateStore
    private let openClawCommand: String

    public init(stateStore: StateStore, openClawCommand: String = "openclaw") {
        self.stateStore = stateStore
        self.openClawCommand = openClawCommand
    }

    public func dispatch(_ event: DaemonEvent) throws {
        if stateStore.isInFlight(id: event.eventId) {
            print("already in flight, skipping")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openClawCommand)
        process.arguments = ["system", "event", "--text", message, "--mode", "now"]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw EventDispatcherError.commandFailed(
                command: openClawCommand,
                status: process.terminationStatus
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
