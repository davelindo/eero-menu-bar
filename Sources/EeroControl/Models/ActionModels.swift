import Foundation

enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

enum RiskLevel: String, Codable, Sendable {
    case low
    case moderate
    case high
}

enum EeroActionKind: String, Codable, Sendable {
    case setGuestNetwork
    case setNetworkFeature
    case setClientPaused
    case setProfilePaused
    case setProfileAdBlock
    case setProfileContentFilter
    case setProfileBlockedApps
    case setDeviceStatusLight
    case rebootDevice
    case rebootNetwork
    case runSpeedTest
    case runBurstReporters
}

struct EeroAction: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: EeroActionKind
    var networkID: String
    var targetID: String?
    var endpoint: String
    var method: HTTPMethod
    var payload: [String: JSONValue]
    var label: String
    var riskLevel: RiskLevel
    var queueEligible: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: EeroActionKind,
        networkID: String,
        targetID: String? = nil,
        endpoint: String,
        method: HTTPMethod,
        payload: [String: JSONValue],
        label: String,
        riskLevel: RiskLevel,
        queueEligible: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.networkID = networkID
        self.targetID = targetID
        self.endpoint = endpoint
        self.method = method
        self.payload = payload
        self.label = label
        self.riskLevel = riskLevel
        self.queueEligible = queueEligible
        self.createdAt = createdAt
    }
}

struct QueuedAction: Identifiable, Codable, Equatable, Sendable {
    enum ReplayStatus: String, Codable, Sendable {
        case pending
        case replayed
        case failed
    }

    var id: UUID { action.id }
    var action: EeroAction
    var queuedAt: Date
    var status: ReplayStatus
    var lastError: String?
}

enum ActionExecutionResult: Equatable, Sendable {
    case success
    case queued
    case rejected(message: String)
    case failed(message: String)
}
