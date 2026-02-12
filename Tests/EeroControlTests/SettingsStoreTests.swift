import XCTest
@testable import EeroControl

final class SettingsStoreTests: XCTestCase {
    func testNormalization() {
        let normalized = AppSettings(
            foregroundPollInterval: 1,
            backgroundPollInterval: 1,
            gatewayAddress: "   ",
            defaultLogin: "  user@example.com  ",
            askConfirmationForModerateRisk: true
        ).normalized()

        XCTAssertEqual(normalized.foregroundPollInterval, 3)
        XCTAssertEqual(normalized.backgroundPollInterval, 15)
        XCTAssertEqual(normalized.gatewayAddress, "192.168.4.1")
        XCTAssertEqual(normalized.defaultLogin, "user@example.com")
        XCTAssertTrue(normalized.askConfirmationForModerateRisk)
    }

    func testRouteCatalogParity() {
        XCTAssertEqual(
            EeroRouteCatalog.getResourceKeys,
            [
                "account",
                "networks",
                "ac_compat",
                "device_blacklist",
                "devices",
                "diagnostics",
                "eeros",
                "forwards",
                "guestnetwork",
                "insights",
                "ouicheck",
                "profiles",
                "reservations",
                "routing",
                "speedtest",
                "support",
                "thread",
                "updates"
            ]
        )

        XCTAssertEqual(
            EeroRouteCatalog.postResourceKeys,
            [
                "burst_reporters",
                "reboot",
                "reboot_eero",
                "run_speedtest"
            ]
        )
    }

    func testLocalHealthIgnoresNTPFailure() {
        let snapshot = OfflineProbeSnapshot(
            checkedAt: Date(),
            gateway: ProbeResult(success: true, message: "ok", latencyMs: 1),
            dns: ProbeResult(success: true, message: "ok", latencyMs: nil),
            ntp: ProbeResult(success: false, message: "optional", latencyMs: nil),
            route: RouteProbeResult(interfaceName: "en0", gateway: "192.168.4.1", success: true, message: "ok")
        )

        XCTAssertEqual(snapshot.localHealthLabel, "LAN OK")
    }

    func testLocalThroughputFormatting() {
        let snapshot = LocalThroughputSnapshot(
            interfaceName: "en0",
            downBytesPerSecond: 2_500_000,
            upBytesPerSecond: 150_000,
            sampledAt: Date()
        )

        XCTAssertTrue(snapshot.downDisplay.hasSuffix("M"))
        XCTAssertTrue(snapshot.upDisplay.hasSuffix("M") || snapshot.upDisplay.hasSuffix("K"))
    }
}
