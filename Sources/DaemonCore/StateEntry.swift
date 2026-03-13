import Foundation

public enum ItemStatus: String, Codable {
    case pending
    case inFlight
    case done
}

public struct StateEntry: Codable, Equatable {
    public let id: String
    public var status: ItemStatus
    public let eventType: String
    public let details: String
    public var startedAt: Date?
    public var updatedAt: Date

    public init(
        id: String,
        status: ItemStatus,
        eventType: String,
        details: String,
        startedAt: Date?,
        updatedAt: Date
    ) {
        self.id = id
        self.status = status
        self.eventType = eventType
        self.details = details
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}
