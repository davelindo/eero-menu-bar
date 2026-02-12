import Foundation

enum AuthState: Equatable, Sendable {
    case restoring
    case unauthenticated
    case waitingForVerification(login: String)
    case authenticated
}

enum CloudReachabilityState: String, Codable, Equatable, Sendable {
    case unknown
    case reachable
    case degraded
    case unreachable
}

struct ProbeResult: Codable, Equatable, Sendable {
    var success: Bool
    var message: String
    var latencyMs: Double?

    static let unknown = ProbeResult(success: false, message: "Not run", latencyMs: nil)
}

struct RouteProbeResult: Codable, Equatable, Sendable {
    var interfaceName: String?
    var gateway: String?
    var success: Bool
    var message: String

    static let unknown = RouteProbeResult(interfaceName: nil, gateway: nil, success: false, message: "Not run")
}

struct OfflineProbeSnapshot: Codable, Equatable, Sendable {
    var checkedAt: Date
    var gateway: ProbeResult
    var dns: ProbeResult
    var ntp: ProbeResult
    var route: RouteProbeResult

    static let empty = OfflineProbeSnapshot(
        checkedAt: Date.distantPast,
        gateway: .unknown,
        dns: .unknown,
        ntp: .unknown,
        route: .unknown
    )

    var localHealthLabel: String {
        // "LAN" should remain meaningful even when the internet is offline; DNS here is a convenience probe.
        let criticalFlags = [gateway.success, route.success]
        if criticalFlags.allSatisfy({ $0 }) {
            return "LAN OK"
        }
        if criticalFlags.contains(true) {
            return "LAN Degraded"
        }
        return "LAN Down"
    }
}

struct CachedDataFreshness: Codable, Equatable, Sendable {
    var fetchedAt: Date

    var age: TimeInterval {
        max(0, Date().timeIntervalSince(fetchedAt))
    }
}

struct LocalThroughputSnapshot: Equatable, Sendable {
    var interfaceName: String
    var downBytesPerSecond: Double
    var upBytesPerSecond: Double
    var sampledAt: Date

    var downDisplay: String {
        Self.compactRateString(bitsPerSecond: downBytesPerSecond * 8)
    }

    var upDisplay: String {
        Self.compactRateString(bitsPerSecond: upBytesPerSecond * 8)
    }

    private static func compactRateString(bitsPerSecond: Double) -> String {
        let value: Double
        let suffix: String

        if bitsPerSecond >= 1_000_000_000 {
            value = bitsPerSecond / 1_000_000_000
            suffix = "G"
        } else if bitsPerSecond >= 1_000_000 {
            value = bitsPerSecond / 1_000_000
            suffix = "M"
        } else if bitsPerSecond >= 1_000 {
            value = bitsPerSecond / 1_000
            suffix = "K"
        } else {
            value = max(0, bitsPerSecond)
            suffix = "b"
        }

        let formatted: String
        if value >= 100 {
            formatted = String(format: "%.0f", value)
        } else if value >= 10 {
            formatted = String(format: "%.1f", value)
        } else {
            formatted = String(format: "%.2f", value)
        }
        return "\(formatted)\(suffix)"
    }
}
