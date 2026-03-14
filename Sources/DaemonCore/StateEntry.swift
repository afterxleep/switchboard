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
    public var sessionId: String?
    public var agentPid: Int?
    public var tokensUsed: Int?

    public init(
        id: String,
        status: ItemStatus,
        eventType: String,
        details: String,
        startedAt: Date?,
        updatedAt: Date,
        sessionId: String? = nil,
        agentPid: Int? = nil,
        tokensUsed: Int? = nil
    ) {
        self.id = id
        self.status = status
        self.eventType = eventType
        self.details = details
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.sessionId = sessionId
        self.agentPid = agentPid
        self.tokensUsed = tokensUsed
    }

    public func timedOut(after timeoutSeconds: TimeInterval) -> Bool {
        guard let startedAt else {
            return false
        }

        return Date().timeIntervalSince(startedAt) > timeoutSeconds
    }

    public var messageIdentifier: String {
        if id.hasPrefix("linear:") {
            return String(id.dropFirst("linear:".count))
        }

        if id.hasPrefix("gh:pr:") {
            let components = id.split(separator: ":")
            if components.count >= 3 {
                return "PR #\(components[2])"
            }
        }

        return id
    }
}
