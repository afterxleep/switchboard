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
    public var prNumber: Int?
    public var prTitle: String?
    public var threadPath: String?
    public var linearIssueId: String?
    public var agentPhase: AgentPhase
    public var lastTurnAt: Date?
    public var retryCount: Int
    public var consecutiveCIFailures: Int

    public init(
        id: String,
        status: ItemStatus,
        eventType: String,
        details: String,
        startedAt: Date?,
        updatedAt: Date,
        sessionId: String? = nil,
        agentPid: Int? = nil,
        tokensUsed: Int? = nil,
        prNumber: Int? = nil,
        prTitle: String? = nil,
        threadPath: String? = nil,
        linearIssueId: String? = nil,
        agentPhase: AgentPhase = .coding,
        lastTurnAt: Date? = nil,
        retryCount: Int = 0,
        consecutiveCIFailures: Int = 0
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
        self.prNumber = prNumber
        self.prTitle = prTitle
        self.threadPath = threadPath
        self.linearIssueId = linearIssueId
        self.agentPhase = agentPhase
        self.lastTurnAt = lastTurnAt
        self.retryCount = retryCount
        self.consecutiveCIFailures = consecutiveCIFailures
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
