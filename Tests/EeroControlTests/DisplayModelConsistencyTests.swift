import XCTest

@testable import EeroControl

final class DisplayModelConsistencyTests: XCTestCase {
  func testDisplayModelConsistency_Fixtures_Strict() throws {
    guard let outURL = thirdPartyOutURLFromEnvironmentOrDefault() else {
      throw XCTSkip("No third-party out path configured.")
    }
    guard FileManager.default.fileExists(atPath: outURL.path) else {
      throw XCTSkip("third-party out directory not found at \(outURL.path)")
    }

    let strictProxyMode =
      boolEnvironment("EERO_DISPLAY_AUDIT_STRICT", defaultValue: false)
      || boolEnvironment("EERO_DISPLAY_CONSISTENCY_STRICT_PROXY", defaultValue: false)

    let report = try evaluateDisplayConsistency(
      cases: makeFixtureCases(),
      outURL: outURL,
      strictProxyMode: strictProxyMode,
      requireOutTraceability: true
    )

    try attach(report: report, activityName: "display model consistency fixture strict")

    XCTAssertTrue(
      report.failures.isEmpty,
      report.rendered
    )
  }

  func testDisplayModelConsistency_Live_Strict() async throws {
    let disableLive = boolEnvironment("EERO_DISPLAY_CONSISTENCY_DISABLE_LIVE", defaultValue: false)
    if disableLive {
      throw XCTSkip(
        "Live consistency validation disabled by EERO_DISPLAY_CONSISTENCY_DISABLE_LIVE=1.")
    }

    guard let outURL = thirdPartyOutURLFromEnvironmentOrDefault() else {
      throw XCTSkip("No third-party out path configured.")
    }
    guard FileManager.default.fileExists(atPath: outURL.path) else {
      throw XCTSkip("third-party out directory not found at \(outURL.path)")
    }

    let credentialStore = KeychainCredentialStore()
    guard let token = try credentialStore.loadUserToken(), !token.isEmpty else {
      throw XCTSkip("No stored user token found in keychain for live consistency validation.")
    }

    let client = EeroAPIClient(session: .shared)
    await client.setUserToken(token)
    let result = try await client.fetchAccountWithRawPayloads(config: UpdateConfig())

    let cases = liveCases(from: result)
    XCTAssertFalse(cases.isEmpty, "No live raw/model network pairs could be matched.")

    let strictProxyMode =
      boolEnvironment("EERO_DISPLAY_AUDIT_STRICT", defaultValue: false)
      || boolEnvironment("EERO_DISPLAY_CONSISTENCY_STRICT_PROXY", defaultValue: false)

    let report = try evaluateDisplayConsistency(
      cases: cases,
      outURL: outURL,
      strictProxyMode: strictProxyMode,
      requireOutTraceability: true
    )

    try attach(report: report, activityName: "display model consistency live strict")

    XCTAssertTrue(
      report.failures.isEmpty,
      report.rendered
    )
  }

  func testDisplayModelCoverage_NoUnmappedDisplayedFields() throws {
    let dashboardSource = try loadSourceFile(
      relativePath: "Sources/EeroControl/Views/DashboardView.swift")
    let clientsSource = try loadSourceFile(
      relativePath: "Sources/EeroControl/Views/ClientsView.swift")
    let networkSource = try loadSourceFile(
      relativePath: "Sources/EeroControl/Views/NetworkView.swift")

    let allIDs = Set(
      networkMetricContracts().map(\.id)
        + clientMetricContracts().map(\.id)
        + deviceMetricContracts().map(\.id)
    )

    let requiredMappings: [(source: String, snippet: String, metricID: String)] = [
      (dashboardSource, "title: \"Status\"", "dashboard.network_status"),
      (dashboardSource, "title: \"Clients Online\"", "dashboard.clients_online"),
      (dashboardSource, "title: \"Guest LAN\"", "dashboard.guest_lan_enabled"),
      (dashboardSource, "title: \"Last Speed Test\"", "dashboard.last_speedtest_down"),
      (
        dashboardSource, "SectionCard(title: \"Traffic Timeline\")",
        "dashboard.realtime_download_mbps_proxy"
      ),
      (
        dashboardSource, "SectionCard(title: \"Busiest Devices\")",
        "dashboard.busiest_devices_count"
      ),
      (
        dashboardSource, "SectionCard(title: \"Mesh and Radio Analytics\")",
        "dashboard.mesh_online_count"
      ),
      (
        dashboardSource, "SectionCard(title: \"Router and Port Stats\")",
        "device.connected_clients_count"
      ),
      (clientsSource, "label: \"Segment\"", "clients.segment_is_guest"),
      (clientsSource, "label: \"Connected To eero\"", "clients.source_location"),
      (clientsSource, "KeyValueRow(label: \"Live Usage\"", "clients.usage_down_mbps"),
      (
        networkSource,
        "label: \"Realtime Throughput (eero)\"",
        "dashboard.realtime_download_mbps_proxy"
      ),
      (networkSource, "label: \"Data Usage Today\"", "network.activity_day_download"),
      (
        networkSource,
        "label: \"Data Usage This Week\"",
        "network.activity_week_download"
      ),
      (
        networkSource,
        "label: \"Data Usage This Month\"",
        "network.activity_month_download"
      ),
    ]

    for mapping in requiredMappings {
      XCTAssertTrue(
        mapping.source.contains(mapping.snippet),
        "UI snippet not found for coverage mapping: \(mapping.snippet)"
      )
      XCTAssertTrue(
        allIDs.contains(mapping.metricID),
        "No display consistency contract mapped for metric ID: \(mapping.metricID)"
      )
    }
  }

  func testDisplayModelProxyPolicy() {
    let networkContracts = networkMetricContracts()
    let clientContracts = clientMetricContracts()
    let deviceContracts = deviceMetricContracts()

    let all =
      networkContracts.map { contract in
        ContractDescriptor(
          id: contract.id,
          provenance: contract.provenance,
          proxyAllowed: contract.proxyAllowed,
          outIndicators: contract.outIndicators
        )
      }
      + clientContracts.map { contract in
        ContractDescriptor(
          id: contract.id,
          provenance: contract.provenance,
          proxyAllowed: contract.proxyAllowed,
          outIndicators: contract.outIndicators
        )
      }
      + deviceContracts.map { contract in
        ContractDescriptor(
          id: contract.id,
          provenance: contract.provenance,
          proxyAllowed: contract.proxyAllowed,
          outIndicators: contract.outIndicators
        )
      }

    let proxyIDs = Set(all.filter { $0.provenance == MetricProvenance.proxy }.map { $0.id })
    let allowlistedProxyIDs: Set<String> = [
      "dashboard.realtime_download_mbps_proxy",
      "dashboard.realtime_upload_mbps_proxy",
    ]

    let nonAllowlisted = proxyIDs.subtracting(allowlistedProxyIDs)
    XCTAssertTrue(
      nonAllowlisted.isEmpty,
      "Proxy metrics are not allowlisted: \(nonAllowlisted.sorted().joined(separator: ", "))"
    )

    let disallowedButFlagged =
      all
      .filter { $0.provenance == MetricProvenance.proxy && !$0.proxyAllowed }
      .map { $0.id }
    XCTAssertTrue(
      disallowedButFlagged.isEmpty,
      "Proxy metrics are marked as disallowed in contract definitions: \(disallowedButFlagged.joined(separator: ", "))"
    )

    let strictProxyMode =
      boolEnvironment("EERO_DISPLAY_AUDIT_STRICT", defaultValue: false)
      || boolEnvironment("EERO_DISPLAY_CONSISTENCY_STRICT_PROXY", defaultValue: false)
    if strictProxyMode {
      XCTAssertTrue(
        proxyIDs.isEmpty,
        "Strict proxy mode enabled, but proxy-backed metrics still exist: \(proxyIDs.sorted().joined(separator: ", "))"
      )
    }
  }

  // MARK: - Core Evaluation

  private func evaluateDisplayConsistency(
    cases: [ConsistencyCase],
    outURL: URL?,
    strictProxyMode: Bool,
    requireOutTraceability: Bool
  ) throws -> ConsistencyReport {
    let networkContracts = networkMetricContracts()
    let clientContracts = clientMetricContracts()
    let deviceContracts = deviceMetricContracts()
    let descriptors = contractDescriptors(
      network: networkContracts, clients: clientContracts, devices: deviceContracts)

    let outIndicators = Set(descriptors.flatMap(\.outIndicators))
    let outMatches: [String: Bool]
    if let outURL {
      outMatches = try scanOutCorpus(for: outIndicators, in: outURL)
    } else {
      outMatches = [:]
    }

    var failures: [ConsistencyFailure] = []
    var evaluatedMetrics = 0
    var warnings: [String] = []

    if requireOutTraceability, outURL != nil {
      for descriptor in descriptors {
        let hasEvidence = descriptor.outIndicators.contains { outMatches[$0] == true }
        if !hasEvidence {
          failures.append(
            ConsistencyFailure(
              caseName: "contracts",
              metricID: descriptor.id,
              provenance: descriptor.provenance,
              detail:
                "No third-party/out traceability evidence matched indicators: \(descriptor.outIndicators.joined(separator: ", "))"
            )
          )
        }
      }
    }

    if strictProxyMode {
      let disallowed = descriptors.filter { $0.provenance == .proxy }
      if !disallowed.isEmpty {
        for proxy in disallowed {
          failures.append(
            ConsistencyFailure(
              caseName: "contracts",
              metricID: proxy.id,
              provenance: proxy.provenance,
              detail: "Strict proxy mode enabled but metric is proxy-backed."
            )
          )
        }
      }
    }

    for caseItem in cases {
      let network = caseItem.network
      let rawNetwork = caseItem.rawNetwork

      for contract in networkContracts {
        evaluatedMetrics += 1
        let expected = contract.expected(rawNetwork)
        let actual = contract.actual(network)
        let required = contract.required(rawNetwork)

        if let detail = metricMismatch(
          metricID: contract.id,
          expected: expected,
          actual: actual,
          required: required,
          tolerance: contract.tolerance,
          rawHint: contract.rawHint,
          modelHint: contract.modelHint
        ) {
          failures.append(
            ConsistencyFailure(
              caseName: caseItem.name,
              metricID: contract.id,
              provenance: contract.provenance,
              detail: detail
            )
          )
        }
      }

      let rawClients = DictionaryValue.dictArray(in: rawNetwork, path: ["devices", "data"])
      let rawClientMap = makeLookupMap(rows: rawClients, keys: rawClientLookupKeys)
      for client in network.clients {
        guard let rawClient = firstMatchedRow(for: parsedClientLookupKeys(client), in: rawClientMap)
        else {
          failures.append(
            ConsistencyFailure(
              caseName: caseItem.name,
              metricID: "clients.raw_match",
              provenance: .derived,
              detail: "Unable to match parsed client \(client.id) to raw client payload."
            )
          )
          continue
        }

        for contract in clientContracts {
          evaluatedMetrics += 1
          let expected = contract.expected(rawClient)
          let actual = contract.actual(client)
          let required = contract.required(rawClient)

          if let detail = metricMismatch(
            metricID: contract.id,
            expected: expected,
            actual: actual,
            required: required,
            tolerance: contract.tolerance,
            rawHint: contract.rawHint,
            modelHint: contract.modelHint
          ) {
            failures.append(
              ConsistencyFailure(
                caseName: "\(caseItem.name):client:\(client.id)",
                metricID: contract.id,
                provenance: contract.provenance,
                detail: detail
              )
            )
          }
        }
      }

      let rawDevices = DictionaryValue.dictArray(in: rawNetwork, path: ["eeros", "data"])
      let rawDeviceMap = makeLookupMap(rows: rawDevices, keys: rawDeviceLookupKeys)
      for device in network.devices {
        guard let rawDevice = firstMatchedRow(for: parsedDeviceLookupKeys(device), in: rawDeviceMap)
        else {
          failures.append(
            ConsistencyFailure(
              caseName: caseItem.name,
              metricID: "devices.raw_match",
              provenance: .derived,
              detail: "Unable to match parsed eero device \(device.id) to raw device payload."
            )
          )
          continue
        }

        for contract in deviceContracts {
          evaluatedMetrics += 1
          let expected = contract.expected(rawDevice)
          let actual = contract.actual(device)
          let required = contract.required(rawDevice)

          if let detail = metricMismatch(
            metricID: contract.id,
            expected: expected,
            actual: actual,
            required: required,
            tolerance: contract.tolerance,
            rawHint: contract.rawHint,
            modelHint: contract.modelHint
          ) {
            failures.append(
              ConsistencyFailure(
                caseName: "\(caseItem.name):device:\(device.id)",
                metricID: contract.id,
                provenance: contract.provenance,
                detail: detail
              )
            )
          }
        }
      }
    }

    if outURL == nil, requireOutTraceability {
      warnings.append("Out traceability was requested, but no third-party/out path was available.")
    }

    return ConsistencyReport(
      outPath: outURL?.path,
      evaluatedMetrics: evaluatedMetrics,
      failures: failures,
      warnings: warnings,
      strictProxyMode: strictProxyMode
    )
  }

  // MARK: - Contracts

  private func networkMetricContracts() -> [NetworkMetricContract] {
    [
      NetworkMetricContract(
        id: "dashboard.network_status",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["\"status\"", "2.2/networks/{networkId}/devices/{deviceMac}"],
        rawHint: "status",
        modelHint: "EeroNetwork.status",
        expected: { raw in self.metricString(DictionaryValue.string(in: raw, path: ["status"])) },
        actual: { network in self.metricString(network.status) },
        required: { raw in self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["status"]))
        },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.clients_online",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["\"connected\"", "2.2/networks/{networkId}/devices/{deviceMac}"],
        rawHint: "devices.data[*].connected",
        modelHint: "EeroNetwork.connectedClientsCount",
        expected: { raw in .int(self.rawConnectedClientCount(raw)) },
        actual: { network in .int(network.connectedClientsCount) },
        required: { _ in true },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.guest_clients_online",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["\"is_guest\"", "2.2/networks/{networkId}/devices/{deviceMac}"],
        rawHint: "devices.data[*].connected && is_guest",
        modelHint: "EeroNetwork.connectedGuestClientsCount",
        expected: { raw in .int(self.rawConnectedGuestClientCount(raw)) },
        actual: { network in .int(network.connectedGuestClientsCount) },
        required: { _ in true },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.guest_lan_enabled",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["guest_network", "2.2/networks/{networkId}/guestnetwork"],
        rawHint: "guest_network.enabled",
        modelHint: "EeroNetwork.guestNetworkEnabled",
        expected: { raw in
          .bool(DictionaryValue.bool(in: raw, path: ["guest_network", "enabled"]) ?? false)
        },
        actual: { network in .bool(network.guestNetworkEnabled) },
        required: { _ in true },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.guest_lan_name",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["guest_network", "2.2/networks/{networkId}/guestnetwork"],
        rawHint: "guest_network.name",
        modelHint: "EeroNetwork.guestNetworkName",
        expected: { raw in
          self.metricString(DictionaryValue.string(in: raw, path: ["guest_network", "name"]))
        },
        actual: { network in self.metricString(network.guestNetworkName) },
        required: { raw in
          self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["guest_network", "name"]))
        },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.gateway_ip",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/devices/{deviceMac}", "\"gateway\""],
        rawHint: "gateway_ip or gateway eero ip_address",
        modelHint: "EeroNetwork.gatewayIP",
        expected: { raw in self.metricString(self.rawGatewayIP(raw)) },
        actual: { network in self.metricString(network.gatewayIP) },
        required: { raw in self.rawGatewayIP(raw) != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.last_speedtest_down",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["down_mbps", "2.2/networks/{networkId}/speedtest"],
        rawHint: "speed.down.value or speedtest.down_mbps",
        modelHint: "EeroNetwork.speed.measuredDownValue",
        expected: { raw in self.metricDouble(self.rawSpeedDown(raw)) },
        actual: { network in self.metricDouble(network.speed.measuredDownValue) },
        required: { raw in self.rawSpeedDown(raw) != nil },
        tolerance: 0.001
      ),
      NetworkMetricContract(
        id: "dashboard.last_speedtest_up",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["up_mbps", "2.2/networks/{networkId}/speedtest"],
        rawHint: "speed.up.value or speedtest.up_mbps",
        modelHint: "EeroNetwork.speed.measuredUpValue",
        expected: { raw in self.metricDouble(self.rawSpeedUp(raw)) },
        actual: { network in self.metricDouble(network.speed.measuredUpValue) },
        required: { raw in self.rawSpeedUp(raw) != nil },
        tolerance: 0.001
      ),
      NetworkMetricContract(
        id: "dashboard.mesh_total_count",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/eeros", "connected_devices_and_eeros"],
        rawHint: "eeros.data.count",
        modelHint: "EeroNetwork.mesh.eeroCount",
        expected: { raw in
          self.metricInt(self.rawEeroRows(raw).isEmpty ? nil : self.rawEeroRows(raw).count)
        },
        actual: { network in self.metricInt(network.mesh?.eeroCount) },
        required: { raw in !self.rawEeroRows(raw).isEmpty },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.mesh_online_count",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["eerostatus_online", "2.2/networks/{networkId}/eeros"],
        rawHint: "eeros.data[*].status (online/green/connected)",
        modelHint: "EeroNetwork.mesh.onlineEeroCount",
        expected: { raw in
          self.metricInt(self.rawEeroRows(raw).isEmpty ? nil : self.rawOnlineEeroCount(raw))
        },
        actual: { network in self.metricInt(network.mesh?.onlineEeroCount) },
        required: { raw in !self.rawEeroRows(raw).isEmpty },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.proxied_nodes_total",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{network}/proxied_nodes", "proxied_nodes"],
        rawHint: "proxied_nodes.devices.count",
        modelHint: "EeroNetwork.proxiedNodes.totalDevices",
        expected: { raw in self.metricInt(self.rawProxiedSummary(raw)?.total) },
        actual: { network in self.metricInt(network.proxiedNodes?.totalDevices) },
        required: { raw in self.rawProxiedSummary(raw) != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.proxied_nodes_online",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{network}/proxied_nodes", "proxied_nodes_ach_status_dot"],
        rawHint: "proxied_nodes.devices[*].status",
        modelHint: "EeroNetwork.proxiedNodes.onlineDevices",
        expected: { raw in self.metricInt(self.rawProxiedSummary(raw)?.online) },
        actual: { network in self.metricInt(network.proxiedNodes?.onlineDevices) },
        required: { raw in self.rawProxiedSummary(raw) != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.channel_utilization_radios",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: [
          "2.2/networks/{network}/channel_utilization", "channel_utilization_average_utilization",
        ],
        rawHint: "channel_utilization.utilization.count",
        modelHint: "EeroNetwork.channelUtilization.radios.count",
        expected: { raw in self.metricInt(self.rawChannelUtilizationRows(raw)?.count) },
        actual: { network in self.metricInt(network.channelUtilization?.radios.count) },
        required: { raw in self.rawChannelUtilizationRows(raw) != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.activity_day_download",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/data_usage", "data_usage_day"],
        rawHint: "activity.network.data_usage_day[*].download",
        modelHint: "EeroNetwork.activity.networkDataUsageDayDownload",
        expected: { raw in self.metricInt(self.rawNetworkUsageTotals(raw, period: "day").download)
        },
        actual: { network in self.metricInt(network.activity?.networkDataUsageDayDownload) },
        required: { raw in self.rawNetworkUsageTotals(raw, period: "day").download != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.activity_day_upload",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/data_usage", "data_usage_day"],
        rawHint: "activity.network.data_usage_day[*].upload",
        modelHint: "EeroNetwork.activity.networkDataUsageDayUpload",
        expected: { raw in self.metricInt(self.rawNetworkUsageTotals(raw, period: "day").upload) },
        actual: { network in self.metricInt(network.activity?.networkDataUsageDayUpload) },
        required: { raw in self.rawNetworkUsageTotals(raw, period: "day").upload != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.activity_week_download",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/data_usage", "data_usage_week"],
        rawHint: "activity.network.data_usage_week[*].download",
        modelHint: "EeroNetwork.activity.networkDataUsageWeekDownload",
        expected: { raw in self.metricInt(self.rawNetworkUsageTotals(raw, period: "week").download)
        },
        actual: { network in self.metricInt(network.activity?.networkDataUsageWeekDownload) },
        required: { raw in self.rawNetworkUsageTotals(raw, period: "week").download != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.activity_week_upload",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/data_usage", "data_usage_week"],
        rawHint: "activity.network.data_usage_week[*].upload",
        modelHint: "EeroNetwork.activity.networkDataUsageWeekUpload",
        expected: { raw in self.metricInt(self.rawNetworkUsageTotals(raw, period: "week").upload) },
        actual: { network in self.metricInt(network.activity?.networkDataUsageWeekUpload) },
        required: { raw in self.rawNetworkUsageTotals(raw, period: "week").upload != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.activity_month_download",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/data_usage", "data_usage_month"],
        rawHint: "activity.network.data_usage_month[*].download",
        modelHint: "EeroNetwork.activity.networkDataUsageMonthDownload",
        expected: { raw in self.metricInt(self.rawNetworkUsageTotals(raw, period: "month").download)
        },
        actual: { network in self.metricInt(network.activity?.networkDataUsageMonthDownload) },
        required: { raw in self.rawNetworkUsageTotals(raw, period: "month").download != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.activity_month_upload",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/data_usage", "data_usage_month"],
        rawHint: "activity.network.data_usage_month[*].upload",
        modelHint: "EeroNetwork.activity.networkDataUsageMonthUpload",
        expected: { raw in self.metricInt(self.rawNetworkUsageTotals(raw, period: "month").upload)
        },
        actual: { network in self.metricInt(network.activity?.networkDataUsageMonthUpload) },
        required: { raw in self.rawNetworkUsageTotals(raw, period: "month").upload != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.busiest_devices_count",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: [
          "2.2/networks/{networkId}/data_usage/devices", "historical_data_usage_title",
        ],
        rawHint: "activity.devices.data_usage_* unique resources",
        modelHint: "EeroNetwork.activity.busiestDevices.count",
        expected: { raw in self.metricInt(self.rawTopDeviceUsageCount(raw)) },
        actual: { network in self.metricInt(network.activity?.busiestDevices.count) },
        required: { raw in self.rawTopDeviceUsageCount(raw) != nil },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.updates_status",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["/updates", "update_status"],
        rawHint: "updates.update_status | updates.status | update_status",
        modelHint: "EeroNetwork.updates.updateStatus",
        expected: { raw in
          self.metricString(
            DictionaryValue.string(in: raw, path: ["updates", "update_status"])
              ?? DictionaryValue.string(in: raw, path: ["updates", "status"])
              ?? DictionaryValue.string(in: raw, path: ["update_status"])
              ?? DictionaryValue.string(in: raw, path: ["firmware_update_status"])
          )
        },
        actual: { network in self.metricString(network.updates.updateStatus) },
        required: { raw in
          self.hasNonEmptyString(
            DictionaryValue.string(in: raw, path: ["updates", "update_status"]))
            || self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["updates", "status"]))
            || self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["update_status"]))
            || self.hasNonEmptyString(
              DictionaryValue.string(in: raw, path: ["firmware_update_status"]))
        },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "network.updates_target_firmware",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["/updates", "target_firmware"],
        rawHint: "updates.target_firmware",
        modelHint: "EeroNetwork.updates.targetFirmware",
        expected: { raw in
          self.metricString(DictionaryValue.string(in: raw, path: ["updates", "target_firmware"]))
        },
        actual: { network in self.metricString(network.updates.targetFirmware) },
        required: { raw in
          self.hasNonEmptyString(
            DictionaryValue.string(in: raw, path: ["updates", "target_firmware"]))
        },
        tolerance: 0.0
      ),
      NetworkMetricContract(
        id: "dashboard.realtime_download_mbps_proxy",
        provenance: .proxy,
        proxyAllowed: true,
        outIndicators: ["live_data_usage", "down_mbps"],
        rawHint: "sum(connected clients usage.down_mbps)",
        modelHint: "EeroNetwork.realtime.downloadMbps",
        expected: { raw in self.metricDouble(self.rawRealtimeUsage(raw)?.download) },
        actual: { network in self.metricDouble(network.realtime?.downloadMbps) },
        required: { raw in self.rawRealtimeUsage(raw) != nil },
        tolerance: 0.001
      ),
      NetworkMetricContract(
        id: "dashboard.realtime_upload_mbps_proxy",
        provenance: .proxy,
        proxyAllowed: true,
        outIndicators: ["live_data_usage", "up_mbps"],
        rawHint: "sum(connected clients usage.up_mbps)",
        modelHint: "EeroNetwork.realtime.uploadMbps",
        expected: { raw in self.metricDouble(self.rawRealtimeUsage(raw)?.upload) },
        actual: { network in self.metricDouble(network.realtime?.uploadMbps) },
        required: { raw in self.rawRealtimeUsage(raw) != nil },
        tolerance: 0.001
      ),
    ]
  }

  private func clientMetricContracts() -> [ClientMetricContract] {
    [
      ClientMetricContract(
        id: "clients.segment_is_guest",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["\"is_guest\"", "2.2/networks/{networkId}/devices/{deviceMac}"],
        rawHint: "is_guest",
        modelHint: "EeroClient.isGuest",
        expected: { raw in .bool(DictionaryValue.bool(in: raw, path: ["is_guest"]) ?? false) },
        actual: { client in .bool(client.isGuest) },
        required: { _ in true },
        tolerance: 0.0
      ),
      ClientMetricContract(
        id: "clients.connected_state",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["\"connected\"", "2.2/networks/{networkId}/devices/{deviceMac}"],
        rawHint: "connected",
        modelHint: "EeroClient.connected",
        expected: { raw in .bool(DictionaryValue.bool(in: raw, path: ["connected"]) ?? false) },
        actual: { client in .bool(client.connected) },
        required: { _ in true },
        tolerance: 0.0
      ),
      ClientMetricContract(
        id: "clients.source_location",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: [
          "connection_type_wireless_format", "devices_tab_device_connection_type_title",
        ],
        rawHint: "source.location",
        modelHint: "EeroClient.sourceLocation",
        expected: { raw in
          self.metricString(DictionaryValue.string(in: raw, path: ["source", "location"]))
        },
        actual: { client in self.metricString(client.sourceLocation) },
        required: { raw in
          self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["source", "location"]))
        },
        tolerance: 0.0
      ),
      ClientMetricContract(
        id: "clients.connection_type",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: [
          "connection_type_wireless_format", "devices_tab_device_connection_type_title",
        ],
        rawHint: "connection_type",
        modelHint: "EeroClient.connectionType",
        expected: { raw in
          self.metricString(DictionaryValue.string(in: raw, path: ["connection_type"]))
        },
        actual: { client in self.metricString(client.connectionType) },
        required: { raw in
          self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["connection_type"]))
        },
        tolerance: 0.0
      ),
      ClientMetricContract(
        id: "clients.signal",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["rx_rate_info", "tx_rate_info"],
        rawHint: "connectivity.signal",
        modelHint: "EeroClient.signal",
        expected: { raw in
          self.metricString(DictionaryValue.string(in: raw, path: ["connectivity", "signal"]))
        },
        actual: { client in self.metricString(client.signal) },
        required: { raw in
          self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["connectivity", "signal"]))
        },
        tolerance: 0.0
      ),
      ClientMetricContract(
        id: "clients.channel",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: [
          "channel_utilization_channel", "2.2/networks/{networkId}/devices/{deviceMac}",
        ],
        rawHint: "channel or connectivity.channel",
        modelHint: "EeroClient.channel",
        expected: { raw in
          self.metricInt(
            DictionaryValue.int(in: raw, path: ["channel"])
              ?? DictionaryValue.int(in: raw, path: ["connectivity", "channel"])
          )
        },
        actual: { client in self.metricInt(client.channel) },
        required: { raw in
          DictionaryValue.int(in: raw, path: ["channel"]) != nil
            || DictionaryValue.int(in: raw, path: ["connectivity", "channel"]) != nil
        },
        tolerance: 0.0
      ),
      ClientMetricContract(
        id: "clients.rx_rate_mbps",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["rx_rate_info", "rate_mbps", "rate_bps", "rx_bitrate"],
        rawHint:
          "connectivity.rx_rate_info.rate_mbps | connectivity.rx_rate_info.rate_bps | connectivity.rx_bitrate",
        modelHint: "EeroClient.rxRateMbps",
        expected: { raw in
          self.metricDouble(
            self.firstRateMbps(
              in: raw,
              pathPrefixes: [
                ["connectivity", "rx_rate_info"],
                ["connectivity", "rx_rate"],
                ["connectivity", "rx_bitrate"],
                ["rx_rate_info"],
                ["rx_rate"],
                ["rx_bitrate"],
              ]))
        },
        actual: { client in self.metricDouble(client.rxRateMbps) },
        required: { raw in
          self.firstRateMbps(
            in: raw,
            pathPrefixes: [
              ["connectivity", "rx_rate_info"],
              ["connectivity", "rx_rate"],
              ["connectivity", "rx_bitrate"],
              ["rx_rate_info"],
              ["rx_rate"],
              ["rx_bitrate"],
            ]) != nil
        },
        tolerance: 0.001
      ),
      ClientMetricContract(
        id: "clients.tx_rate_mbps",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["tx_rate_info", "rate_mbps", "rate_bps", "tx_bitrate"],
        rawHint:
          "connectivity.tx_rate_info.rate_mbps | connectivity.tx_rate_info.rate_bps | connectivity.tx_bitrate",
        modelHint: "EeroClient.txRateMbps",
        expected: { raw in
          self.metricDouble(
            self.firstRateMbps(
              in: raw,
              pathPrefixes: [
                ["connectivity", "tx_rate_info"],
                ["connectivity", "tx_rate"],
                ["connectivity", "tx_bitrate"],
                ["tx_rate_info"],
                ["tx_rate"],
                ["tx_bitrate"],
              ]))
        },
        actual: { client in self.metricDouble(client.txRateMbps) },
        required: { raw in
          self.firstRateMbps(
            in: raw,
            pathPrefixes: [
              ["connectivity", "tx_rate_info"],
              ["connectivity", "tx_rate"],
              ["connectivity", "tx_bitrate"],
              ["tx_rate_info"],
              ["tx_rate"],
              ["tx_bitrate"],
            ]) != nil
        },
        tolerance: 0.001
      ),
      ClientMetricContract(
        id: "clients.usage_down_mbps",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["down_mbps", "live_data_usage"],
        rawHint: "usage.down_mbps",
        modelHint: "EeroClient.usageDownMbps",
        expected: { raw in
          self.metricDouble(
            self.firstDouble(
              in: raw,
              paths: [
                ["usage", "down_mbps"],
                ["usage", "downMbps"],
                ["down_mbps"],
                ["downMbps"],
              ]
            )
          )
        },
        actual: { client in self.metricDouble(client.usageDownMbps) },
        required: { raw in
          self.firstDouble(
            in: raw,
            paths: [
              ["usage", "down_mbps"],
              ["usage", "downMbps"],
              ["down_mbps"],
              ["downMbps"],
            ]
          ) != nil
        },
        tolerance: 0.001
      ),
      ClientMetricContract(
        id: "clients.usage_up_mbps",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["up_mbps", "live_data_usage"],
        rawHint: "usage.up_mbps",
        modelHint: "EeroClient.usageUpMbps",
        expected: { raw in
          self.metricDouble(
            self.firstDouble(
              in: raw,
              paths: [
                ["usage", "up_mbps"],
                ["usage", "upMbps"],
                ["up_mbps"],
                ["upMbps"],
              ]
            )
          )
        },
        actual: { client in self.metricDouble(client.usageUpMbps) },
        required: { raw in
          self.firstDouble(
            in: raw,
            paths: [
              ["usage", "up_mbps"],
              ["usage", "upMbps"],
              ["up_mbps"],
              ["upMbps"],
            ]
          ) != nil
        },
        tolerance: 0.001
      ),
    ]
  }

  private func deviceMetricContracts() -> [DeviceMetricContract] {
    [
      DeviceMetricContract(
        id: "device.status",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["eerostatus_online", "2.2/networks/{networkId}/eeros"],
        rawHint: "status",
        modelHint: "EeroDevice.status",
        expected: { raw in self.metricString(DictionaryValue.string(in: raw, path: ["status"])) },
        actual: { device in self.metricString(device.status) },
        required: { raw in self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["status"]))
        },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.is_gateway",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["\"gateway\"", "2.2/networks/{networkId}/eeros"],
        rawHint: "gateway",
        modelHint: "EeroDevice.isGateway",
        expected: { raw in .bool(DictionaryValue.bool(in: raw, path: ["gateway"]) ?? false) },
        actual: { device in .bool(device.isGateway) },
        required: { _ in true },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.ip_address",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["2.2/networks/{networkId}/eeros", "\"ip_address\""],
        rawHint: "ip_address or ip",
        modelHint: "EeroDevice.ipAddress",
        expected: { raw in
          self.metricString(
            DictionaryValue.string(in: raw, path: ["ip_address"])
              ?? DictionaryValue.string(in: raw, path: ["ip"])
          )
        },
        actual: { device in self.metricString(device.ipAddress) },
        required: { raw in
          self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["ip_address"]))
            || self.hasNonEmptyString(DictionaryValue.string(in: raw, path: ["ip"]))
        },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.connected_clients_count",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["device_connections", "connected_devices_and_eeros"],
        rawHint: "connected_clients_count",
        modelHint: "EeroDevice.connectedClientCount",
        expected: { raw in
          self.metricInt(DictionaryValue.int(in: raw, path: ["connected_clients_count"]))
        },
        actual: { device in self.metricInt(device.connectedClientCount) },
        required: { raw in DictionaryValue.int(in: raw, path: ["connected_clients_count"]) != nil },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.connected_wired_clients_count",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["device_connections", "connected_devices_and_eeros"],
        rawHint: "connected_wired_clients_count",
        modelHint: "EeroDevice.connectedWiredClientCount",
        expected: { raw in
          self.metricInt(DictionaryValue.int(in: raw, path: ["connected_wired_clients_count"]))
        },
        actual: { device in self.metricInt(device.connectedWiredClientCount) },
        required: { raw in
          DictionaryValue.int(in: raw, path: ["connected_wired_clients_count"]) != nil
        },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.connected_wireless_clients_count",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["device_connections", "connected_devices_and_eeros"],
        rawHint: "connected_wireless_clients_count",
        modelHint: "EeroDevice.connectedWirelessClientCount",
        expected: { raw in
          self.metricInt(DictionaryValue.int(in: raw, path: ["connected_wireless_clients_count"]))
        },
        actual: { device in self.metricInt(device.connectedWirelessClientCount) },
        required: { raw in
          DictionaryValue.int(in: raw, path: ["connected_wireless_clients_count"]) != nil
        },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.mesh_quality_bars",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["channel_utilization", "connected_devices_and_eeros"],
        rawHint: "mesh_quality_bars",
        modelHint: "EeroDevice.meshQualityBars",
        expected: { raw in self.metricInt(DictionaryValue.int(in: raw, path: ["mesh_quality_bars"]))
        },
        actual: { device in self.metricInt(device.meshQualityBars) },
        required: { raw in DictionaryValue.int(in: raw, path: ["mesh_quality_bars"]) != nil },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.wired_backhaul",
        provenance: .direct,
        proxyAllowed: false,
        outIndicators: ["device_connections", "connected_devices_and_eeros"],
        rawHint: "wired",
        modelHint: "EeroDevice.wiredBackhaul",
        expected: { raw in self.metricBool(DictionaryValue.bool(in: raw, path: ["wired"])) },
        actual: { device in self.metricBool(device.wiredBackhaul) },
        required: { raw in DictionaryValue.bool(in: raw, path: ["wired"]) != nil },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.ethernet_link_count",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["device_connections", "negotiated_speed"],
        rawHint: "connections.ports.interfaces.count",
        modelHint: "EeroDevice.ethernetStatuses.count",
        expected: { raw in self.metricInt(self.rawEthernetInterfaceCount(raw)) },
        actual: { device in self.metricInt(device.ethernetStatuses.count) },
        required: { raw in self.rawEthernetInterfaceCount(raw) != nil },
        tolerance: 0.0
      ),
      DeviceMetricContract(
        id: "device.wireless_attachment_count",
        provenance: .derived,
        proxyAllowed: false,
        outIndicators: ["device_connections", "wireless_devices"],
        rawHint: "connections.wireless_devices.count",
        modelHint: "EeroDevice.wirelessAttachments.count",
        expected: { raw in self.metricInt(self.rawWirelessAttachmentCount(raw)) },
        actual: { device in self.metricInt(device.wirelessAttachments?.count ?? 0) },
        required: { raw in self.rawWirelessAttachmentCount(raw) != nil },
        tolerance: 0.0
      ),
    ]
  }

  private func contractDescriptors(
    network: [NetworkMetricContract],
    clients: [ClientMetricContract],
    devices: [DeviceMetricContract]
  ) -> [ContractDescriptor] {
    network.map {
      ContractDescriptor(
        id: $0.id, provenance: $0.provenance, proxyAllowed: $0.proxyAllowed,
        outIndicators: $0.outIndicators)
    }
      + clients.map {
        ContractDescriptor(
          id: $0.id, provenance: $0.provenance, proxyAllowed: $0.proxyAllowed,
          outIndicators: $0.outIndicators)
      }
      + devices.map {
        ContractDescriptor(
          id: $0.id, provenance: $0.provenance, proxyAllowed: $0.proxyAllowed,
          outIndicators: $0.outIndicators)
      }
  }

  // MARK: - Fixture and Live Case Inputs

  private func makeFixtureCases() -> [ConsistencyCase] {
    let timelineDateA = ISO8601DateFormatter().date(from: "2026-02-11T08:00:00Z") ?? Date()
    let timelineDateB = ISO8601DateFormatter().date(from: "2026-02-11T09:00:00Z") ?? Date()
    let now = ISO8601DateFormatter().date(from: "2026-02-12T09:30:00Z") ?? Date()

    let rawNetwork: [String: Any] = [
      "url": "/2.2/networks/network-1",
      "name": "DLSC West 4th",
      "nickname": "West 4th",
      "status": "connected",
      "guest_network": [
        "enabled": true,
        "name": "DLSC-IOT",
        "password": "guest-password",
      ],
      "backup_internet_enabled": false,
      "gateway_ip": "192.168.4.1",
      "health": [
        "internet": ["status": "connected", "isp_up": true],
        "eero_network": ["status": "connected"],
      ],
      "updates": [
        "target_firmware": "v7.13.2-50",
        "update_status": "Available",
        "has_update": true,
        "can_update_now": true,
      ],
      "speed": [
        "down": ["value": 979.9, "units": "Mbps"],
        "up": ["value": 970.0, "units": "Mbps"],
        "date": "2026-02-11T11:45:51Z",
      ],
      "speedtest": [
        [
          "down_mbps": 979.9,
          "up_mbps": 970.0,
          "date": "2026-02-11T11:45:51Z",
        ]
      ],
      "devices": [
        "data": [
          [
            "url": "/2.2/networks/network-1/devices/client-aa",
            "nickname": "MacBook-Pro",
            "mac": "AA:AA:AA:AA:AA:AA",
            "ip": "192.168.4.10",
            "connected": true,
            "paused": false,
            "wireless": true,
            "is_guest": false,
            "connection_type": "wireless",
            "channel": 36,
            "manufacturer": "Apple, Inc.",
            "device_type": "computer",
            "connectivity": [
              "signal": "-45 dBm",
              "rx_rate_info": ["rate_mbps": 780.0, "channel_width": "WIDTH_80MHZ"],
              "tx_rate_info": ["rate_mbps": 610.0, "channel_width": "WIDTH_80MHZ"],
            ],
            "usage": [
              "down_mbps": 12.5,
              "up_mbps": 2.1,
            ],
            "source": [
              "location": "Office",
              "url": "/2.2/eeros/eero-office",
            ],
          ],
          [
            "url": "/2.2/networks/network-1/devices/client-bb",
            "nickname": "ChromecastTV",
            "mac": "BB:BB:BB:BB:BB:BB",
            "ip": "192.168.4.29",
            "connected": true,
            "paused": false,
            "wireless": true,
            "is_guest": true,
            "connection_type": "wireless",
            "channel": 149,
            "manufacturer": "Google, Inc.",
            "device_type": "media_streamer",
            "connectivity": [
              "signal": "-58 dBm",
              "rx_rate_info": ["rate_mbps": 500.0, "channel_width": "WIDTH_80MHZ"],
              "tx_rate_info": ["rate_mbps": 260.0, "channel_width": "WIDTH_80MHZ"],
            ],
            "usage": [
              "down_mbps": 3.2,
              "up_mbps": 0.8,
            ],
            "source": [
              "location": "Living Room",
              "url": "/2.2/eeros/eero-living",
            ],
          ],
        ]
      ],
      "eeros": [
        "data": [
          [
            "url": "/2.2/eeros/eero-office",
            "location": "Office",
            "gateway": true,
            "status": "green",
            "mac_address": "40:47:5E:8B:AA:B2",
            "ip_address": "192.168.4.1",
            "connected_clients_count": 2,
            "connected_wired_clients_count": 1,
            "connected_wireless_clients_count": 1,
            "mesh_quality_bars": 5,
            "wired": true,
            "bands": ["band_2_4GHz", "band_5GHz"],
            "connections": [
              "ports": [
                "interfaces": [
                  [
                    "interface_number": 1,
                    "name": "Port 1",
                    "network_type": "LAN",
                    "negotiated_speed": ["tag": "1 Gbps"],
                    "connection_status": [
                      "kind": "connected",
                      "metadata": ["location": "srv2"],
                    ],
                  ],
                  [
                    "interface_number": 2,
                    "name": "Port 2",
                    "network_type": "LAN",
                    "connection_status": [
                      "kind": "not_connected"
                    ],
                  ],
                ]
              ],
              "wireless_devices": [
                [
                  "metadata": [
                    "display_name": "Nest-Doorbell",
                    "url": "/2.2/networks/network-1/devices/client-cc",
                  ],
                  "kind": "wireless",
                ]
              ],
            ],
          ],
          [
            "url": "/2.2/eeros/eero-living",
            "location": "Living Room",
            "gateway": false,
            "status": "green",
            "mac_address": "40:47:5E:8B:AA:B3",
            "ip_address": "192.168.4.203",
            "connected_clients_count": 1,
            "connected_wired_clients_count": 0,
            "connected_wireless_clients_count": 1,
            "mesh_quality_bars": 4,
            "wired": false,
            "bands": ["band_2_4GHz", "band_5GHz"],
            "connections": [
              "ports": [
                "interfaces": [
                  [
                    "interface_number": 1,
                    "name": "Port 1",
                    "network_type": "LAN",
                    "negotiated_speed": ["tag": "1 Gbps"],
                    "connection_status": [
                      "kind": "multiple",
                      "metadata": [
                        "multiple_devices": [
                          "multiple_devices": [
                            "connections": [
                              [
                                "metadata": [
                                  "location": "Office Rack",
                                  "url": "/2.2/networks/network-1/devices/device-01",
                                ]
                              ],
                              [
                                "metadata": [
                                  "location": "Studio",
                                  "url": "/2.2/networks/network-1/devices/device-02",
                                ]
                              ],
                              [
                                "metadata": [
                                  "location": "Living Room AP",
                                  "url": "/2.2/networks/network-1/devices/device-03",
                                ]
                              ],
                            ]
                          ]
                        ]
                      ],
                    ],
                  ]
                ]
              ]
            ],
          ],
        ]
      ],
      "proxied_nodes": [
        "enabled": true,
        "devices": [
          ["status": "online"],
          ["status": "offline"],
        ],
      ],
      "channel_utilization": [
        "eeros": [
          ["id": "eero-office", "location": "Office"],
          ["id": "eero-living", "location": "Living Room"],
        ],
        "utilization": [
          [
            "eero_id": "eero-office",
            "band": "5 GHz",
            "channel": 36,
            "average_utilization": 42,
            "max_utilization": 69,
            "time_series_data": [
              ["timestamp": 1_707_140_400.0, "busy": 42, "noise": 8]
            ],
          ],
          [
            "eero_id": "eero-living",
            "band": "2.4 GHz",
            "channel": 1,
            "average_utilization": 31,
            "max_utilization": 58,
            "time_series_data": [
              ["timestamp": 1_707_140_400.0, "busy": 31, "noise": 5]
            ],
          ],
        ],
      ],
      "activity": [
        "network": [
          "data_usage_day": [
            ["download": 4_000_000_000, "upload": 600_000_000]
          ],
          "data_usage_week": [
            ["download": 16_000_000_000, "upload": 2_000_000_000]
          ],
          "data_usage_month": [
            ["download": 64_000_000_000, "upload": 8_000_000_000]
          ],
        ],
        "devices": [
          "data_usage_day": [
            [
              "url": "/2.2/networks/network-1/devices/client-aa",
              "display_name": "MacBook-Pro",
              "download": 3_200_000_000,
              "upload": 500_000_000,
            ],
            [
              "url": "/2.2/networks/network-1/devices/client-bb",
              "display_name": "ChromecastTV",
              "download": 800_000_000,
              "upload": 100_000_000,
            ],
          ],
          "data_usage_week": [
            [
              "url": "/2.2/networks/network-1/devices/client-aa",
              "display_name": "MacBook-Pro",
              "download": 12_000_000_000,
              "upload": 1_600_000_000,
            ],
            [
              "url": "/2.2/networks/network-1/devices/client-bb",
              "display_name": "ChromecastTV",
              "download": 4_000_000_000,
              "upload": 400_000_000,
            ],
          ],
          "data_usage_month": [
            [
              "url": "/2.2/networks/network-1/devices/client-aa",
              "display_name": "MacBook-Pro",
              "download": 48_000_000_000,
              "upload": 6_000_000_000,
            ],
            [
              "url": "/2.2/networks/network-1/devices/client-bb",
              "display_name": "ChromecastTV",
              "download": 16_000_000_000,
              "upload": 2_000_000_000,
            ],
          ],
          "device_timelines": [
            [
              "resource_key": "client-aa",
              "display_name": "MacBook-Pro",
              "mac": "AA:AA:AA:AA:AA:AA",
              "payload": [
                "values": [
                  [
                    "time": "2026-02-11T08:00:00Z", "download": 1_000_000_000,
                    "upload": 120_000_000,
                  ],
                  [
                    "time": "2026-02-11T09:00:00Z", "download": 1_200_000_000,
                    "upload": 140_000_000,
                  ],
                ]
              ],
            ]
          ],
        ],
      ],
      "premium_dns": [
        "ad_block_settings": ["enabled": true],
        "dns_policies": ["block_malware": false],
      ],
      "band_steering": true,
      "upnp": true,
      "thread": ["enabled": false],
      "sqm": false,
      "ipv6_upstream": true,
      "ddns": ["enabled": false, "subdomain": "Unavailable"],
      "diagnostics": ["status": "not_started"],
      "support": ["name": "eero", "support_phone": "+18776592347"],
      "routing": [
        "reservations": ["data": []],
        "forwards": ["data": []],
        "pinholes": ["data": []],
      ],
      "insights_response": ["available": true],
    ]

    let fixtureClients: [EeroClient] = [
      EeroClient(
        id: "client-aa",
        name: "MacBook-Pro",
        mac: "AA:AA:AA:AA:AA:AA",
        ip: "192.168.4.10",
        connected: true,
        paused: false,
        wireless: true,
        isGuest: false,
        connectionType: "wireless",
        signal: "-45 dBm",
        signalAverage: nil,
        scoreBars: 4,
        channel: 36,
        blacklisted: false,
        deviceType: "computer",
        manufacturer: "Apple, Inc.",
        lastActive: "2026-02-12T09:25:00Z",
        isPrivate: false,
        interfaceFrequency: "5",
        interfaceFrequencyUnit: "GHz",
        rxChannelWidth: "WIDTH_80MHZ",
        txChannelWidth: "WIDTH_80MHZ",
        rxRateMbps: 780.0,
        txRateMbps: 610.0,
        usageDownMbps: 12.5,
        usageUpMbps: 2.1,
        usageDownPercentCurrent: 40,
        usageUpPercentCurrent: 12,
        usageDayDownload: 3_200_000_000,
        usageDayUpload: 500_000_000,
        usageWeekDownload: 12_000_000_000,
        usageWeekUpload: 1_600_000_000,
        usageMonthDownload: 48_000_000_000,
        usageMonthUpload: 6_000_000_000,
        sourceLocation: "Office",
        sourceURL: "/2.2/eeros/eero-office",
        resources: [:]
      ),
      EeroClient(
        id: "client-bb",
        name: "ChromecastTV",
        mac: "BB:BB:BB:BB:BB:BB",
        ip: "192.168.4.29",
        connected: true,
        paused: false,
        wireless: true,
        isGuest: true,
        connectionType: "wireless",
        signal: "-58 dBm",
        signalAverage: nil,
        scoreBars: 3,
        channel: 149,
        blacklisted: false,
        deviceType: "media_streamer",
        manufacturer: "Google, Inc.",
        lastActive: "2026-02-12T09:24:00Z",
        isPrivate: false,
        interfaceFrequency: "5",
        interfaceFrequencyUnit: "GHz",
        rxChannelWidth: "WIDTH_80MHZ",
        txChannelWidth: "WIDTH_80MHZ",
        rxRateMbps: 500.0,
        txRateMbps: 260.0,
        usageDownMbps: 3.2,
        usageUpMbps: 0.8,
        usageDownPercentCurrent: 12,
        usageUpPercentCurrent: 4,
        usageDayDownload: 800_000_000,
        usageDayUpload: 100_000_000,
        usageWeekDownload: 4_000_000_000,
        usageWeekUpload: 400_000_000,
        usageMonthDownload: 16_000_000_000,
        usageMonthUpload: 2_000_000_000,
        sourceLocation: "Living Room",
        sourceURL: "/2.2/eeros/eero-living",
        resources: [:]
      ),
    ]

    let fixtureDevices: [EeroDevice] = [
      EeroDevice(
        id: "eero-office",
        name: "Office",
        model: "eero Pro 6E",
        modelNumber: "S010001",
        serial: "SERIAL-OFFICE",
        macAddress: "40:47:5E:8B:AA:B2",
        isGateway: true,
        status: "green",
        statusLightEnabled: true,
        statusLightBrightness: nil,
        updateAvailable: true,
        ipAddress: "192.168.4.1",
        osVersion: "v7.13.2-50",
        lastRebootAt: "2026-02-10T10:00:00Z",
        connectedClientCount: 2,
        connectedClientNames: ["MacBook-Pro", "ChromecastTV"],
        connectedWiredClientCount: 1,
        connectedWirelessClientCount: 1,
        meshQualityBars: 5,
        wiredBackhaul: true,
        wifiBands: ["band_2_4GHz", "band_5GHz"],
        portDetails: [],
        ethernetStatuses: [
          EeroEthernetPortStatus(
            id: "eero-office-if-1",
            interfaceNumber: 1,
            portName: "Port 1",
            hasCarrier: true,
            peerCount: nil,
            isWanPort: false,
            speedTag: "1 Gbps",
            powerSaving: nil,
            originalSpeed: nil,
            neighborName: "srv2",
            neighborURL: nil,
            neighborPortName: nil,
            neighborPort: nil,
            connectionKind: "connected",
            connectionType: nil
          ),
          EeroEthernetPortStatus(
            id: "eero-office-if-2",
            interfaceNumber: 2,
            portName: "Port 2",
            hasCarrier: false,
            peerCount: nil,
            isWanPort: false,
            speedTag: nil,
            powerSaving: nil,
            originalSpeed: nil,
            neighborName: nil,
            neighborURL: nil,
            neighborPortName: nil,
            neighborPort: nil,
            connectionKind: "not_connected",
            connectionType: nil
          ),
        ],
        wirelessAttachments: [
          EeroWirelessAttachmentSummary(
            id: "wireless-client-cc",
            displayName: "Nest-Doorbell",
            url: "/2.2/networks/network-1/devices/client-cc",
            kind: "wireless",
            model: nil,
            deviceType: nil
          )
        ],
        usageDayDownload: 1_200_000_000,
        usageDayUpload: 150_000_000,
        usageWeekDownload: 4_500_000_000,
        usageWeekUpload: 500_000_000,
        usageMonthDownload: 18_000_000_000,
        usageMonthUpload: 2_000_000_000,
        supportExpired: false,
        supportExpirationString: nil,
        resources: [:]
      ),
      EeroDevice(
        id: "eero-living",
        name: "Living Room",
        model: "eero Pro 6",
        modelNumber: "S010002",
        serial: "SERIAL-LIVING",
        macAddress: "40:47:5E:8B:AA:B3",
        isGateway: false,
        status: "green",
        statusLightEnabled: true,
        statusLightBrightness: nil,
        updateAvailable: false,
        ipAddress: "192.168.4.203",
        osVersion: "v7.13.2-50",
        lastRebootAt: "2026-02-10T11:00:00Z",
        connectedClientCount: 1,
        connectedClientNames: nil,
        connectedWiredClientCount: 0,
        connectedWirelessClientCount: 1,
        meshQualityBars: 4,
        wiredBackhaul: false,
        wifiBands: ["band_2_4GHz", "band_5GHz"],
        portDetails: [],
        ethernetStatuses: [
          EeroEthernetPortStatus(
            id: "eero-living-if-1",
            interfaceNumber: 1,
            portName: "Port 1",
            hasCarrier: true,
            peerCount: 3,
            isWanPort: false,
            speedTag: "1 Gbps",
            powerSaving: nil,
            originalSpeed: nil,
            neighborName: nil,
            neighborURL: nil,
            neighborPortName: nil,
            neighborPort: nil,
            connectionKind: "multiple",
            connectionType: nil
          )
        ],
        wirelessAttachments: nil,
        usageDayDownload: 900_000_000,
        usageDayUpload: 120_000_000,
        usageWeekDownload: 3_800_000_000,
        usageWeekUpload: 420_000_000,
        usageMonthDownload: 14_000_000_000,
        usageMonthUpload: 1_700_000_000,
        supportExpired: false,
        supportExpirationString: nil,
        resources: [:]
      ),
    ]

    let fixtureNetwork = EeroNetwork(
      id: "network-1",
      name: "DLSC West 4th",
      nickname: "West 4th",
      status: "connected",
      premiumEnabled: false,
      connectedClientsCount: 2,
      connectedGuestClientsCount: 1,
      guestNetworkEnabled: true,
      guestNetworkName: "DLSC-IOT",
      guestNetworkPassword: "guest-password",
      guestNetworkDetails: GuestNetworkDetails(
        enabled: true, name: "DLSC-IOT", password: "guest-password"),
      backupInternetEnabled: false,
      resources: [:],
      features: NetworkFeatureState(
        adBlock: true,
        blockMalware: false,
        bandSteering: true,
        upnp: true,
        wpa3: nil,
        threadEnabled: false,
        sqm: false,
        ipv6Upstream: true
      ),
      ddns: NetworkDDNSSummary(enabled: false, subdomain: "Unavailable"),
      health: NetworkHealthSummary(
        internetStatus: "connected", internetUp: true, eeroNetworkStatus: "connected"),
      diagnostics: NetworkDiagnosticsSummary(status: "not_started"),
      updates: NetworkUpdateSummary(
        hasUpdate: true,
        canUpdateNow: true,
        targetFirmware: "v7.13.2-50",
        minRequiredFirmware: nil,
        updateToFirmware: nil,
        updateStatus: "Available",
        preferredUpdateHour: nil,
        scheduledUpdateTime: nil,
        lastUpdateStarted: nil
      ),
      speed: NetworkSpeedSummary(
        measuredDownValue: 979.9,
        measuredDownUnits: "Mbps",
        measuredUpValue: 970.0,
        measuredUpUnits: "Mbps",
        measuredAt: "2026-02-11T11:45:51Z",
        latestSpeedTest: SpeedTestRecord(
          upMbps: 970.0, downMbps: 979.9, date: "2026-02-11T11:45:51Z")
      ),
      support: NetworkSupportSummary(
        supportPhone: "+18776592347",
        contactURL: nil,
        helpURL: nil,
        emailWebFormURL: nil,
        name: "eero"
      ),
      acCompatibility: NetworkACCompatibilitySummary(enabled: nil, state: nil),
      security: NetworkSecuritySummary(blacklistedDeviceCount: 0, blacklistedDeviceNames: []),
      routing: NetworkRoutingSummary(
        reservationCount: 0, forwardCount: 0, pinholeCount: 0, reservations: [], forwards: []),
      insights: NetworkInsightsSummary(available: true, lastError: nil),
      threadDetails: nil,
      burstReporters: nil,
      gatewayIP: "192.168.4.1",
      mesh: NetworkMeshSummary(
        eeroCount: 2,
        onlineEeroCount: 2,
        gatewayName: "Office",
        gatewayMACAddress: "40:47:5E:8B:AA:B2",
        gatewayIP: "192.168.4.1",
        averageMeshQualityBars: 4.5,
        wiredBackhaulCount: 1,
        wirelessBackhaulCount: 1
      ),
      wirelessCongestion: nil,
      activity: NetworkActivitySummary(
        networkDataUsageDayDownload: 4_000_000_000,
        networkDataUsageDayUpload: 600_000_000,
        networkDataUsageWeekDownload: 16_000_000_000,
        networkDataUsageWeekUpload: 2_000_000_000,
        networkDataUsageMonthDownload: 64_000_000_000,
        networkDataUsageMonthUpload: 8_000_000_000,
        busiestDevices: [
          TopDeviceUsage(
            id: "usage-device-client-aa",
            name: "MacBook-Pro",
            macAddress: "AA:AA:AA:AA:AA:AA",
            manufacturer: "Apple, Inc.",
            deviceType: "computer",
            dayDownloadBytes: 3_200_000_000,
            dayUploadBytes: 500_000_000,
            weekDownloadBytes: 12_000_000_000,
            weekUploadBytes: 1_600_000_000,
            monthDownloadBytes: 48_000_000_000,
            monthUploadBytes: 6_000_000_000
          ),
          TopDeviceUsage(
            id: "usage-device-client-bb",
            name: "ChromecastTV",
            macAddress: "BB:BB:BB:BB:BB:BB",
            manufacturer: "Google, Inc.",
            deviceType: "media_streamer",
            dayDownloadBytes: 800_000_000,
            dayUploadBytes: 100_000_000,
            weekDownloadBytes: 4_000_000_000,
            weekUploadBytes: 400_000_000,
            monthDownloadBytes: 16_000_000_000,
            monthUploadBytes: 2_000_000_000
          ),
        ],
        busiestDeviceTimelines: [
          DeviceUsageTimeline(
            id: "usage-timeline-client-aa",
            name: "MacBook-Pro",
            macAddress: "AA:AA:AA:AA:AA:AA",
            samples: [
              DeviceUsageTimelineSample(
                id: "timeline-sample-a",
                timestamp: timelineDateA,
                downloadBytes: 1_000_000_000,
                uploadBytes: 120_000_000
              ),
              DeviceUsageTimelineSample(
                id: "timeline-sample-b",
                timestamp: timelineDateB,
                downloadBytes: 1_200_000_000,
                uploadBytes: 140_000_000
              ),
            ]
          )
        ]
      ),
      realtime: NetworkRealtimeSummary(
        downloadMbps: 15.7,
        uploadMbps: 2.9,
        sourceLabel: "eero client telemetry",
        sampledAt: now
      ),
      channelUtilization: NetworkChannelUtilizationSummary(
        radios: [
          ChannelUtilizationRadio(
            id: "radio-office-5",
            eeroID: "eero-office",
            eeroName: "Office",
            band: "5 GHz",
            controlChannel: 36,
            centerChannel: nil,
            channelBandwidth: nil,
            frequencyMHz: nil,
            averageUtilization: 42,
            maxUtilization: 69,
            p99Utilization: nil,
            timeSeries: [
              ChannelUtilizationSample(
                id: "sample-office-1",
                timestamp: now,
                busyPercent: 42,
                noisePercent: 8,
                rxTxPercent: nil,
                rxOtherPercent: nil
              )
            ]
          ),
          ChannelUtilizationRadio(
            id: "radio-living-24",
            eeroID: "eero-living",
            eeroName: "Living Room",
            band: "2.4 GHz",
            controlChannel: 1,
            centerChannel: nil,
            channelBandwidth: nil,
            frequencyMHz: nil,
            averageUtilization: 31,
            maxUtilization: 58,
            p99Utilization: nil,
            timeSeries: [
              ChannelUtilizationSample(
                id: "sample-living-1",
                timestamp: now,
                busyPercent: 31,
                noisePercent: 5,
                rxTxPercent: nil,
                rxOtherPercent: nil
              )
            ]
          ),
        ],
        sampledAt: now
      ),
      proxiedNodes: ProxiedNodesSummary(
        enabled: true,
        totalDevices: 2,
        onlineDevices: 1,
        offlineDevices: 1
      ),
      clients: fixtureClients,
      profiles: [],
      devices: fixtureDevices,
      lastUpdated: now
    )

    return [
      ConsistencyCase(
        name: "fixture:network-1",
        rawNetwork: rawNetwork,
        network: fixtureNetwork
      )
    ]
  }

  private func liveCases(from result: FetchAccountWithRawPayloadsResult) -> [ConsistencyCase] {
    var rawNetworksByID: [String: [String: Any]] = [:]
    for payload in result.rawNetworks {
      guard let object = try? JSONSerialization.jsonObject(with: payload.payload) as? [String: Any]
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

    var cases: [ConsistencyCase] = []
    for network in result.snapshot.networks {
      let key = normalizeLookupKey(network.id)
      if let rawNetwork = rawNetworksByID[key] {
        cases.append(
          ConsistencyCase(
            name: "live:\(network.id)",
            rawNetwork: rawNetwork,
            network: network
          )
        )
      }
    }
    return cases
  }

  // MARK: - Metric Comparisons

  private func metricMismatch(
    metricID: String,
    expected: MetricValue?,
    actual: MetricValue?,
    required: Bool,
    tolerance: Double,
    rawHint: String,
    modelHint: String
  ) -> String? {
    if required, expected == nil {
      return "Expected value missing while metric is required. rawHint=\(rawHint)"
    }
    if required, actual == nil {
      return "Actual model value missing while metric is required. modelHint=\(modelHint)"
    }
    guard let expected else {
      return nil
    }
    guard let actual else {
      return nil
    }
    guard actual.matches(expected, tolerance: tolerance) else {
      return
        "Mismatch for \(metricID): expected=\(expected) actual=\(actual) rawHint=\(rawHint) modelHint=\(modelHint)"
    }
    return nil
  }

  private func metricString(_ value: String?) -> MetricValue? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : .string(trimmed)
  }

  private func metricInt(_ value: Int?) -> MetricValue? {
    guard let value else { return nil }
    return .int(value)
  }

  private func metricDouble(_ value: Double?) -> MetricValue? {
    guard let value else { return nil }
    return .double(value)
  }

  private func metricBool(_ value: Bool?) -> MetricValue? {
    guard let value else { return nil }
    return .bool(value)
  }

  private func hasNonEmptyString(_ value: String?) -> Bool {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !trimmed.isEmpty
  }

  // MARK: - Raw Network Semantics (App-Aligned Rules)

  private func rawConnectedClientCount(_ raw: [String: Any]) -> Int {
    DictionaryValue.dictArray(in: raw, path: ["devices", "data"])
      .filter { DictionaryValue.bool(in: $0, path: ["connected"]) ?? false }
      .count
  }

  private func rawConnectedGuestClientCount(_ raw: [String: Any]) -> Int {
    DictionaryValue.dictArray(in: raw, path: ["devices", "data"])
      .filter {
        (DictionaryValue.bool(in: $0, path: ["connected"]) ?? false)
          && (DictionaryValue.bool(in: $0, path: ["is_guest"]) ?? false)
      }
      .count
  }

  private func rawGatewayIP(_ raw: [String: Any]) -> String? {
    if let gatewayIP = DictionaryValue.string(in: raw, path: ["gateway_ip"]), !gatewayIP.isEmpty {
      return gatewayIP
    }
    for device in rawEeroRows(raw) {
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

  private func rawSpeedDown(_ raw: [String: Any]) -> Double? {
    DictionaryValue.double(in: raw, path: ["speed", "down", "value"])
      ?? DictionaryValue.double(in: raw, path: ["speedtest", "0", "down_mbps"])
      ?? rawSpeedTestRecord(raw)?["down_mbps"].flatMap(doubleValue)
      ?? rawSpeedTestRecord(raw)?["down"].flatMap { dict in
        guard let dict = dict as? [String: Any] else { return nil }
        return DictionaryValue.double(in: dict, path: ["value"])
      }
  }

  private func rawSpeedUp(_ raw: [String: Any]) -> Double? {
    DictionaryValue.double(in: raw, path: ["speed", "up", "value"])
      ?? DictionaryValue.double(in: raw, path: ["speedtest", "0", "up_mbps"])
      ?? rawSpeedTestRecord(raw)?["up_mbps"].flatMap(doubleValue)
      ?? rawSpeedTestRecord(raw)?["up"].flatMap { dict in
        guard let dict = dict as? [String: Any] else { return nil }
        return DictionaryValue.double(in: dict, path: ["value"])
      }
  }

  private func rawSpeedTestRecord(_ raw: [String: Any]) -> [String: Any]? {
    if let rows = raw["speedtest"] as? [[String: Any]], let first = rows.first {
      return first
    }
    return raw["speedtest"] as? [String: Any]
  }

  private func rawEeroRows(_ raw: [String: Any]) -> [[String: Any]] {
    DictionaryValue.dictArray(in: raw, path: ["eeros", "data"])
  }

  private func rawOnlineEeroCount(_ raw: [String: Any]) -> Int {
    rawEeroRows(raw)
      .filter { row in
        let status =
          DictionaryValue.string(in: row, path: ["status"])
          ?? DictionaryValue.string(in: row, path: ["status", "value"])
          ?? ""
        return statusIsOnline(status)
      }
      .count
  }

  private func statusIsOnline(_ status: String) -> Bool {
    let normalized = status.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized == "green"
      || normalized == "online"
      || normalized == "connected"
      || normalized == "up"
  }

  private func rawProxiedSummary(_ raw: [String: Any]) -> (total: Int, online: Int, offline: Int)? {
    guard let proxied = DictionaryValue.dict(in: raw, path: ["proxied_nodes"]) else {
      return nil
    }
    let devices = DictionaryValue.dictArray(in: proxied, path: ["devices"])
    let online = devices.filter { device in
      let status =
        DictionaryValue.string(in: device, path: ["status"])
        ?? DictionaryValue.string(in: device, path: ["status", "value"])
        ?? ""
      let normalized = status.lowercased()
      return normalized == "green" || normalized.contains("online")
    }.count
    let offline = devices.filter { device in
      let status =
        DictionaryValue.string(in: device, path: ["status"])
        ?? DictionaryValue.string(in: device, path: ["status", "value"])
        ?? ""
      let normalized = status.lowercased()
      return normalized == "red" || normalized.contains("offline")
    }.count
    return (devices.count, online, offline)
  }

  private func rawChannelUtilizationRows(_ raw: [String: Any]) -> [[String: Any]]? {
    if let dict = raw["channel_utilization"] as? [String: Any] {
      let rows = DictionaryValue.dictArray(in: dict, path: ["utilization"])
      return rows.isEmpty ? nil : rows
    }
    if let rows = raw["channel_utilization"] as? [[String: Any]] {
      return rows.isEmpty ? nil : rows
    }
    return nil
  }

  private func rawNetworkUsageTotals(
    _ raw: [String: Any],
    period: String
  ) -> (download: Int?, upload: Int?) {
    let rows = usageRows(in: raw, path: ["activity", "network", "data_usage_\(period)"])
    guard !rows.isEmpty else {
      return (nil, nil)
    }
    var totalDownload: Int?
    var totalUpload: Int?
    for row in rows {
      if let download = DictionaryValue.int(in: row, path: ["download"])
        ?? integerValue(row["download"])
      {
        totalDownload = (totalDownload ?? 0) + max(0, download)
      }
      if let upload = DictionaryValue.int(in: row, path: ["upload"]) ?? integerValue(row["upload"])
      {
        totalUpload = (totalUpload ?? 0) + max(0, upload)
      }

      let type = (DictionaryValue.string(in: row, path: ["type"]) ?? "").lowercased()
      let isDownloadSeries = type.contains("download") || type == "down"
      let isUploadSeries = type.contains("upload") || type == "up"
      guard isDownloadSeries || isUploadSeries else {
        continue
      }

      var seriesTotal: Int?
      if let sum = DictionaryValue.int(in: row, path: ["sum"]) ?? integerValue(row["sum"]) {
        seriesTotal = max(0, sum)
      } else {
        let seriesRows = DictionaryValue.dictArray(in: row, path: ["values"])
        if !seriesRows.isEmpty {
          let values = seriesRows.compactMap { sample in
            DictionaryValue.int(in: sample, path: ["value"]) ?? integerValue(sample["value"])
          }
          if !values.isEmpty {
            seriesTotal = values.reduce(0) { $0 + max(0, $1) }
          }
        }
      }

      guard let seriesTotal else {
        continue
      }
      if isDownloadSeries {
        totalDownload = seriesTotal
      }
      if isUploadSeries {
        totalUpload = seriesTotal
      }
    }
    return (download: totalDownload, upload: totalUpload)
  }

  private func rawTopDeviceUsageCount(_ raw: [String: Any]) -> Int? {
    let dayRows = usageRows(in: raw, path: ["activity", "devices", "data_usage_day"])
    let weekRows = usageRows(in: raw, path: ["activity", "devices", "data_usage_week"])
    let monthRows = usageRows(in: raw, path: ["activity", "devices", "data_usage_month"])
    let allRows = dayRows + weekRows + monthRows

    var keys: Set<String> = []
    for row in allRows {
      if let key = resourceKeyForUsageRow(row) {
        keys.insert(normalizeLookupKey(key))
      }
    }
    keys.remove("")
    guard !keys.isEmpty else {
      return nil
    }
    return keys.count
  }

  private func rawRealtimeUsage(_ raw: [String: Any]) -> (download: Double, upload: Double)? {
    let rawClients = DictionaryValue.dictArray(in: raw, path: ["devices", "data"])
    let active = rawClients.filter { row in
      let connected = DictionaryValue.bool(in: row, path: ["connected"]) ?? false
      let hasUsage = rawClientUsageDownMbps(row) != nil || rawClientUsageUpMbps(row) != nil
      return connected && hasUsage
    }
    guard !active.isEmpty else {
      return nil
    }
    let down = active.reduce(0.0) { partial, row in
      partial + max(0, rawClientUsageDownMbps(row) ?? 0)
    }
    let up = active.reduce(0.0) { partial, row in
      partial + max(0, rawClientUsageUpMbps(row) ?? 0)
    }
    return (down, up)
  }

  private func rawClientUsageDownMbps(_ row: [String: Any]) -> Double? {
    firstDouble(
      in: row,
      paths: [
        ["usage", "down_mbps"],
        ["usage", "downMbps"],
        ["down_mbps"],
        ["downMbps"],
      ]
    )
  }

  private func rawClientUsageUpMbps(_ row: [String: Any]) -> Double? {
    firstDouble(
      in: row,
      paths: [
        ["usage", "up_mbps"],
        ["usage", "upMbps"],
        ["up_mbps"],
        ["upMbps"],
      ]
    )
  }

  private func rawEthernetInterfaceCount(_ row: [String: Any]) -> Int? {
    let interfaces = DictionaryValue.dictArray(
      in: row, path: ["connections", "ports", "interfaces"])
    guard !interfaces.isEmpty else {
      return nil
    }
    return interfaces.count
  }

  private func rawWirelessAttachmentCount(_ row: [String: Any]) -> Int? {
    let rows = DictionaryValue.dictArray(in: row, path: ["connections", "wireless_devices"])
    guard !rows.isEmpty else {
      return nil
    }
    return rows.count
  }

  private func usageRows(in data: [String: Any], path: [String]) -> [[String: Any]] {
    let directRows = DictionaryValue.dictArray(in: data, path: path)
    if !directRows.isEmpty {
      return directRows
    }
    if let dict = DictionaryValue.dict(in: data, path: path),
      let values = dict["values"] as? [[String: Any]]
    {
      return values
    }
    return []
  }

  private func resourceKeyForUsageRow(_ row: [String: Any]) -> String? {
    if let url = DictionaryValue.string(in: row, path: ["url"]) {
      let id = DictionaryValue.id(fromURL: url)
      if !id.isEmpty {
        return id
      }
    }
    if let mac = DictionaryValue.string(in: row, path: ["mac"]),
      !mac.isEmpty,
      !isPlaceholderMAC(mac)
    {
      return mac
    }
    if let identifier = DictionaryValue.string(in: row, path: ["id"]), !identifier.isEmpty {
      return identifier
    }
    return nil
  }

  private func isPlaceholderMAC(_ value: String) -> Bool {
    let compact =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
    guard compact.count == 12 else {
      return false
    }
    return Set(compact) == ["0"]
  }

  private func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
      return value
    }
    if let value = value as? Float {
      return Double(value)
    }
    if let value = value as? NSNumber {
      return value.doubleValue
    }
    if let value = value as? String {
      return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private func firstDouble(in row: [String: Any], paths: [[String]]) -> Double? {
    for path in paths {
      if let value = DictionaryValue.double(in: row, path: path) {
        return value
      }
      if let value = doubleValue(DictionaryValue.value(in: row, path: path)) {
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

    if let value = doubleValue(value) {
      if value > 100_000 {
        return value / 1_000_000
      }
      return value
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

  // MARK: - Shared Matching Helpers

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

  // MARK: - Report Attachment

  private func attach(report: ConsistencyReport, activityName: String) throws {
    let rendered = report.rendered
    let textAttachment = XCTAttachment(string: rendered)
    textAttachment.name = "\(activityName).txt"
    textAttachment.lifetime = .keepAlways
    add(textAttachment)

    if let jsonString = try? report.jsonString() {
      let jsonAttachment = XCTAttachment(string: jsonString)
      jsonAttachment.name = "display-model-consistency.json"
      jsonAttachment.lifetime = .keepAlways
      add(jsonAttachment)
    }
    print(rendered)
  }

  // MARK: - Env and Repository Helpers

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

  private func loadSourceFile(relativePath: String) throws -> String {
    guard let root = repositoryRootURL() else {
      throw XCTSkip("Unable to locate repository root for source load.")
    }
    let sourceFile = root.appendingPathComponent(relativePath)
    return try String(contentsOf: sourceFile, encoding: .utf8)
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

// MARK: - Contract Types

private enum MetricProvenance: String {
  case direct
  case derived
  case proxy
}

private enum MetricValue: CustomStringConvertible, Equatable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  var description: String {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return "\(value)"
    case .double(let value):
      return String(format: "%.6f", value)
    case .bool(let value):
      return value ? "true" : "false"
    }
  }

  func matches(_ other: MetricValue, tolerance: Double) -> Bool {
    switch (self, other) {
    case (.string(let lhs), .string(let rhs)):
      return lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    case (.int(let lhs), .int(let rhs)):
      return lhs == rhs
    case (.double(let lhs), .double(let rhs)):
      return abs(lhs - rhs) <= max(0.000_1, tolerance)
    case (.bool(let lhs), .bool(let rhs)):
      return lhs == rhs
    case (.int(let lhs), .double(let rhs)):
      return abs(Double(lhs) - rhs) <= max(0.000_1, tolerance)
    case (.double(let lhs), .int(let rhs)):
      return abs(lhs - Double(rhs)) <= max(0.000_1, tolerance)
    default:
      return false
    }
  }
}

private struct NetworkMetricContract {
  let id: String
  let provenance: MetricProvenance
  let proxyAllowed: Bool
  let outIndicators: [String]
  let rawHint: String
  let modelHint: String
  let expected: ([String: Any]) -> MetricValue?
  let actual: (EeroNetwork) -> MetricValue?
  let required: ([String: Any]) -> Bool
  let tolerance: Double
}

private struct ClientMetricContract {
  let id: String
  let provenance: MetricProvenance
  let proxyAllowed: Bool
  let outIndicators: [String]
  let rawHint: String
  let modelHint: String
  let expected: ([String: Any]) -> MetricValue?
  let actual: (EeroClient) -> MetricValue?
  let required: ([String: Any]) -> Bool
  let tolerance: Double
}

private struct DeviceMetricContract {
  let id: String
  let provenance: MetricProvenance
  let proxyAllowed: Bool
  let outIndicators: [String]
  let rawHint: String
  let modelHint: String
  let expected: ([String: Any]) -> MetricValue?
  let actual: (EeroDevice) -> MetricValue?
  let required: ([String: Any]) -> Bool
  let tolerance: Double
}

private struct ContractDescriptor {
  let id: String
  let provenance: MetricProvenance
  let proxyAllowed: Bool
  let outIndicators: [String]
}

private struct ConsistencyCase {
  let name: String
  let rawNetwork: [String: Any]
  let network: EeroNetwork
}

private struct ConsistencyFailure {
  let caseName: String
  let metricID: String
  let provenance: MetricProvenance
  let detail: String
}

private struct ConsistencyReport {
  let outPath: String?
  let evaluatedMetrics: Int
  let failures: [ConsistencyFailure]
  let warnings: [String]
  let strictProxyMode: Bool

  var rendered: String {
    var lines: [String] = []
    lines.append("Display Model Consistency")
    lines.append("Out Path: \(outPath ?? "Unavailable")")
    lines.append("Evaluated Metrics: \(evaluatedMetrics)")
    lines.append("Failures: \(failures.count)")
    lines.append("Strict Proxy Mode: \(strictProxyMode ? "enabled" : "disabled")")

    if !warnings.isEmpty {
      lines.append("")
      lines.append("Warnings")
      for warning in warnings {
        lines.append("- \(warning)")
      }
    }

    if failures.isEmpty {
      lines.append("")
      lines.append("Status: PASS")
    } else {
      lines.append("")
      lines.append("Status: FAIL")
      for failure in failures {
        lines.append(
          "- [\(failure.provenance.rawValue)] \(failure.caseName) · \(failure.metricID) · \(failure.detail)"
        )
      }
    }

    return lines.joined(separator: "\n")
  }

  func jsonString() throws -> String {
    let payload: [String: Any] = [
      "outPath": outPath ?? "",
      "evaluatedMetrics": evaluatedMetrics,
      "failureCount": failures.count,
      "strictProxyMode": strictProxyMode,
      "warnings": warnings,
      "failures": failures.map {
        [
          "caseName": $0.caseName,
          "metricID": $0.metricID,
          "provenance": $0.provenance.rawValue,
          "detail": $0.detail,
        ]
      },
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
