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
    public var pendingThreadNodeIds: [String]

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
        consecutiveCIFailures: Int = 0,
        pendingThreadNodeIds: [String] = []
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
        self.pendingThreadNodeIds = pendingThreadNodeIds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case eventType
        case details
        case startedAt
        case updatedAt
        case sessionId
        case agentPid
        case tokensUsed
        case prNumber
        case prTitle
        case threadPath
        case linearIssueId
        case agentPhase
        case lastTurnAt
        case retryCount
        case consecutiveCIFailures
        case pendingThreadNodeIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(ItemStatus.self, forKey: .status)
        eventType = try container.decode(String.self, forKey: .eventType)
        details = try container.decode(String.self, forKey: .details)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        agentPid = try container.decodeIfPresent(Int.self, forKey: .agentPid)
        tokensUsed = try container.decodeIfPresent(Int.self, forKey: .tokensUsed)
        prNumber = try container.decodeIfPresent(Int.self, forKey: .prNumber)
        prTitle = try container.decodeIfPresent(String.self, forKey: .prTitle)
        threadPath = try container.decodeIfPresent(String.self, forKey: .threadPath)
        linearIssueId = try container.decodeIfPresent(String.self, forKey: .linearIssueId)
        let phaseRaw = try container.decodeIfPresent(String.self, forKey: .agentPhase) ?? "coding"
        agentPhase = AgentPhase(rawValue: phaseRaw) ?? .coding
        lastTurnAt = try container.decodeIfPresent(Date.self, forKey: .lastTurnAt)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        consecutiveCIFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveCIFailures) ?? 0
        pendingThreadNodeIds = try container.decodeIfPresent([String].self, forKey: .pendingThreadNodeIds) ?? []
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
