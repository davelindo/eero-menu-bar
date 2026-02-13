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
        "channel_utilization",
        "device_blacklist",
        "devices",
        "diagnostics",
        "eeros",
        "forwards",
        "guestnetwork",
        "insights",
        "ouicheck",
        "profiles",
        "proxied_nodes",
        "reservations",
        "routing",
        "speedtest",
        "support",
        "thread",
        "updates",
      ]
    )

    XCTAssertEqual(
      EeroRouteCatalog.postResourceKeys,
      [
        "burst_reporters",
        "reboot",
        "reboot_eero",
        "run_speedtest",
      ]
    )
  }

  func testLocalHealthIgnoresNTPFailure() {
    let snapshot = OfflineProbeSnapshot(
      checkedAt: Date(),
      gateway: ProbeResult(success: true, message: "ok", latencyMs: 1),
      dns: ProbeResult(success: true, message: "ok", latencyMs: nil),
      ntp: ProbeResult(success: false, message: "optional", latencyMs: nil),
      route: RouteProbeResult(
        interfaceName: "en0", gateway: "192.168.4.1", success: true, message: "ok")
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

final class StoredAccountModelCoverageTests: XCTestCase {
  func testStoredAccountModelCoverageLoop() async throws {
    guard let snapshotURL = snapshotURLFromEnvironmentOrDefault() else {
      throw XCTSkip("No snapshot path configured.")
    }

    let refreshFromStoredAccount = boolEnvironment("EERO_MODEL_AUDIT_REFRESH", defaultValue: false)
    if !refreshFromStoredAccount {
      guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
        throw XCTSkip("Snapshot file not found at \(snapshotURL.path)")
      }
    }

    let iterations = max(1, intEnvironment("EERO_MODEL_AUDIT_ITERATIONS", defaultValue: 1))
    let intervalSeconds = max(
      0, doubleEnvironment("EERO_MODEL_AUDIT_INTERVAL_SECONDS", defaultValue: 0))
    let strictMode = boolEnvironment("EERO_MODEL_AUDIT_STRICT", defaultValue: false)
    let autoRefreshWhenAuditMissing = boolEnvironment(
      "EERO_MODEL_AUDIT_AUTO_REFRESH", defaultValue: true)

    for iteration in 1...iterations {
      let snapshot = try await loadSnapshot(
        from: snapshotURL,
        refreshFromStoredAccount: refreshFromStoredAccount,
        autoRefreshWhenAuditMissing: autoRefreshWhenAuditMissing
      )
      XCTAssertFalse(snapshot.networks.isEmpty, "Snapshot decoded but has no networks.")

      let reportModel = CoverageReport(snapshot: snapshot, sourceURL: snapshotURL)
      let report = reportModel.render(iteration: iteration, totalIterations: iterations)

      await MainActor.run {
        XCTContext.runActivity(named: "Stored Account Audit \(iteration)/\(iterations)") {
          activity in
          activity.add(XCTAttachment(string: report))
        }
      }

      print(report)

      if strictMode {
        XCTAssertTrue(
          reportModel.criticalGaps.isEmpty,
          "Critical model gaps detected: \(reportModel.criticalGaps.joined(separator: ", "))"
        )
      }

      if iteration < iterations, intervalSeconds > 0 {
        let delay = UInt64(intervalSeconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: delay)
      }
    }
  }

  private func loadSnapshot(from url: URL) throws -> EeroAccountSnapshot {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(EeroAccountSnapshot.self, from: data)
  }

  private func loadSnapshot(
    from url: URL,
    refreshFromStoredAccount: Bool,
    autoRefreshWhenAuditMissing: Bool
  ) async throws -> EeroAccountSnapshot {
    if refreshFromStoredAccount {
      guard let refreshed = try await refreshSnapshotFromStoredAccountIfAvailable(to: url) else {
        throw XCTSkip("No stored user token found in keychain for live model audit refresh.")
      }
      return refreshed
    }

    let cached = try loadSnapshot(from: url)
    guard autoRefreshWhenAuditMissing, cached.modelAudit == nil else {
      return cached
    }

    return try await refreshSnapshotFromStoredAccountIfAvailable(to: url) ?? cached
  }

  private func refreshSnapshotFromStoredAccountIfAvailable(to url: URL) async throws
    -> EeroAccountSnapshot?
  {
    let credentialStore = KeychainCredentialStore()
    guard let token = try credentialStore.loadUserToken(), !token.isEmpty else {
      return nil
    }

    let client = EeroAPIClient(session: .shared)
    await client.setUserToken(token)
    let snapshot = try await client.fetchAccount(config: UpdateConfig())
    saveSnapshot(snapshot, to: url)
    return snapshot
  }

  private func saveSnapshot(_ snapshot: EeroAccountSnapshot, to url: URL) {
    do {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(snapshot)
      try data.write(to: url, options: [.atomic])
    } catch {
      XCTFail("Failed to persist refreshed snapshot at \(url.path): \(error.localizedDescription)")
    }
  }

  private func snapshotURLFromEnvironmentOrDefault() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if let override = env["EERO_ACCOUNT_SNAPSHOT_PATH"]?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return URL(fileURLWithPath: override)
    }
    return OfflineStateStore.appSupportDirectory().appendingPathComponent(
      "cached-account-snapshot.json")
  }

  private func intEnvironment(_ key: String, defaultValue: Int) -> Int {
    let value =
      ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    return Int(value) ?? defaultValue
  }

  private func doubleEnvironment(_ key: String, defaultValue: Double) -> Double {
    let value =
      ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    return Double(value) ?? defaultValue
  }

  private func boolEnvironment(_ key: String, defaultValue: Bool) -> Bool {
    let value =
      ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    if ["1", "true", "yes", "y", "on"].contains(value) {
      return true
    }
    if ["0", "false", "no", "n", "off"].contains(value) {
      return false
    }
    return defaultValue
  }

  func testThirdPartyOutCrossReferenceForModelFields() throws {
    guard let outURL = thirdPartyOutURLFromEnvironmentOrDefault() else {
      throw XCTSkip("No third-party out path configured.")
    }
    guard FileManager.default.fileExists(atPath: outURL.path) else {
      throw XCTSkip("third-party out directory not found at \(outURL.path)")
    }
    let parserSource = try loadParserSource()

    struct FieldCrossReference {
      let field: String
      let decompiledIndicators: [String]
      let parserIndicators: [String]
    }

    let checks: [FieldCrossReference] = [
      FieldCrossReference(
        field: "client.rx_rate_mbps",
        decompiledIndicators: ["rx_rate_info", "rate_bps"],
        parserIndicators: ["rx_rate_info", "rate_mbps", "rate_bps", "rx_bitrate"]
      ),
      FieldCrossReference(
        field: "client.tx_rate_mbps",
        decompiledIndicators: ["tx_rate_info", "rate_bps"],
        parserIndicators: ["tx_rate_info", "rate_mbps", "rate_bps", "tx_bitrate"]
      ),
      FieldCrossReference(
        field: "client.usage_down_mbps",
        decompiledIndicators: ["down_mbps"],
        parserIndicators: ["down_mbps"]
      ),
      FieldCrossReference(
        field: "client.usage_up_mbps",
        decompiledIndicators: ["up_mbps"],
        parserIndicators: ["up_mbps"]
      ),
      FieldCrossReference(
        field: "client.usage_down_percent_current",
        decompiledIndicators: ["down_percent_current_usage"],
        parserIndicators: ["down_percent_current_usage", "downPercentCurrentUsage"]
      ),
      FieldCrossReference(
        field: "client.usage_up_percent_current",
        decompiledIndicators: ["up_percent_current_usage"],
        parserIndicators: ["up_percent_current_usage", "upPercentCurrentUsage"]
      ),
      FieldCrossReference(
        field: "network.channel_utilization",
        decompiledIndicators: ["channel_utilization"],
        parserIndicators: [
          "channel_utilization", "fetchChannelUtilizationSnapshot",
          "parseChannelUtilizationSummary",
        ]
      ),
      FieldCrossReference(
        field: "network.proxied_nodes",
        decompiledIndicators: ["proxied_nodes"],
        parserIndicators: ["proxied_nodes", "parseProxiedNodesSummary"]
      ),
      FieldCrossReference(
        field: "network.updates_status",
        decompiledIndicators: ["update_status"],
        parserIndicators: ["update_status", "[\"updates\", \"update_status\"]"]
      ),
    ]

    let endpointChecks: [(label: String, fragment: String)] = [
      ("channel utilization endpoint", "/channel_utilization"),
      ("device usage endpoint", "/data_usage/devices"),
      ("network usage endpoint", "/data_usage"),
      ("updates endpoint", "/updates"),
    ]
    let outIndicators = Set(checks.flatMap(\.decompiledIndicators) + endpointChecks.map(\.fragment))
    let outMatches = try scanOutCorpus(for: outIndicators, in: outURL)

    var report: [String] = []
    report.append("third-party/out cross-reference")
    report.append("Out Path: \(outURL.path)")
    report.append("")

    for check in checks {
      let decompiledHit = check.decompiledIndicators.contains { outMatches[$0] == true }
      let parserHit = check.parserIndicators.contains { parserSource.contains($0) }

      let decompiledLabel = decompiledHit ? "present in out" : "missing in out"
      let parserLabel = parserHit ? "mapped in parser" : "missing in parser"
      report.append("- \(check.field): \(decompiledLabel) / \(parserLabel)")

      if decompiledHit {
        XCTAssertTrue(
          parserHit,
          "\(check.field) appears in third-party out, but parser mapping was not found in EeroAPIClient.swift"
        )
      }
    }

    report.append("")
    report.append("Endpoint Fragments")
    for endpoint in endpointChecks {
      let inOut = outMatches[endpoint.fragment] == true
      let inParser = parserSource.contains(endpoint.fragment)
      report.append(
        "- \(endpoint.label): out=\(inOut ? "yes" : "no") parser=\(inParser ? "yes" : "no")")
      if inOut {
        XCTAssertTrue(
          inParser,
          "\(endpoint.label) is referenced in third-party out but not in EeroAPIClient fetch paths."
        )
      }
    }

    let rendered = report.joined(separator: "\n")
    XCTContext.runActivity(named: "third-party/out cross-reference") { activity in
      activity.add(XCTAttachment(string: rendered))
    }
    print(rendered)
  }

  func testLiveRawPayloadParityWithParsedSnapshot() async throws {
    let credentialStore = KeychainCredentialStore()
    guard let token = try credentialStore.loadUserToken(), !token.isEmpty else {
      throw XCTSkip("No stored user token found in keychain for live raw parity validation.")
    }

    let client = EeroAPIClient(session: .shared)
    await client.setUserToken(token)
    let result = try await client.fetchAccountWithRawPayloads(config: UpdateConfig())

    var rawNetworksByID: [String: [String: Any]] = [:]
    for payload in result.rawNetworks {
      guard let object = try JSONSerialization.jsonObject(with: payload.payload) as? [String: Any]
      else {
        continue
      }
      let rawURLID = DictionaryValue.id(fromURL: DictionaryValue.string(in: object, path: ["url"]))
      let keys = [
        normalizeLookupKey(payload.networkID),
        normalizeLookupKey("network-\(payload.networkID)"),
        normalizeLookupKey(rawURLID),
        normalizeLookupKey("network-\(rawURLID)"),
      ]
      for key in keys where !key.isEmpty {
        rawNetworksByID[key] = object
      }
    }

    var mismatches: [String] = []
    var comparisons = 0

    for network in result.snapshot.networks {
      let networkKey = normalizeLookupKey(network.id)
      guard let rawNetwork = rawNetworksByID[networkKey] else {
        mismatches.append("network[\(network.id)] missing raw payload match")
        continue
      }

      compare(
        path: "network[\(network.id)].status",
        actual: network.status,
        expected: DictionaryValue.string(in: rawNetwork, path: ["status"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].guestNetworkEnabled",
        actual: network.guestNetworkEnabled,
        expected: DictionaryValue.bool(in: rawNetwork, path: ["guest_network", "enabled"]) ?? false,
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].guestNetworkName",
        actual: network.guestNetworkName,
        expected: DictionaryValue.string(in: rawNetwork, path: ["guest_network", "name"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].backupInternetEnabled",
        actual: network.backupInternetEnabled,
        expected: DictionaryValue.bool(in: rawNetwork, path: ["backup_internet_enabled"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].health.internetStatus",
        actual: network.health.internetStatus,
        expected: DictionaryValue.string(in: rawNetwork, path: ["health", "internet", "status"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].health.internetUp",
        actual: network.health.internetUp,
        expected: DictionaryValue.bool(in: rawNetwork, path: ["health", "internet", "isp_up"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].health.eeroNetworkStatus",
        actual: network.health.eeroNetworkStatus,
        expected: DictionaryValue.string(
          in: rawNetwork, path: ["health", "eero_network", "status"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].updates.targetFirmware",
        actual: network.updates.targetFirmware,
        expected: DictionaryValue.string(in: rawNetwork, path: ["updates", "target_firmware"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].updates.updateStatus",
        actual: network.updates.updateStatus,
        expected: DictionaryValue.string(in: rawNetwork, path: ["updates", "update_status"])
          ?? DictionaryValue.string(in: rawNetwork, path: ["updates", "status"])
          ?? DictionaryValue.string(in: rawNetwork, path: ["update_status"])
          ?? DictionaryValue.string(in: rawNetwork, path: ["firmware_update_status"]),
        mismatches: &mismatches,
        comparisons: &comparisons
      )

      let expectedGatewayIP =
        DictionaryValue.string(in: rawNetwork, path: ["gateway_ip"])
        ?? gatewayIPFromRawEeros(rawNetwork)
      compare(
        path: "network[\(network.id)].gatewayIP",
        actual: network.gatewayIP,
        expected: expectedGatewayIP,
        mismatches: &mismatches,
        comparisons: &comparisons
      )

      let rawClients = DictionaryValue.dictArray(in: rawNetwork, path: ["devices", "data"])
      let expectedConnectedClients = rawClients.filter {
        DictionaryValue.bool(in: $0, path: ["connected"]) ?? false
      }.count
      let expectedConnectedGuestClients = rawClients.filter {
        (DictionaryValue.bool(in: $0, path: ["connected"]) ?? false)
          && (DictionaryValue.bool(in: $0, path: ["is_guest"]) ?? false)
      }.count

      compare(
        path: "network[\(network.id)].connectedClientsCount",
        actual: network.connectedClientsCount,
        expected: expectedConnectedClients,
        mismatches: &mismatches,
        comparisons: &comparisons
      )
      compare(
        path: "network[\(network.id)].connectedGuestClientsCount",
        actual: network.connectedGuestClientsCount,
        expected: expectedConnectedGuestClients,
        mismatches: &mismatches,
        comparisons: &comparisons
      )

      let rawClientMap = makeLookupMap(rows: rawClients, keys: rawClientLookupKeys)
      for parsedClient in network.clients {
        guard
          let rawClient = firstMatchedRow(
            for: parsedClientLookupKeys(parsedClient), in: rawClientMap)
        else {
          mismatches.append(
            "network[\(network.id)] client[\(parsedClient.id)] missing raw client match")
          continue
        }

        compareMAC(
          path: "network[\(network.id)] client[\(parsedClient.id)].mac",
          actual: parsedClient.mac,
          expected: DictionaryValue.string(in: rawClient, path: ["mac"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].ip",
          actual: parsedClient.ip,
          expected: DictionaryValue.string(in: rawClient, path: ["ip"])
            ?? DictionaryValue.string(in: rawClient, path: ["ipv4"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].connected",
          actual: parsedClient.connected,
          expected: DictionaryValue.bool(in: rawClient, path: ["connected"]) ?? false,
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].paused",
          actual: parsedClient.paused,
          expected: DictionaryValue.bool(in: rawClient, path: ["paused"]) ?? false,
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].wireless",
          actual: parsedClient.wireless,
          expected: DictionaryValue.bool(in: rawClient, path: ["wireless"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].isGuest",
          actual: parsedClient.isGuest,
          expected: DictionaryValue.bool(in: rawClient, path: ["is_guest"]) ?? false,
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].connectionType",
          actual: parsedClient.connectionType,
          expected: DictionaryValue.string(in: rawClient, path: ["connection_type"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].signal",
          actual: parsedClient.signal,
          expected: DictionaryValue.string(in: rawClient, path: ["connectivity", "signal"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].channel",
          actual: parsedClient.channel,
          expected: DictionaryValue.int(in: rawClient, path: ["channel"])
            ?? DictionaryValue.int(in: rawClient, path: ["connectivity", "channel"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].manufacturer",
          actual: parsedClient.manufacturer,
          expected: DictionaryValue.string(in: rawClient, path: ["manufacturer"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].deviceType",
          actual: parsedClient.deviceType,
          expected: DictionaryValue.string(in: rawClient, path: ["device_type"])
            ?? DictionaryValue.string(in: rawClient, path: ["manufacturer_device_type_id"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].sourceLocation",
          actual: parsedClient.sourceLocation,
          expected: DictionaryValue.string(in: rawClient, path: ["source", "location"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].sourceURL",
          actual: parsedClient.sourceURL,
          expected: DictionaryValue.string(in: rawClient, path: ["source", "url"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )

        compareDouble(
          path: "network[\(network.id)] client[\(parsedClient.id)].rxRateMbps",
          actual: parsedClient.rxRateMbps,
          expected: firstRateMbps(
            in: rawClient,
            pathPrefixes: [
              ["connectivity", "rx_rate_info"],
              ["connectivity", "rx_rate"],
              ["connectivity", "rx_bitrate"],
              ["rx_rate_info"],
              ["rx_rate"],
              ["rx_bitrate"],
            ]
          ),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compareDouble(
          path: "network[\(network.id)] client[\(parsedClient.id)].txRateMbps",
          actual: parsedClient.txRateMbps,
          expected: firstRateMbps(
            in: rawClient,
            pathPrefixes: [
              ["connectivity", "tx_rate_info"],
              ["connectivity", "tx_rate"],
              ["connectivity", "tx_bitrate"],
              ["tx_rate_info"],
              ["tx_rate"],
              ["tx_bitrate"],
            ]
          ),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compareDouble(
          path: "network[\(network.id)] client[\(parsedClient.id)].usageDownMbps",
          actual: parsedClient.usageDownMbps,
          expected: firstDouble(
            in: rawClient,
            paths: [
              ["usage", "down_mbps"],
              ["usage", "downMbps"],
              ["down_mbps"],
              ["downMbps"],
            ]
          ),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compareDouble(
          path: "network[\(network.id)] client[\(parsedClient.id)].usageUpMbps",
          actual: parsedClient.usageUpMbps,
          expected: firstDouble(
            in: rawClient,
            paths: [
              ["usage", "up_mbps"],
              ["usage", "upMbps"],
              ["up_mbps"],
              ["upMbps"],
            ]
          ),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].usageDownPercentCurrent",
          actual: parsedClient.usageDownPercentCurrent,
          expected: firstInt(
            in: rawClient,
            paths: [
              ["usage", "down_percent_current_usage"],
              ["usage", "downPercentCurrentUsage"],
              ["down_percent_current_usage"],
              ["downPercentCurrentUsage"],
            ]
          ),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] client[\(parsedClient.id)].usageUpPercentCurrent",
          actual: parsedClient.usageUpPercentCurrent,
          expected: firstInt(
            in: rawClient,
            paths: [
              ["usage", "up_percent_current_usage"],
              ["usage", "upPercentCurrentUsage"],
              ["up_percent_current_usage"],
              ["upPercentCurrentUsage"],
            ]
          ),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
      }

      let rawDevices = DictionaryValue.dictArray(in: rawNetwork, path: ["eeros", "data"])
      let rawDeviceMap = makeLookupMap(rows: rawDevices, keys: rawDeviceLookupKeys)
      for parsedDevice in network.devices {
        guard
          let rawDevice = firstMatchedRow(
            for: parsedDeviceLookupKeys(parsedDevice), in: rawDeviceMap)
        else {
          mismatches.append(
            "network[\(network.id)] device[\(parsedDevice.id)] missing raw device match")
          continue
        }

        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].status",
          actual: parsedDevice.status,
          expected: DictionaryValue.string(in: rawDevice, path: ["status"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compareMAC(
          path: "network[\(network.id)] device[\(parsedDevice.id)].macAddress",
          actual: parsedDevice.macAddress,
          expected: DictionaryValue.string(in: rawDevice, path: ["mac_address"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].ipAddress",
          actual: parsedDevice.ipAddress,
          expected: DictionaryValue.string(in: rawDevice, path: ["ip_address"])
            ?? DictionaryValue.string(in: rawDevice, path: ["ip"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].isGateway",
          actual: parsedDevice.isGateway,
          expected: DictionaryValue.bool(in: rawDevice, path: ["gateway"]) ?? false,
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].osVersion",
          actual: parsedDevice.osVersion,
          expected: DictionaryValue.string(in: rawDevice, path: ["os_version"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].meshQualityBars",
          actual: parsedDevice.meshQualityBars,
          expected: DictionaryValue.int(in: rawDevice, path: ["mesh_quality_bars"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].wiredBackhaul",
          actual: parsedDevice.wiredBackhaul,
          expected: DictionaryValue.bool(in: rawDevice, path: ["wired"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].connectedClientCount",
          actual: parsedDevice.connectedClientCount,
          expected: DictionaryValue.int(in: rawDevice, path: ["connected_clients_count"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].connectedWiredClientCount",
          actual: parsedDevice.connectedWiredClientCount,
          expected: DictionaryValue.int(in: rawDevice, path: ["connected_wired_clients_count"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
        compare(
          path: "network[\(network.id)] device[\(parsedDevice.id)].connectedWirelessClientCount",
          actual: parsedDevice.connectedWirelessClientCount,
          expected: DictionaryValue.int(in: rawDevice, path: ["connected_wireless_clients_count"]),
          mismatches: &mismatches,
          comparisons: &comparisons
        )
      }
    }

    var report: [String] = []
    report.append("Live Raw Payload Parity")
    report.append("Fetched At: \(result.snapshot.fetchedAt.ISO8601Format())")
    report.append("Networks: \(result.snapshot.networks.count)")
    report.append("Raw Payloads: \(result.rawNetworks.count)")
    report.append("Comparisons: \(comparisons)")
    report.append("Mismatches: \(mismatches.count)")
    if mismatches.isEmpty {
      report.append("Status: PASS")
    } else {
      report.append("Status: FAIL")
      report.append(contentsOf: mismatches.map { "- \($0)" })
    }

    let rendered = report.joined(separator: "\n")
    await MainActor.run {
      XCTContext.runActivity(named: "live raw payload parity") { activity in
        activity.add(XCTAttachment(string: rendered))
      }
    }
    print(rendered)

    XCTAssertTrue(mismatches.isEmpty, rendered)
  }

  func testDisplayMetricConfidenceAuditAgainstThirdPartyOut() throws {
    guard let outURL = thirdPartyOutURLFromEnvironmentOrDefault() else {
      throw XCTSkip("No third-party out path configured.")
    }
    guard FileManager.default.fileExists(atPath: outURL.path) else {
      throw XCTSkip("third-party out directory not found at \(outURL.path)")
    }

    let parserSource = try loadParserSource()
    let dashboardSource = try loadSourceFile(
      relativePath: "Sources/EeroControl/Views/DashboardView.swift")
    let clientsSource = try loadSourceFile(
      relativePath: "Sources/EeroControl/Views/ClientsView.swift")
    let networkViewSource = try loadSourceFile(
      relativePath: "Sources/EeroControl/Views/NetworkView.swift")
    let uiSource = [dashboardSource, clientsSource, networkViewSource].joined(separator: "\n")

    enum Confidence: String {
      case direct
      case derived
      case proxy
    }

    struct DisplayMetricAuditCase {
      let id: String
      let confidence: Confidence
      let outIndicators: [String]
      let parserIndicators: [String]
      let uiIndicators: [String]
      let note: String
    }

    let metrics: [DisplayMetricAuditCase] = [
      DisplayMetricAuditCase(
        id: "dashboard.network_status",
        confidence: .direct,
        outIndicators: ["\"status\"", "2.2/networks/{networkId}/devices"],
        parserIndicators: [
          "DictionaryValue.string(in: data, path: [\"status\"])", "network.status",
        ],
        uiIndicators: ["title: \"Status\"", "network.status ?? \"Unavailable\""],
        note: "Network status text from network payload."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.clients_online",
        confidence: .derived,
        outIndicators: ["\"connected\"", "2.2/networks/{networkId}/devices"],
        parserIndicators: ["clients.filter(\\.connected).count", "connectedClientsCount"],
        uiIndicators: ["title: \"Clients Online\"", "network.connectedClientsCount"],
        note: "Derived count from devices payload connected flags."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.guest_lan",
        confidence: .direct,
        outIndicators: ["guestnetwork", "2.2/networks/{networkId}/guestnetwork"],
        parserIndicators: ["guestNetworkEnabled", "[\"guest_network\", \"enabled\"]"],
        uiIndicators: ["title: \"Guest LAN\"", "network.guestNetworkEnabled"],
        note: "Guest network state + SSID."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.last_speed_test",
        confidence: .direct,
        outIndicators: ["2.2/networks/{networkId}/speedtest", "down_mbps", "up_mbps"],
        parserIndicators: ["parseSpeedTestRecord", "[\"speedtest\"]"],
        uiIndicators: ["title: \"Last Speed Test\"", "speedPairText(network)"],
        note: "Last recorded speed test, not live throughput."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.traffic_timeline",
        confidence: .proxy,
        outIndicators: ["down_mbps", "up_mbps", "DeviceUsage.smali"],
        parserIndicators: ["parseRealtimeSummary", "sourceLabel: \"eero client telemetry\""],
        uiIndicators: [
          "SectionCard(title: \"Traffic Timeline\")", "metricPill(icon: \"arrow.down\"",
        ],
        note: "Summed client telemetry proxy; may differ from WAN throughput."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.busiest_devices",
        confidence: .direct,
        outIndicators: [
          "2.2/networks/{networkId}/data_usage/devices",
          "2.2/networks/{networkId}/data_usage/devices/{deviceMac}",
          "data_usage_day",
          "data_usage_week",
          "data_usage_month",
        ],
        parserIndicators: [
          "fetchDeviceUsageSnapshot", "fetchDeviceUsageTimelines", "parseTopDeviceUsage",
        ],
        uiIndicators: ["SectionCard(title: \"Busiest Devices\")", "usageEntries(for: network"],
        note: "Device usage rollups + timeline endpoint."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.mesh_summary",
        confidence: .derived,
        outIndicators: ["2.2/networks/{networkId}/eeros", "wireless_devices", "ports.interfaces"],
        parserIndicators: ["NetworkMeshSummary", "onlineEeroCount", "wiredBackhaulCount"],
        uiIndicators: [
          "SectionCard(title: \"Mesh and Radio Analytics\")", "eero Nodes", "Backhaul",
        ],
        note: "Derived from eero list and per-eero connections."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.channel_utilization",
        confidence: .direct,
        outIndicators: [
          "2.2/networks/{network}/channel_utilization", "channel_utilization_average_utilization",
        ],
        parserIndicators: ["fetchChannelUtilizationSnapshot", "parseChannelUtilizationSummary"],
        uiIndicators: ["channelUtilization", "radioLabel("],
        note: "Radio analytics from channel utilization endpoint."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.proxied_nodes",
        confidence: .direct,
        outIndicators: ["2.2/networks/{network}/proxied_nodes", "proxied_nodes_enabled_card"],
        parserIndicators: ["parseProxiedNodesSummary", "[\"proxied_nodes\"]"],
        uiIndicators: ["Proxied Nodes", "network.proxiedNodes"],
        note: "Node proxy state from proxied_nodes endpoint."
      ),
      DisplayMetricAuditCase(
        id: "dashboard.router_ports",
        confidence: .direct,
        outIndicators: [
          "device_connections", "2.2/eeros/{id}/ports/{interface_number}/action",
          "wireless_devices",
        ],
        parserIndicators: [
          "connections", "ports.interfaces", "wireless_devices", "ethernetStatuses",
        ],
        uiIndicators: ["SectionCard(title: \"Router and Port Stats\")", "device.ethernetStatuses"],
        note: "Port + attachment stats from expanded eero connections."
      ),
      DisplayMetricAuditCase(
        id: "clients.segment_primary_guest",
        confidence: .direct,
        outIndicators: ["\"is_guest\""],
        parserIndicators: ["isGuest: DictionaryValue.bool(in: data, path: [\"is_guest\"])"],
        uiIndicators: ["Segment\", value: client.isGuest ? \"Guest LAN\" : \"Primary LAN\""],
        note: "Client segment labeling from is_guest field."
      ),
      DisplayMetricAuditCase(
        id: "network.realtime_throughput_row",
        confidence: .proxy,
        outIndicators: ["down_mbps", "up_mbps", "live_data_usage"],
        parserIndicators: ["parseRealtimeSummary", "eero client telemetry"],
        uiIndicators: ["Realtime Throughput (eero)", "Telemetry Source"],
        note: "Network tab realtime row uses client-summed proxy."
      ),
    ]

    let outIndicatorSet = Set(metrics.flatMap(\.outIndicators))
    let outMatches = try scanOutCorpus(for: outIndicatorSet, in: outURL)

    var unsupported: [String] = []
    var proxyMetrics: [String] = []
    var lines: [String] = []
    lines.append("Display Metric Confidence Audit")
    lines.append("Out Path: \(outURL.path)")
    lines.append("Metrics: \(metrics.count)")
    lines.append("")

    for metric in metrics {
      let outEvidence = metric.outIndicators.contains { outMatches[$0] == true }
      let parserEvidence = metric.parserIndicators.contains { parserSource.contains($0) }
      let uiEvidence = metric.uiIndicators.contains { uiSource.contains($0) }

      let status: String
      if outEvidence, parserEvidence, uiEvidence {
        status = "OK"
      } else {
        status = "UNSUPPORTED"
        unsupported.append(metric.id)
      }

      if metric.confidence == .proxy {
        proxyMetrics.append(metric.id)
      }

      lines.append(
        "- \(metric.id) [\(metric.confidence.rawValue)] \(status) · out=\(yesNo(outEvidence)) parser=\(yesNo(parserEvidence)) ui=\(yesNo(uiEvidence))"
      )
      lines.append("  note: \(metric.note)")
    }

    lines.append("")
    lines.append("Summary")
    lines.append("- Unsupported metrics: \(unsupported.count)")
    lines.append("- Proxy metrics: \(proxyMetrics.count)")

    let strictProxyMode = boolEnvironment("EERO_DISPLAY_AUDIT_STRICT", defaultValue: false)
    if strictProxyMode, !proxyMetrics.isEmpty {
      lines.append("- Strict proxy mode: enabled")
      lines.append("- Proxy IDs: \(proxyMetrics.joined(separator: ", "))")
    } else {
      lines.append("- Strict proxy mode: disabled")
    }

    let rendered = lines.joined(separator: "\n")
    XCTContext.runActivity(named: "display metric confidence audit") { activity in
      activity.add(XCTAttachment(string: rendered))
    }
    print(rendered)

    XCTAssertTrue(
      unsupported.isEmpty,
      "Display metrics without third-party/parser/ui evidence: \(unsupported.joined(separator: ", "))"
    )

    if strictProxyMode {
      XCTAssertTrue(
        proxyMetrics.isEmpty,
        "Proxy metrics detected under strict mode: \(proxyMetrics.joined(separator: ", "))"
      )
    }
  }

  func testLivePortSpeedDiagnostics() async throws {
    let enabled =
      boolEnvironment("EERO_DEBUG_PORT_SPEEDS", defaultValue: false)
      || boolEnvironment("EERO_MODEL_AUDIT_PORT_SPEEDS", defaultValue: false)
    if !enabled {
      throw XCTSkip("Set EERO_MODEL_AUDIT_PORT_SPEEDS=1 to run live port speed diagnostics.")
    }

    let credentialStore = KeychainCredentialStore()
    guard let token = try credentialStore.loadUserToken(), !token.isEmpty else {
      throw XCTSkip("No stored user token found in keychain for live port speed diagnostics.")
    }

    let client = EeroAPIClient(session: .shared)
    await client.setUserToken(token)
    let result = try await client.fetchAccountWithRawPayloads(config: UpdateConfig())

    guard let network = result.snapshot.networks.first,
      let rawPayload = result.rawNetworks.first?.payload,
      let rawNetwork = try JSONSerialization.jsonObject(with: rawPayload) as? [String: Any]
    else {
      throw XCTSkip("Unable to decode live raw payload for diagnostics.")
    }

    let rawEeros = DictionaryValue.dictArray(in: rawNetwork, path: ["eeros", "data"])
    let parsedByMAC: [String: EeroDevice] = Dictionary(
      uniqueKeysWithValues: network.devices.compactMap { device in
        let mac = normalizeLookupKey(device.macAddress)
        guard !mac.isEmpty else { return nil }
        return (mac, device)
      })

    var lines: [String] = []
    lines.append("Live Port Speed Diagnostics")
    lines.append("Fetched At: \(result.snapshot.fetchedAt.ISO8601Format())")
    lines.append("Network: \(network.displayName)")
    lines.append("")

    let parsedClientRateCount = network.clients.reduce(into: (rx: 0, tx: 0)) { counts, client in
      if client.rxRateMbps != nil { counts.rx += 1 }
      if client.txRateMbps != nil { counts.tx += 1 }
    }
    let rawClientRows = DictionaryValue.dictArray(in: rawNetwork, path: ["devices", "data"])
    let rawClientRateCount = rawClientRows.reduce(into: (rx: 0, tx: 0, rxBitrate: 0, txBitrate: 0))
    { counts, row in
      let connectivity = DictionaryValue.dict(in: row, path: ["connectivity"]) ?? [:]
      if DictionaryValue.value(in: connectivity, path: ["rx_rate_info", "rate_bps"]) != nil
        || DictionaryValue.value(in: connectivity, path: ["rx_rate", "rate_bps"]) != nil
      {
        counts.rx += 1
      }
      if DictionaryValue.value(in: connectivity, path: ["tx_rate_info", "rate_bps"]) != nil
        || DictionaryValue.value(in: connectivity, path: ["tx_rate", "rate_bps"]) != nil
      {
        counts.tx += 1
      }
      if DictionaryValue.value(in: connectivity, path: ["rx_bitrate"]) != nil {
        counts.rxBitrate += 1
      }
      if DictionaryValue.value(in: connectivity, path: ["tx_bitrate"]) != nil {
        counts.txBitrate += 1
      }
    }
    lines.append(
      "raw client rate fields: rx_rate_bps=\(rawClientRateCount.rx) tx_rate_bps=\(rawClientRateCount.tx) rx_bitrate=\(rawClientRateCount.rxBitrate) tx_bitrate=\(rawClientRateCount.txBitrate)"
    )
    lines.append(
      "parsed client rates: rxRateMbps=\(parsedClientRateCount.rx) txRateMbps=\(parsedClientRateCount.tx)"
    )
    lines.append("")

    for rawEero in rawEeros {
      let name =
        DictionaryValue.string(in: rawEero, path: ["location"])
        ?? DictionaryValue.string(in: rawEero, path: ["nickname"])
        ?? "eero"
      let mac = DictionaryValue.string(in: rawEero, path: ["mac_address"]) ?? "unknown-mac"
      let parsed = parsedByMAC[normalizeLookupKey(mac)]

      lines.append("eero: \(name) (\(mac))")
      lines.append(
        "parsed speedTags: \(parsed?.ethernetStatuses.map { "\($0.portName ?? "?")=\($0.speedTag ?? "nil")" }.joined(separator: ", ") ?? "no parsed device match")"
      )

      let legacyStatuses = DictionaryValue.dictArray(
        in: rawEero, path: ["ethernet_status", "statuses"])
      if legacyStatuses.isEmpty {
        lines.append("raw legacy statuses: none")
      } else {
        let values = legacyStatuses.map { status in
          let port =
            DictionaryValue.string(in: status, path: ["port_name"])
            ?? DictionaryValue.int(in: status, path: ["interfaceNumber"]).map(String.init)
            ?? "?"
          let speed = DictionaryValue.string(in: status, path: ["speed"]) ?? "nil"
          let carrier =
            DictionaryValue.bool(in: status, path: ["hasCarrier"]).map { String($0) } ?? "nil"
          return "\(port)=\(speed) carrier=\(carrier)"
        }.joined(separator: ", ")
        lines.append("raw legacy statuses: \(values)")
      }

      let connectionInterfaces = DictionaryValue.dictArray(
        in: rawEero, path: ["connections", "ports", "interfaces"])
      if connectionInterfaces.isEmpty {
        lines.append("raw connection interfaces: none")
      } else {
        let values = connectionInterfaces.map { interface in
          let port =
            DictionaryValue.string(in: interface, path: ["name"])
            ?? DictionaryValue.string(in: interface, path: ["port_name"])
            ?? DictionaryValue.int(in: interface, path: ["interface_number"]).map(String.init)
            ?? "?"
          let negotiated =
            DictionaryValue.string(in: interface, path: ["negotiated_speed"]) ?? "nil"
          let supported = DictionaryValue.string(in: interface, path: ["supported_speed"]) ?? "nil"
          let status = DictionaryValue.string(in: interface, path: ["port_status"]) ?? "nil"
          return "\(port)=negotiated:\(negotiated) supported:\(supported) status:\(status)"
        }.joined(separator: ", ")
        lines.append("raw connection interfaces: \(values)")
      }

      lines.append("")
    }

    let rendered = lines.joined(separator: "\n")
    await MainActor.run {
      XCTContext.runActivity(named: "live port speed diagnostics") { activity in
        activity.add(XCTAttachment(string: rendered))
      }
    }
    print(rendered)
  }

  private func thirdPartyOutURLFromEnvironmentOrDefault() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if let override = env["EERO_THIRD_PARTY_OUT_PATH"]?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return URL(fileURLWithPath: override)
    }

    guard let root = repositoryRootURL() else {
      return nil
    }

    let candidates = [
      root.appendingPathComponent("third-party/out"),
      root.appendingPathComponent("third-party/eero-app/out"),
    ]

    return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
  }

  private func repositoryRootURL() -> URL? {
    // XCTest often launches from DerivedData, so anchor on this test file first.
    let sourceAnchor = URL(fileURLWithPath: #filePath, isDirectory: false)
      .deletingLastPathComponent()
    if let root = walkUpToGitRoot(from: sourceAnchor) {
      return root
    }

    let workingDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return walkUpToGitRoot(from: workingDirectory)
  }

  private func walkUpToGitRoot(from start: URL) -> URL? {
    var current = start
    for _ in 0..<16 {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        break
      }
      current = parent
    }
    return nil
  }

  private func loadParserSource() throws -> String {
    guard let root = repositoryRootURL() else {
      throw XCTSkip("Unable to locate repository root for parser cross-reference.")
    }
    let parserFile = root.appendingPathComponent("Sources/EeroControl/Services/EeroAPIClient.swift")
    return try String(contentsOf: parserFile, encoding: .utf8)
  }

  private func loadSourceFile(relativePath: String) throws -> String {
    guard let root = repositoryRootURL() else {
      throw XCTSkip("Unable to locate repository root for source load.")
    }
    let sourceFile = root.appendingPathComponent(relativePath)
    return try String(contentsOf: sourceFile, encoding: .utf8)
  }

  private func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
  }

  private func makeLookupMap(
    rows: [[String: Any]],
    keys: ([String: Any]) -> [String]
  ) -> [String: [String: Any]] {
    var map: [String: [String: Any]] = [:]
    for row in rows {
      for key in keys(row) where !key.isEmpty {
        map[key, default: row] = row
      }
    }
    return map
  }

  private func firstMatchedRow(
    for keys: [String],
    in map: [String: [String: Any]]
  ) -> [String: Any]? {
    for key in keys where !key.isEmpty {
      if let row = map[key] {
        return row
      }
    }
    return nil
  }

  private func rawClientLookupKeys(_ row: [String: Any]) -> [String] {
    let url = DictionaryValue.string(in: row, path: ["url"])
    let resourceURL = DictionaryValue.string(in: row, path: ["resource_url"])
    return [
      normalizeLookupKey(DictionaryValue.id(fromURL: url)),
      normalizeLookupKey(DictionaryValue.id(fromURL: resourceURL)),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["mac"])),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["ip"])),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["ipv4"])),
    ]
  }

  private func parsedClientLookupKeys(_ client: EeroClient) -> [String] {
    [
      normalizeLookupKey(client.id),
      normalizeLookupKey(client.mac),
      normalizeLookupKey(client.ip),
      normalizeLookupKey(DictionaryValue.id(fromURL: client.sourceURL)),
    ]
  }

  private func rawDeviceLookupKeys(_ row: [String: Any]) -> [String] {
    let url = DictionaryValue.string(in: row, path: ["url"])
    return [
      normalizeLookupKey(DictionaryValue.id(fromURL: url)),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["mac_address"])),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["ip_address"])),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["ip"])),
      normalizeLookupKey(DictionaryValue.string(in: row, path: ["serial"])),
    ]
  }

  private func parsedDeviceLookupKeys(_ device: EeroDevice) -> [String] {
    [
      normalizeLookupKey(device.id),
      normalizeLookupKey(device.macAddress),
      normalizeLookupKey(device.ipAddress),
      normalizeLookupKey(device.serial),
    ]
  }

  private func normalizeLookupKey(_ value: String?) -> String {
    value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
  }

  private func normalizeMAC(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: ":")
      .uppercased()
    return normalized.isEmpty ? nil : normalized
  }

  private func gatewayIPFromRawEeros(_ network: [String: Any]) -> String? {
    let rawDevices = DictionaryValue.dictArray(in: network, path: ["eeros", "data"])
    for device in rawDevices {
      guard DictionaryValue.bool(in: device, path: ["gateway"]) ?? false else {
        continue
      }
      if let ip = DictionaryValue.string(in: device, path: ["ip_address"])
        ?? DictionaryValue.string(in: device, path: ["ip"])
      {
        return ip
      }
    }
    return nil
  }

  private func firstDouble(in row: [String: Any], paths: [[String]]) -> Double? {
    for path in paths {
      if let value = DictionaryValue.double(in: row, path: path) {
        return value
      }
    }
    return nil
  }

  private func firstRateMbps(in row: [String: Any], pathPrefixes: [[String]]) -> Double? {
    for prefix in pathPrefixes {
      if let direct = rateToMbps(DictionaryValue.value(in: row, path: prefix)) {
        return direct
      }
      if let mbps = rateToMbps(DictionaryValue.value(in: row, path: prefix + ["rate_mbps"]))
        ?? rateToMbps(DictionaryValue.value(in: row, path: prefix + ["mbps"]))
        ?? rateToMbps(DictionaryValue.value(in: row, path: prefix + ["rate"]))
      {
        return mbps
      }
      if let bps = DictionaryValue.double(in: row, path: prefix + ["rate_bps"])
        ?? DictionaryValue.double(in: row, path: prefix + ["bps"])
      {
        return bps / 1_000_000
      }
    }
    return nil
  }

  private func rateToMbps(_ value: Any?) -> Double? {
    if let dict = value as? [String: Any] {
      if let mbps = DictionaryValue.double(in: dict, path: ["rate_mbps"])
        ?? DictionaryValue.double(in: dict, path: ["mbps"])
      {
        return mbps
      }
      if let bps = DictionaryValue.double(in: dict, path: ["rate_bps"])
        ?? DictionaryValue.double(in: dict, path: ["bps"])
      {
        return bps / 1_000_000
      }
      if let nested = dict["rate"], let mbps = rateToMbps(nested) {
        return mbps
      }
      if let nested = dict["value"], let mbps = rateToMbps(nested) {
        return mbps
      }
    }
    if let text = value as? String,
      let parsed = parseRateStringInMbps(text)
    {
      return parsed
    }
    if let number = value as? NSNumber {
      let numeric = number.doubleValue
      return numeric > 100_000 ? numeric / 1_000_000 : numeric
    }
    return nil
  }

  private func parseRateStringInMbps(_ text: String) -> Double? {
    let normalized = text.lowercased().replacingOccurrences(of: " ", with: "")
    guard
      let numberRange = normalized.range(of: #"[-+]?[0-9]*\.?[0-9]+"#, options: .regularExpression),
      let number = Double(normalized[numberRange]),
      number.isFinite
    else {
      return nil
    }

    let unit = String(normalized[numberRange.upperBound...])
    if unit.isEmpty {
      return number > 100_000 ? (number / 1_000_000) : number
    }
    if unit.contains("gbit/s") || unit.contains("gbitps") || unit.contains("gbps") {
      return number * 1_000
    }
    if unit.contains("mbit/s") || unit.contains("mbitps") || unit.contains("mbps") {
      return number
    }
    if unit.contains("kbit/s") || unit.contains("kbitps") || unit.contains("kbps") {
      return number / 1_000
    }
    if unit.contains("bit/s") || unit.contains("bps") {
      return number / 1_000_000
    }
    return number > 100_000 ? (number / 1_000_000) : number
  }

  private func firstInt(in row: [String: Any], paths: [[String]]) -> Int? {
    for path in paths {
      if let value = DictionaryValue.int(in: row, path: path) {
        return value
      }
    }
    return nil
  }

  private func compare<T: Equatable>(
    path: String,
    actual: T,
    expected: T,
    mismatches: inout [String],
    comparisons: inout Int
  ) {
    comparisons += 1
    if actual != expected {
      mismatches.append(
        "\(path) expected=\(String(describing: expected)) actual=\(String(describing: actual))")
    }
  }

  private func compare<T: Equatable>(
    path: String,
    actual: T?,
    expected: T?,
    mismatches: inout [String],
    comparisons: inout Int
  ) {
    comparisons += 1
    if actual != expected {
      mismatches.append(
        "\(path) expected=\(String(describing: expected)) actual=\(String(describing: actual))")
    }
  }

  private func compareMAC(
    path: String,
    actual: String?,
    expected: String?,
    mismatches: inout [String],
    comparisons: inout Int
  ) {
    compare(
      path: path,
      actual: normalizeMAC(actual),
      expected: normalizeMAC(expected),
      mismatches: &mismatches,
      comparisons: &comparisons
    )
  }

  private func compareDouble(
    path: String,
    actual: Double?,
    expected: Double?,
    mismatches: inout [String],
    comparisons: inout Int
  ) {
    comparisons += 1
    let tolerance = 0.000_1
    switch (actual, expected) {
    case (nil, nil):
      break
    case (let lhs?, let rhs?):
      if abs(lhs - rhs) > tolerance {
        mismatches.append("\(path) expected=\(rhs) actual=\(lhs)")
      }
    default:
      mismatches.append(
        "\(path) expected=\(String(describing: expected)) actual=\(String(describing: actual))")
    }
  }

  private func scanOutCorpus(for indicators: Set<String>, in outURL: URL) throws -> [String: Bool] {
    var matches = Dictionary(uniqueKeysWithValues: indicators.map { ($0, false) })
    var remaining = indicators
    if remaining.isEmpty {
      return matches
    }

    let fileManager = FileManager.default
    let allowedExtensions: Set<String> = ["smali", "xml", "json", "txt", "proto"]
    guard
      let enumerator = fileManager.enumerator(
        at: outURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw XCTSkip("Unable to enumerate third-party out directory at \(outURL.path)")
    }

    for case let fileURL as URL in enumerator {
      if remaining.isEmpty {
        break
      }

      guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
        continue
      }

      let fileData: Data
      do {
        fileData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
      } catch {
        continue
      }

      var foundInThisFile: [String] = []
      for indicator in remaining {
        if fileData.range(of: Data(indicator.utf8)) != nil {
          matches[indicator] = true
          foundInThisFile.append(indicator)
        }
      }
      remaining.subtract(foundInThisFile)
    }

    return matches
  }
}

private struct CoverageReport {
  private struct Counter {
    var populated: Int = 0
    var total: Int = 0

    mutating func add(hasValue: Bool) {
      total += 1
      if hasValue {
        populated += 1
      }
    }

    var percent: Double {
      guard total > 0 else { return 0 }
      return (Double(populated) / Double(total)) * 100
    }

    var summary: String {
      let percentText = String(format: "%.1f%%", percent)
      return "\(populated)/\(total) (\(percentText))"
    }
  }

  let snapshot: EeroAccountSnapshot
  let sourceURL: URL
  let endpointAudit: ModelFieldAuditSummary?

  private var networkCounters: [String: Counter] = [:]
  private var clientCounters: [String: Counter] = [:]
  private var deviceCounters: [String: Counter] = [:]

  init(snapshot: EeroAccountSnapshot, sourceURL: URL) {
    self.snapshot = snapshot
    self.sourceURL = sourceURL
    self.endpointAudit = snapshot.modelAudit
    self.networkCounters = Self.collectNetworkCounters(from: snapshot)
    self.clientCounters = Self.collectClientCounters(from: snapshot)
    self.deviceCounters = Self.collectDeviceCounters(from: snapshot)
  }

  var criticalGaps: [String] {
    let criticalKeys: [String] = [
      "network.status",
      "network.gateway_ip",
      "client.mac",
      "client.ip",
      "client.source_location",
      "device.status",
      "device.mac_address",
      "device.ip_address",
    ]

    var all: [String: Counter] = [:]
    for (key, value) in networkCounters {
      all["network.\(key)"] = value
    }
    for (key, value) in clientCounters {
      all["client.\(key)"] = value
    }
    for (key, value) in deviceCounters {
      all["device.\(key)"] = value
    }

    return criticalKeys.filter { key in
      guard let counter = all[key], counter.total > 0 else {
        return false
      }
      return counter.populated == 0
    }
  }

  func render(iteration: Int, totalIterations: Int) -> String {
    let networks = snapshot.networks
    let clients = networks.flatMap(\.clients)
    let devices = networks.flatMap(\.devices)

    var lines: [String] = []
    lines.append("Stored Account Model Coverage \(iteration)/\(totalIterations)")
    lines.append("Source: \(sourceURL.path)")
    lines.append("Fetched At: \(snapshot.fetchedAt.ISO8601Format())")
    lines.append(
      "Networks: \(networks.count) | Clients: \(clients.count) | eero Devices: \(devices.count)")
    if let endpointAudit {
      lines.append("Endpoint Evidence: available (\(endpointAudit.generatedAt.ISO8601Format()))")
    } else {
      lines.append("Endpoint Evidence: unavailable (refresh snapshot with current app build)")
    }
    lines.append("")
    lines.append("Network Fields")
    lines.append(contentsOf: sortedLines(prefix: "network", counters: networkCounters))
    lines.append("")
    lines.append("Client Fields")
    lines.append(contentsOf: sortedLines(prefix: "client", counters: clientCounters))
    lines.append("")
    lines.append("Device Fields")
    lines.append(contentsOf: sortedLines(prefix: "device", counters: deviceCounters))
    lines.append("")

    let gapLines = potentialGaps()
    if gapLines.isEmpty {
      lines.append("Potential Gaps: none")
    } else {
      lines.append("Potential Gaps")
      lines.append(contentsOf: gapLines.map { "- \($0)" })
    }

    if !criticalGaps.isEmpty {
      lines.append("")
      lines.append("Critical Gaps")
      lines.append(contentsOf: criticalGaps.map { "- \($0)" })
    }

    return lines.joined(separator: "\n")
  }

  private func sortedLines(prefix: String, counters: [String: Counter]) -> [String] {
    counters
      .sorted { lhs, rhs in
        if lhs.value.percent == rhs.value.percent {
          return lhs.key < rhs.key
        }
        return lhs.value.percent > rhs.value.percent
      }
      .map { key, counter in
        "- \(prefix).\(key): \(counter.summary)"
      }
  }

  private func potentialGaps() -> [String] {
    var lines: [String] = []
    for (key, counter) in networkCounters where counter.total > 0 && counter.populated == 0 {
      lines.append(gapLine(prefix: "network", key: key, counter: counter))
    }
    for (key, counter) in clientCounters where counter.total > 0 && counter.populated == 0 {
      lines.append(gapLine(prefix: "client", key: key, counter: counter))
    }
    for (key, counter) in deviceCounters where counter.total > 0 && counter.populated == 0 {
      lines.append(gapLine(prefix: "device", key: key, counter: counter))
    }
    return lines.sorted()
  }

  private func gapLine(prefix: String, key: String, counter: Counter) -> String {
    " \(prefix).\(key) is 0% populated (\(endpointAssessment(prefix: prefix, key: key, modelCounter: counter)))"
      .trimmingCharacters(in: .whitespaces)
  }

  private func endpointAssessment(prefix: String, key: String, modelCounter: Counter) -> String {
    guard let endpointCounter = endpointCounter(prefix: prefix, key: key) else {
      return "no endpoint evidence"
    }
    guard endpointCounter.total > 0 else {
      return "endpoint not sampled"
    }
    if endpointCounter.present > 0, modelCounter.populated == 0 {
      return
        "endpoint has data \(endpointCounter.present)/\(endpointCounter.total), likely mapping gap"
    }
    return "endpoint empty \(endpointCounter.present)/\(endpointCounter.total)"
  }

  private func endpointCounter(prefix: String, key: String) -> ModelFieldAuditCounter? {
    switch prefix {
    case "network":
      return endpointAudit?.networkFields[key]
    case "client":
      return endpointAudit?.clientFields[key]
    case "device":
      return endpointAudit?.deviceFields[key]
    default:
      return nil
    }
  }

  private static func collectNetworkCounters(from snapshot: EeroAccountSnapshot) -> [String:
    Counter]
  {
    var counters: [String: Counter] = [:]
    for network in snapshot.networks {
      recordString(network.status, in: &counters, key: "status")
      recordString(network.gatewayIP ?? network.mesh?.gatewayIP, in: &counters, key: "gateway_ip")
      recordString(network.guestNetworkName, in: &counters, key: "guest_network_name")
      recordBool(network.backupInternetEnabled, in: &counters, key: "backup_internet_enabled")
      recordBool(network.features.adBlock, in: &counters, key: "feature_ad_block")
      recordBool(network.features.blockMalware, in: &counters, key: "feature_malware")
      recordBool(network.features.upnp, in: &counters, key: "feature_upnp")
      recordBool(network.features.threadEnabled, in: &counters, key: "feature_thread")
      recordString(network.health.internetStatus, in: &counters, key: "health_internet_status")
      recordString(network.health.eeroNetworkStatus, in: &counters, key: "health_mesh_status")
      recordString(network.diagnostics.status, in: &counters, key: "diagnostics_status")
      recordString(network.updates.targetFirmware, in: &counters, key: "updates_target_firmware")
      recordString(network.updates.updateStatus, in: &counters, key: "updates_status")
      recordString(network.speed.measuredAt, in: &counters, key: "speed_measured_at")
      recordString(network.support.supportPhone, in: &counters, key: "support_phone")
      recordPresent(network.threadDetails, in: &counters, key: "thread_details")
      recordPresent(network.mesh, in: &counters, key: "mesh_summary")
      recordPresent(network.wirelessCongestion, in: &counters, key: "wireless_congestion")
      recordPresent(network.activity, in: &counters, key: "activity_summary")
      recordPresent(network.realtime, in: &counters, key: "realtime_summary")
      recordPresent(network.channelUtilization, in: &counters, key: "channel_utilization")
      recordPresent(network.proxiedNodes, in: &counters, key: "proxied_nodes")
    }
    return counters
  }

  private static func collectClientCounters(from snapshot: EeroAccountSnapshot) -> [String: Counter]
  {
    var counters: [String: Counter] = [:]
    for client in snapshot.networks.flatMap(\.clients) {
      recordString(client.mac, in: &counters, key: "mac")
      recordString(client.ip, in: &counters, key: "ip")
      recordBool(client.wireless, in: &counters, key: "wireless")
      recordString(client.connectionType, in: &counters, key: "connection_type")
      recordString(client.signal, in: &counters, key: "signal")
      recordPresent(client.scoreBars, in: &counters, key: "signal_bars")
      recordPresent(client.channel, in: &counters, key: "channel")
      recordString(client.manufacturer, in: &counters, key: "manufacturer")
      recordString(client.deviceType, in: &counters, key: "device_type")
      recordString(client.lastActive, in: &counters, key: "last_active")
      recordBool(client.isPrivate, in: &counters, key: "private_address")
      recordString(client.interfaceFrequency, in: &counters, key: "interface_frequency")
      recordString(client.interfaceFrequencyUnit, in: &counters, key: "interface_frequency_unit")
      recordString(client.rxChannelWidth, in: &counters, key: "rx_channel_width")
      recordString(client.txChannelWidth, in: &counters, key: "tx_channel_width")
      recordPresent(client.rxRateMbps, in: &counters, key: "rx_rate_mbps")
      recordPresent(client.txRateMbps, in: &counters, key: "tx_rate_mbps")
      recordPresent(client.usageDownMbps, in: &counters, key: "usage_down_mbps")
      recordPresent(client.usageUpMbps, in: &counters, key: "usage_up_mbps")
      recordPresent(
        client.usageDownPercentCurrent, in: &counters, key: "usage_down_percent_current")
      recordPresent(client.usageUpPercentCurrent, in: &counters, key: "usage_up_percent_current")
      recordPresent(client.usageDayDownload, in: &counters, key: "usage_day_download")
      recordPresent(client.usageDayUpload, in: &counters, key: "usage_day_upload")
      recordPresent(client.usageWeekDownload, in: &counters, key: "usage_week_download")
      recordPresent(client.usageWeekUpload, in: &counters, key: "usage_week_upload")
      recordPresent(client.usageMonthDownload, in: &counters, key: "usage_month_download")
      recordPresent(client.usageMonthUpload, in: &counters, key: "usage_month_upload")
      recordString(client.sourceLocation, in: &counters, key: "source_location")
      recordString(client.sourceURL, in: &counters, key: "source_url")
    }
    return counters
  }

  private static func collectDeviceCounters(from snapshot: EeroAccountSnapshot) -> [String: Counter]
  {
    var counters: [String: Counter] = [:]
    for device in snapshot.networks.flatMap(\.devices) {
      recordString(device.status, in: &counters, key: "status")
      recordString(device.model, in: &counters, key: "model")
      recordString(device.modelNumber, in: &counters, key: "model_number")
      recordString(device.serial, in: &counters, key: "serial")
      recordString(device.macAddress, in: &counters, key: "mac_address")
      recordString(device.ipAddress, in: &counters, key: "ip_address")
      recordString(device.osVersion, in: &counters, key: "os_version")
      recordString(device.lastRebootAt, in: &counters, key: "last_reboot")
      recordPresent(device.connectedClientCount, in: &counters, key: "connected_clients_count")
      recordPresent(device.connectedWiredClientCount, in: &counters, key: "connected_wired_count")
      recordPresent(
        device.connectedWirelessClientCount, in: &counters, key: "connected_wireless_count")
      recordPresent(device.meshQualityBars, in: &counters, key: "mesh_quality_bars")
      recordBool(device.wiredBackhaul, in: &counters, key: "wired_backhaul")
      recordNonEmpty(device.wifiBands, in: &counters, key: "wifi_bands")
      recordNonEmpty(device.portDetails, in: &counters, key: "port_details")
      recordNonEmpty(device.ethernetStatuses, in: &counters, key: "ethernet_statuses")
      recordNonEmpty(device.wirelessAttachments, in: &counters, key: "wireless_attachments")
      recordPresent(device.usageDayDownload, in: &counters, key: "usage_day_download")
      recordPresent(device.usageDayUpload, in: &counters, key: "usage_day_upload")
      recordPresent(device.usageWeekDownload, in: &counters, key: "usage_week_download")
      recordPresent(device.usageWeekUpload, in: &counters, key: "usage_week_upload")
      recordPresent(device.usageMonthDownload, in: &counters, key: "usage_month_download")
      recordPresent(device.usageMonthUpload, in: &counters, key: "usage_month_upload")
    }
    return counters
  }

  private static func recordString(
    _ value: String?, in counters: inout [String: Counter], key: String
  ) {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var counter = counters[key] ?? Counter()
    counter.add(hasValue: !trimmed.isEmpty)
    counters[key] = counter
  }

  private static func recordPresent<T>(
    _ value: T?, in counters: inout [String: Counter], key: String
  ) {
    var counter = counters[key] ?? Counter()
    counter.add(hasValue: value != nil)
    counters[key] = counter
  }

  private static func recordBool(_ value: Bool?, in counters: inout [String: Counter], key: String)
  {
    var counter = counters[key] ?? Counter()
    counter.add(hasValue: value != nil)
    counters[key] = counter
  }

  private static func recordNonEmpty<T>(
    _ value: [T]?, in counters: inout [String: Counter], key: String
  ) {
    var counter = counters[key] ?? Counter()
    counter.add(hasValue: !(value?.isEmpty ?? true))
    counters[key] = counter
  }
}
