import Foundation

actor OfflineConnectivityService {
    func runOfflineProbeSuite(gateway: String) async -> OfflineProbeSnapshot {
        let routeResult = probeRoute()
        let targetGateway = routeResult.gateway ?? gateway

        let gatewayResult = probeGateway(targetGateway)
        let dnsResult = probeDNS(targetGateway)
        let ntpResult = probeNTP(targetGateway)

        return OfflineProbeSnapshot(
            checkedAt: Date(),
            gateway: gatewayResult,
            dns: dnsResult,
            ntp: ntpResult,
            route: routeResult
        )
    }

    private func probeGateway(_ gateway: String) -> ProbeResult {
        let result = ShellCommand.run(executable: "/sbin/ping", arguments: ["-c", "1", "-W", "1000", gateway])
        guard result.succeeded else {
            return ProbeResult(success: false, message: "Gateway ping failed", latencyMs: nil)
        }

        let latency = parsePingLatencyMs(result.stdout)
        let message = latency.map { String(format: "Gateway reachable (%.2f ms)", $0) } ?? "Gateway reachable"
        return ProbeResult(success: true, message: message, latencyMs: latency)
    }

    private func probeDNS(_ gateway: String) -> ProbeResult {
        let result = ShellCommand.run(executable: "/usr/bin/dig", arguments: ["+time=1", "+tries=1", "@\(gateway)", "eero.com", "A"])
        guard result.succeeded else {
            return ProbeResult(success: false, message: "Router DNS query failed", latencyMs: nil)
        }

        if result.stdout.contains("status: NOERROR") {
            return ProbeResult(success: true, message: "Router DNS resolver responding", latencyMs: nil)
        }

        return ProbeResult(success: false, message: "Router DNS did not return NOERROR", latencyMs: nil)
    }

    private func probeNTP(_ gateway: String) -> ProbeResult {
        let result = ShellCommand.run(executable: "/usr/bin/nc", arguments: ["-u", "-z", "-w", "1", gateway, "123"])
        if result.succeeded {
            return ProbeResult(success: true, message: "NTP port reachable", latencyMs: nil)
        }
        return ProbeResult(success: true, message: "NTP no response (optional check)", latencyMs: nil)
    }

    private func probeRoute() -> RouteProbeResult {
        let result = ShellCommand.run(executable: "/sbin/route", arguments: ["-n", "get", "default"])
        guard result.succeeded else {
            return RouteProbeResult(interfaceName: nil, gateway: nil, success: false, message: "Unable to read default route")
        }

        let interface = extractValue(prefix: "interface:", from: result.stdout)
        let gateway = extractValue(prefix: "gateway:", from: result.stdout)
        let success = interface != nil && gateway != nil
        let message: String
        if success {
            message = "Route via \(interface ?? "?") -> \(gateway ?? "?")"
        } else {
            message = "Default route incomplete"
        }
        return RouteProbeResult(interfaceName: interface, gateway: gateway, success: success, message: message)
    }

    private func parsePingLatencyMs(_ output: String) -> Double? {
        guard let segment = output.components(separatedBy: "time=").dropFirst().first else {
            return nil
        }
        let valuePart = segment.split(separator: " ").first.map(String.init)
        return valuePart.flatMap(Double.init)
    }

    private func extractValue(prefix: String, from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return trimmed.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
