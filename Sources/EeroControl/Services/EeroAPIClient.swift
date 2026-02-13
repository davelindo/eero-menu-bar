import Foundation

struct LoginResponse: Sendable {
  var userToken: String
}

struct VerifyResponse: Sendable {
  var accountName: String?
  var accountID: String?
}

struct RefreshResponse: Sendable {
  var userToken: String
}

struct UpdateConfig: Sendable {
  var networkIDs: Set<String> = []
}

struct RawNetworkPayload: Sendable {
  var networkID: String
  var payload: Data
}

struct FetchAccountWithRawPayloadsResult: Sendable {
  var snapshot: EeroAccountSnapshot
  var rawNetworks: [RawNetworkPayload]
}

enum EeroRouteCatalog {
  static let getResourceKeys: Set<String> = [
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

  static let postResourceKeys: Set<String> = [
    "burst_reporters",
    "reboot",
    "reboot_eero",
    "run_speedtest",
  ]
}

enum EeroAPIError: Error, LocalizedError {
  case unauthenticated
  case invalidResponse
  case invalidPayload
  case server(code: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .unauthenticated:
      return "Not authenticated with eero."
    case .invalidResponse:
      return "Invalid response from eero API."
    case .invalidPayload:
      return "Unexpected eero API payload."
    case .server(let code, let message):
      return "Eero API error (\(code)): \(message)"
    }
  }
}

protocol EeroAPIClientProtocol: Sendable {
  func setUserToken(_ token: String?) async
  func currentUserToken() async -> String?
  func login(login: String) async throws -> LoginResponse
  func verify(code: String) async throws -> VerifyResponse
  func refreshSession() async throws -> RefreshResponse
  func fetchAccount(config: UpdateConfig) async throws -> EeroAccountSnapshot
  func perform(_ action: EeroAction) async throws
}

actor EeroAPIClient: EeroAPIClientProtocol {
  private let baseURL = URL(string: "https://api-user.e2ro.com")!
  private let session: URLSession
  private var userToken: String?

  init(session: URLSession = .shared) {
    self.session = session
  }

  func setUserToken(_ token: String?) async {
    userToken = token
  }

  func currentUserToken() async -> String? {
    userToken
  }

  func login(login: String) async throws -> LoginResponse {
    let response = try await call(
      method: .post,
      pathOrURL: "/2.2/login",
      json: ["login": login],
      requiresAuth: false,
      retryOnAuthFailure: false
    )

    guard let payload = response as? [String: Any],
      let token = payload["user_token"] as? String
    else {
      throw EeroAPIError.invalidPayload
    }

    userToken = token
    return LoginResponse(userToken: token)
  }

  func verify(code: String) async throws -> VerifyResponse {
    let response = try await call(
      method: .post,
      pathOrURL: "/2.2/login/verify",
      json: ["code": code],
      requiresAuth: true,
      retryOnAuthFailure: false
    )

    guard let payload = response as? [String: Any] else {
      throw EeroAPIError.invalidPayload
    }

    return VerifyResponse(
      accountName: payload["name"] as? String,
      accountID: payload["log_id"] as? String
    )
  }

  func refreshSession() async throws -> RefreshResponse {
    let response = try await call(
      method: .post,
      pathOrURL: "/2.2/login/refresh",
      json: nil,
      requiresAuth: true,
      retryOnAuthFailure: false
    )

    guard let payload = response as? [String: Any],
      let token = payload["user_token"] as? String
    else {
      throw EeroAPIError.invalidPayload
    }

    userToken = token
    return RefreshResponse(userToken: token)
  }

  func fetchAccount(config: UpdateConfig = UpdateConfig()) async throws -> EeroAccountSnapshot {
    try await fetchAccountSnapshot(config: config, includeRawPayloads: false).snapshot
  }

  func fetchAccountWithRawPayloads(config: UpdateConfig = UpdateConfig()) async throws
    -> FetchAccountWithRawPayloadsResult
  {
    try await fetchAccountSnapshot(config: config, includeRawPayloads: true)
  }

  private func fetchAccountSnapshot(
    config: UpdateConfig,
    includeRawPayloads: Bool
  ) async throws -> FetchAccountWithRawPayloadsResult {
    guard
      let account = try await call(
        method: .get, pathOrURL: "/2.2/account", json: nil, requiresAuth: true) as? [String: Any]
    else {
      throw EeroAPIError.invalidPayload
    }

    let networkRefs = DictionaryValue.dictArray(in: account, path: ["networks", "data"])
    var networks: [EeroNetwork] = []
    var modelAuditAccumulator = ModelFieldAuditAccumulator()
    var rawNetworks: [RawNetworkPayload] = []

    for ref in networkRefs {
      guard let networkURL = DictionaryValue.string(in: ref, path: ["url"]) else {
        continue
      }

      let networkID = DictionaryValue.id(fromURL: networkURL)
      if !config.networkIDs.isEmpty, !config.networkIDs.contains(networkID) {
        continue
      }

      guard
        var networkData = try await call(
          method: .get, pathOrURL: networkURL, json: nil, requiresAuth: true) as? [String: Any]
      else {
        continue
      }

      var resources = DictionaryValue.stringMap(in: networkData, path: ["resources"])

      let missingUpdateStatus =
        DictionaryValue.string(in: networkData, path: ["updates", "update_status"]) == nil
        && DictionaryValue.string(in: networkData, path: ["updates", "status"]) == nil
        && DictionaryValue.string(in: networkData, path: ["update_status"]) == nil
        && DictionaryValue.string(in: networkData, path: ["firmware_update_status"]) == nil
      let missingManagedFields =
        DictionaryValue.value(in: networkData, path: ["proxied_nodes"]) == nil
        || DictionaryValue.value(in: networkData, path: ["channel_utilization"]) == nil
        || missingUpdateStatus
      if missingManagedFields,
        let managed = await fetchResourceData(
          resources: resources,
          resourceKeys: ["managed"],
          fallbackPath: "/2.2/networks/\(networkID)/managed"
        ) as? [String: Any]
      {
        networkData = Self.deepMergeDictionary(base: networkData, incoming: managed)
        resources = DictionaryValue.stringMap(in: networkData, path: ["resources"])
      }

      if let thread = await fetchResourceData(
        resources: resources,
        resourceKeys: ["thread"],
        fallbackPath: "/2.2/networks/\(networkID)/thread"
      ) as? [String: Any] {
        networkData["thread"] = thread
      }

      if let guestNetwork = await fetchResourceData(
        resources: resources,
        resourceKeys: ["guestnetwork", "guest_network"],
        fallbackPath: "/2.2/networks/\(networkID)/guestnetwork"
      ) as? [String: Any] {
        networkData["guest_network"] = guestNetwork
      }

      if let devices = await fetchDevicesSnapshot(
        resources: resources,
        networkID: networkID
      ) {
        let enrichedDevices = await enrichDevicesWithDetailTelemetry(devices, networkID: networkID)
        networkData["devices"] = ["count": enrichedDevices.count, "data": enrichedDevices]
      }

      if let profiles = await fetchResourceData(
        resources: resources,
        resourceKeys: ["profiles"],
        fallbackPath: "/2.2/networks/\(networkID)/profiles"
      ) as? [[String: Any]] {
        let catalogs = await fetchProfileApplicationCatalog(
          networkID: networkID, profiles: profiles)
        let enrichedProfiles = profiles.map { profile in
          guard let profileID = Self.profileIdentifier(from: profile),
            let catalog = catalogs[profileID]
          else {
            return profile
          }
          var enriched = profile
          enriched["applications_catalog"] = catalog
          return enriched
        }
        networkData["profiles"] = ["count": enrichedProfiles.count, "data": enrichedProfiles]
      }

      if let eeros = await fetchResourceData(
        resources: resources,
        resourceKeys: ["eeros"],
        fallbackPath: "/2.2/networks/\(networkID)/eeros"
      ) as? [[String: Any]] {
        let enrichedEeros = await fetchExpandedEeros(eeros)
        networkData["eeros"] = ["count": enrichedEeros.count, "data": enrichedEeros]
      }

      if let acCompat = await fetchResourceData(
        resources: resources,
        resourceKeys: ["ac_compat"],
        fallbackPath: "/2.2/networks/\(networkID)/ac_compat"
      ) as? [String: Any] {
        networkData["ac_compat"] = acCompat
      }

      if let blacklist = await fetchResourceData(
        resources: resources,
        resourceKeys: ["blacklist", "device_blacklist"],
        fallbackPath: "/2.2/networks/\(networkID)/blacklist"
      ) as? [[String: Any]] {
        networkData["device_blacklist"] = ["count": blacklist.count, "data": blacklist]
      }

      if let diagnostics = await fetchResourceData(
        resources: resources,
        resourceKeys: ["diagnostics"],
        fallbackPath: "/2.2/networks/\(networkID)/diagnostics"
      ) as? [String: Any] {
        networkData["diagnostics"] = diagnostics
      }

      if let forwards = await fetchResourceData(
        resources: resources,
        resourceKeys: ["forwards"],
        fallbackPath: "/2.2/networks/\(networkID)/forwards"
      ) as? [[String: Any]] {
        networkData["forwards"] = ["count": forwards.count, "data": forwards]
      }

      if let reservations = await fetchResourceData(
        resources: resources,
        resourceKeys: ["reservations"],
        fallbackPath: "/2.2/networks/\(networkID)/reservations"
      ) as? [[String: Any]] {
        networkData["reservations"] = ["count": reservations.count, "data": reservations]
      }

      if let routing = await fetchResourceData(
        resources: resources,
        resourceKeys: ["routing"],
        fallbackPath: "/2.2/networks/\(networkID)/routing"
      ) as? [String: Any] {
        networkData["routing"] = routing
      }

      if let speedTest = await fetchResourceData(
        resources: resources,
        resourceKeys: ["speedtest"],
        fallbackPath: "/2.2/networks/\(networkID)/speedtest"
      ) {
        networkData["speedtest"] = speedTest
      }

      if let updates = await fetchResourceData(
        resources: resources,
        resourceKeys: ["updates"],
        fallbackPath: "/2.2/networks/\(networkID)/updates"
      ) as? [String: Any] {
        networkData["updates"] = updates
      }

      if let support = await fetchResourceData(
        resources: resources,
        resourceKeys: ["support"],
        fallbackPath: "/2.2/networks/\(networkID)/support"
      ) as? [String: Any] {
        networkData["support"] = support
      }

      if let insights = await fetchResourceData(
        resources: resources,
        resourceKeys: ["insights"],
        fallbackPath: "/2.2/networks/\(networkID)/insights"
      ) {
        networkData["insights_response"] = insights
      }

      if let ouicheck = await fetchResourceData(
        resources: resources,
        resourceKeys: ["ouicheck"],
        fallbackPath: "/2.2/networks/\(networkID)/ouicheck"
      ) {
        networkData["ouicheck_response"] = ouicheck
      }

      let timezoneIdentifier =
        DictionaryValue.string(in: networkData, path: ["timezone", "value"])
        ?? TimeZone.current.identifier

      if let activity = await fetchActivitySnapshot(
        networkURL: networkURL, timezoneIdentifier: timezoneIdentifier)
      {
        networkData["activity"] = activity
      }

      if let channelUtilization = await fetchChannelUtilizationSnapshot(
        networkID: networkID,
        networkURL: networkURL,
        resources: resources,
        timezoneIdentifier: timezoneIdentifier,
        eeroDevices: DictionaryValue.dictArray(in: networkData, path: ["eeros", "data"])
      ) {
        networkData["channel_utilization"] = channelUtilization
      }

      if includeRawPayloads,
        JSONSerialization.isValidJSONObject(networkData),
        let payload = try? JSONSerialization.data(withJSONObject: networkData, options: [])
      {
        rawNetworks.append(RawNetworkPayload(networkID: networkID, payload: payload))
      }

      modelAuditAccumulator.record(networkData: networkData)
      networks.append(Self.parseNetwork(networkData))
    }

    let fetchedAt = Date()
    let snapshot = EeroAccountSnapshot(
      fetchedAt: fetchedAt,
      networks: networks,
      modelAudit: modelAuditAccumulator.summary(generatedAt: fetchedAt)
    )
    return FetchAccountWithRawPayloadsResult(snapshot: snapshot, rawNetworks: rawNetworks)
  }

  private func fetchResourceData(
    resources: [String: String],
    resourceKeys: [String],
    fallbackPath: String
  ) async -> Any? {
    let pathOrURL = resourceKeys.compactMap { resources[$0] }.first ?? fallbackPath
    return try? await call(method: .get, pathOrURL: pathOrURL, json: nil, requiresAuth: true)
  }

  private func fetchDevicesSnapshot(
    resources: [String: String],
    networkID: String
  ) async -> [[String: Any]]? {
    let devicesPath =
      ["devices", "clients"].compactMap { resources[$0] }.first
      ?? "/2.2/networks/\(networkID)/devices"
    let queryVariants: [[URLQueryItem]] = [
      [
        URLQueryItem(name: "thread", value: "true"),
        URLQueryItem(name: "proxied_node", value: "true"),
      ],
      [
        URLQueryItem(name: "thread", value: "true")
      ],
      [
        URLQueryItem(name: "proxied_node", value: "true")
      ],
      [],
    ]

    var bestRows: [[String: Any]]?
    var bestScore: Int?

    for queryItems in queryVariants {
      let candidatePath: String
      if queryItems.isEmpty {
        candidatePath = devicesPath
      } else if let withQuery = withQueryItems(pathOrURL: devicesPath, queryItems: queryItems) {
        candidatePath = withQuery
      } else {
        continue
      }

      guard
        let response = try? await call(
          method: .get, pathOrURL: candidatePath, json: nil, requiresAuth: true)
      else {
        continue
      }
      guard let rows = normalizeObjectArray(response), !rows.isEmpty else {
        continue
      }

      let score = Self.deviceTelemetryScore(rows)
      if bestScore == nil || score > (bestScore ?? Int.min) {
        bestScore = score
        bestRows = rows
      }
    }

    return bestRows
  }

  private func enrichDevicesWithDetailTelemetry(
    _ devices: [[String: Any]],
    networkID: String
  ) async -> [[String: Any]] {
    var enriched: [[String: Any]] = []
    enriched.reserveCapacity(devices.count)

    for device in devices {
      guard deviceNeedsTelemetryEnrichment(device),
        let detailPath = detailPathForDevice(device, networkID: networkID),
        let detail = try? await call(
          method: .get, pathOrURL: detailPath, json: nil, requiresAuth: true) as? [String: Any]
      else {
        enriched.append(device)
        continue
      }

      enriched.append(Self.deepMergeDictionary(base: device, incoming: detail))
    }

    return enriched
  }

  private func deviceNeedsTelemetryEnrichment(_ device: [String: Any]) -> Bool {
    let hasDownMbps =
      Self.numericValue(
        DictionaryValue.value(in: device, path: ["usage", "down_mbps"])
          ?? DictionaryValue.value(in: device, path: ["usage", "downMbps"])
          ?? DictionaryValue.value(in: device, path: ["down_mbps"])
          ?? DictionaryValue.value(in: device, path: ["downMbps"])
      ) != nil
    let hasUpMbps =
      Self.numericValue(
        DictionaryValue.value(in: device, path: ["usage", "up_mbps"])
          ?? DictionaryValue.value(in: device, path: ["usage", "upMbps"])
          ?? DictionaryValue.value(in: device, path: ["up_mbps"])
          ?? DictionaryValue.value(in: device, path: ["upMbps"])
      ) != nil
    let hasDownPercent =
      Self.integerValue(
        DictionaryValue.value(in: device, path: ["usage", "down_percent_current_usage"])
          ?? DictionaryValue.value(in: device, path: ["usage", "down_percent_current"])
          ?? DictionaryValue.value(in: device, path: ["usage", "downPercentCurrentUsage"])
          ?? DictionaryValue.value(in: device, path: ["usage", "downPercentCurrent"])
          ?? DictionaryValue.value(in: device, path: ["down_percent_current_usage"])
          ?? DictionaryValue.value(in: device, path: ["down_percent_current"])
          ?? DictionaryValue.value(in: device, path: ["downPercentCurrentUsage"])
          ?? DictionaryValue.value(in: device, path: ["downPercentCurrent"])
      ) != nil
    let hasUpPercent =
      Self.integerValue(
        DictionaryValue.value(in: device, path: ["usage", "up_percent_current_usage"])
          ?? DictionaryValue.value(in: device, path: ["usage", "up_percent_current"])
          ?? DictionaryValue.value(in: device, path: ["usage", "upPercentCurrentUsage"])
          ?? DictionaryValue.value(in: device, path: ["usage", "upPercentCurrent"])
          ?? DictionaryValue.value(in: device, path: ["up_percent_current_usage"])
          ?? DictionaryValue.value(in: device, path: ["up_percent_current"])
          ?? DictionaryValue.value(in: device, path: ["upPercentCurrentUsage"])
          ?? DictionaryValue.value(in: device, path: ["upPercentCurrent"])
      ) != nil
    let hasRxRate =
      Self.firstRateMbps(
        in: device,
        pathPrefixes: [
          ["connectivity", "rx_rate_info"],
          ["connectivity", "rx_rate"],
          ["rx_rate_info"],
          ["rx_rate"],
        ]
      ) != nil
    let hasTxRate =
      Self.firstRateMbps(
        in: device,
        pathPrefixes: [
          ["connectivity", "tx_rate_info"],
          ["connectivity", "tx_rate"],
          ["tx_rate_info"],
          ["tx_rate"],
        ]
      ) != nil

    return !(hasDownMbps && hasUpMbps && hasDownPercent && hasUpPercent && hasRxRate && hasTxRate)
  }

  private func detailPathForDevice(
    _ device: [String: Any],
    networkID: String
  ) -> String? {
    if let url = DictionaryValue.string(in: device, path: ["url"]),
      !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return url
    }

    guard let mac = DictionaryValue.string(in: device, path: ["mac"]),
      !mac.isEmpty,
      let encodedMAC = mac.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      return nil
    }
    return "/2.2/networks/\(networkID)/devices/\(encodedMAC)"
  }

  private func normalizeObjectArray(_ response: Any) -> [[String: Any]]? {
    if let rows = response as? [[String: Any]] {
      return rows
    }
    if let dict = response as? [String: Any] {
      if let rows = dict["data"] as? [[String: Any]] {
        return rows
      }
      if let rows = dict["values"] as? [[String: Any]] {
        return rows
      }
    }
    return nil
  }

  private static func deviceTelemetryScore(_ rows: [[String: Any]]) -> Int {
    var rateBpsCount = 0
    var bitrateStringCount = 0
    var sourceCount = 0
    var usageCount = 0

    for row in rows {
      let connectivity = DictionaryValue.dict(in: row, path: ["connectivity"]) ?? [:]
      let hasRateBps =
        DictionaryValue.value(in: connectivity, path: ["rx_rate_info", "rate_bps"]) != nil
        || DictionaryValue.value(in: connectivity, path: ["tx_rate_info", "rate_bps"]) != nil
        || DictionaryValue.value(in: connectivity, path: ["rx_rate", "rate_bps"]) != nil
        || DictionaryValue.value(in: connectivity, path: ["tx_rate", "rate_bps"]) != nil
        || DictionaryValue.value(in: row, path: ["rx_rate_info", "rate_bps"]) != nil
        || DictionaryValue.value(in: row, path: ["tx_rate_info", "rate_bps"]) != nil
        || DictionaryValue.value(in: row, path: ["rx_rate", "rate_bps"]) != nil
        || DictionaryValue.value(in: row, path: ["tx_rate", "rate_bps"]) != nil

      if hasRateBps {
        rateBpsCount += 1
      }

      let hasBitrateString =
        DictionaryValue.value(in: connectivity, path: ["rx_bitrate"]) != nil
        || DictionaryValue.value(in: connectivity, path: ["tx_bitrate"]) != nil
        || DictionaryValue.value(in: row, path: ["rx_bitrate"]) != nil
        || DictionaryValue.value(in: row, path: ["tx_bitrate"]) != nil

      if hasBitrateString {
        bitrateStringCount += 1
      }

      let hasSource =
        DictionaryValue.value(in: row, path: ["source", "url"]) != nil
        || DictionaryValue.value(in: row, path: ["source", "location"]) != nil
      if hasSource {
        sourceCount += 1
      }

      let hasUsage =
        DictionaryValue.value(in: row, path: ["usage", "down_mbps"]) != nil
        || DictionaryValue.value(in: row, path: ["usage", "up_mbps"]) != nil
        || DictionaryValue.value(in: row, path: ["usage", "down_percent_current_usage"]) != nil
        || DictionaryValue.value(in: row, path: ["usage", "up_percent_current_usage"]) != nil
      if hasUsage {
        usageCount += 1
      }
    }

    // Prefer variants that carry richer live telemetry first.
    return (rateBpsCount * 10_000)
      + (bitrateStringCount * 1_000)
      + (usageCount * 100)
      + (sourceCount * 10)
      + rows.count
  }

  private func fetchExpandedEeros(_ eeros: [[String: Any]]) async -> [[String: Any]] {
    var expanded: [[String: Any]] = []
    expanded.reserveCapacity(eeros.count)

    for eero in eeros {
      guard let url = DictionaryValue.string(in: eero, path: ["url"]),
        let detail = try? await call(method: .get, pathOrURL: url, json: nil, requiresAuth: true)
          as? [String: Any]
      else {
        expanded.append(eero)
        continue
      }

      var enriched = Self.deepMergeDictionary(base: eero, incoming: detail)
      let resources = DictionaryValue.stringMap(in: detail, path: ["resources"])
      if let connectionsPath = resources["connections"],
        let connections = try? await call(
          method: .get, pathOrURL: connectionsPath, json: nil, requiresAuth: true)
      {
        enriched["connections"] = connections
      }

      expanded.append(enriched)
    }

    return expanded
  }

  private func fetchProfileApplicationCatalog(
    networkID: String,
    profiles: [[String: Any]]
  ) async -> [String: Any] {
    var catalogsByProfileID: [String: Any] = [:]

    for profile in profiles {
      guard let profileID = Self.profileIdentifier(from: profile),
        let encodedProfileID = profileID.addingPercentEncoding(
          withAllowedCharacters: .urlPathAllowed)
      else {
        continue
      }

      let path = "/2.2/networks/\(networkID)/dns_policies/profiles/\(encodedProfileID)/applications"
      guard
        let payload = try? await call(method: .get, pathOrURL: path, json: nil, requiresAuth: true)
      else {
        continue
      }

      if let dict = payload as? [String: Any], !dict.isEmpty {
        catalogsByProfileID[profileID] = dict
        continue
      }

      if let rows = payload as? [[String: Any]], !rows.isEmpty {
        catalogsByProfileID[profileID] = ["applications": rows]
      }
    }

    return catalogsByProfileID
  }

  private static func deepMergeDictionary(base: [String: Any], incoming: [String: Any]) -> [String:
    Any]
  {
    var merged = base
    for (key, incomingValue) in incoming {
      // Keep richer previously-fetched values when detail endpoints return null placeholders.
      if incomingValue is NSNull {
        continue
      }

      if let incomingDict = incomingValue as? [String: Any] {
        if let existingDict = merged[key] as? [String: Any] {
          merged[key] = deepMergeDictionary(base: existingDict, incoming: incomingDict)
        } else if !incomingDict.isEmpty {
          merged[key] = incomingDict
        }
        continue
      }

      if let incomingText = incomingValue as? String {
        let trimmedIncoming = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedIncoming.isEmpty,
          let existingText = merged[key] as? String,
          !existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          continue
        }
      }

      merged[key] = incomingValue
    }
    return merged
  }

  private struct ModelFieldAuditAccumulator {
    private(set) var networkFields: [String: ModelFieldAuditCounter] = [:]
    private(set) var clientFields: [String: ModelFieldAuditCounter] = [:]
    private(set) var deviceFields: [String: ModelFieldAuditCounter] = [:]

    mutating func record(networkData: [String: Any]) {
      let clients = DictionaryValue.dictArray(in: networkData, path: ["devices", "data"])
      recordNetworkFields(networkData, clients: clients)
      recordClientFields(clients)
    }

    func summary(generatedAt: Date) -> ModelFieldAuditSummary? {
      guard !networkFields.isEmpty || !clientFields.isEmpty || !deviceFields.isEmpty else {
        return nil
      }
      return ModelFieldAuditSummary(
        generatedAt: generatedAt,
        networkFields: networkFields,
        clientFields: clientFields,
        deviceFields: deviceFields
      )
    }

    private mutating func recordNetworkFields(
      _ networkData: [String: Any], clients: [[String: Any]]
    ) {
      Self.bump(
        key: "status",
        hasValue: Self.hasAnyValue(in: networkData, paths: [["status"]]),
        counters: &networkFields
      )

      let hasGatewayIP =
        Self.hasAnyValue(in: networkData, paths: [["gateway_ip"]])
        || Self.gatewayEeroHasIP(networkData)
      Self.bump(key: "gateway_ip", hasValue: hasGatewayIP, counters: &networkFields)

      Self.bump(
        key: "updates_status",
        hasValue: Self.hasAnyValue(
          in: networkData,
          paths: [
            ["updates", "update_status"],
            ["updates", "updates_status"],
            ["updates", "state"],
            ["updates", "status"],
            ["update_status"],
            ["updates_status"],
            ["firmware_update_status"],
          ]
        ),
        counters: &networkFields
      )

      Self.bump(
        key: "channel_utilization",
        hasValue: Self.hasAnyValue(in: networkData, paths: [["channel_utilization"]]),
        counters: &networkFields
      )

      Self.bump(
        key: "proxied_nodes",
        hasValue: Self.hasAnyValue(in: networkData, paths: [["proxied_nodes"]]),
        counters: &networkFields
      )

      Self.bump(
        key: "activity_summary",
        hasValue: Self.hasAnyValue(in: networkData, paths: [["activity"]]),
        counters: &networkFields
      )

      let hasRealtimeUsage = clients.contains { client in
        let down = Self.firstPresentValue(
          in: client,
          paths: [
            ["usage", "down_mbps"],
            ["usage", "downMbps"],
            ["down_mbps"],
            ["downMbps"],
          ]
        )
        let up = Self.firstPresentValue(
          in: client,
          paths: [
            ["usage", "up_mbps"],
            ["usage", "upMbps"],
            ["up_mbps"],
            ["upMbps"],
          ]
        )
        let connected = DictionaryValue.bool(in: client, path: ["connected"]) ?? false
        return connected && (down != nil || up != nil)
      }
      Self.bump(key: "realtime_summary", hasValue: hasRealtimeUsage, counters: &networkFields)
    }

    private mutating func recordClientFields(_ clients: [[String: Any]]) {
      for client in clients {
        Self.bump(
          key: "rx_rate_mbps",
          hasValue: Self.firstPresentValue(
            in: client,
            paths: [
              ["connectivity", "rx_rate_info", "rate_mbps"],
              ["connectivity", "rx_rate_info", "mbps"],
              ["connectivity", "rx_rate_info", "rate"],
              ["connectivity", "rx_rate_info", "rate_bps"],
              ["connectivity", "rx_rate", "rate_mbps"],
              ["connectivity", "rx_rate", "mbps"],
              ["connectivity", "rx_rate", "rate"],
              ["connectivity", "rx_rate", "rate_bps"],
              ["connectivity", "rx_bitrate"],
              ["rx_rate_info", "rate_mbps"],
              ["rx_rate_info", "mbps"],
              ["rx_rate_info", "rate"],
              ["rx_rate_info", "rate_bps"],
              ["rx_rate", "rate_mbps"],
              ["rx_rate", "mbps"],
              ["rx_rate", "rate"],
              ["rx_rate", "rate_bps"],
              ["rx_bitrate"],
            ]
          ) != nil,
          counters: &clientFields
        )

        Self.bump(
          key: "tx_rate_mbps",
          hasValue: Self.firstPresentValue(
            in: client,
            paths: [
              ["connectivity", "tx_rate_info", "rate_mbps"],
              ["connectivity", "tx_rate_info", "mbps"],
              ["connectivity", "tx_rate_info", "rate"],
              ["connectivity", "tx_rate_info", "rate_bps"],
              ["connectivity", "tx_rate", "rate_mbps"],
              ["connectivity", "tx_rate", "mbps"],
              ["connectivity", "tx_rate", "rate"],
              ["connectivity", "tx_rate", "rate_bps"],
              ["connectivity", "tx_bitrate"],
              ["tx_rate_info", "rate_mbps"],
              ["tx_rate_info", "mbps"],
              ["tx_rate_info", "rate"],
              ["tx_rate_info", "rate_bps"],
              ["tx_rate", "rate_mbps"],
              ["tx_rate", "mbps"],
              ["tx_rate", "rate"],
              ["tx_rate", "rate_bps"],
              ["tx_bitrate"],
            ]
          ) != nil,
          counters: &clientFields
        )

        Self.bump(
          key: "usage_down_mbps",
          hasValue: Self.firstPresentValue(
            in: client,
            paths: [
              ["usage", "down_mbps"],
              ["usage", "downMbps"],
              ["down_mbps"],
              ["downMbps"],
            ]
          ) != nil,
          counters: &clientFields
        )

        Self.bump(
          key: "usage_up_mbps",
          hasValue: Self.firstPresentValue(
            in: client,
            paths: [
              ["usage", "up_mbps"],
              ["usage", "upMbps"],
              ["up_mbps"],
              ["upMbps"],
            ]
          ) != nil,
          counters: &clientFields
        )

        Self.bump(
          key: "usage_down_percent_current",
          hasValue: Self.firstPresentValue(
            in: client,
            paths: [
              ["usage", "down_percent_current_usage"],
              ["usage", "downPercentCurrentUsage"],
              ["down_percent_current_usage"],
              ["downPercentCurrentUsage"],
            ]
          ) != nil,
          counters: &clientFields
        )

        Self.bump(
          key: "usage_up_percent_current",
          hasValue: Self.firstPresentValue(
            in: client,
            paths: [
              ["usage", "up_percent_current_usage"],
              ["usage", "upPercentCurrentUsage"],
              ["up_percent_current_usage"],
              ["upPercentCurrentUsage"],
            ]
          ) != nil,
          counters: &clientFields
        )
      }
    }

    private static func bump(
      key: String,
      hasValue: Bool,
      counters: inout [String: ModelFieldAuditCounter]
    ) {
      var counter = counters[key] ?? ModelFieldAuditCounter(present: 0, total: 0)
      counter.total += 1
      if hasValue {
        counter.present += 1
      }
      counters[key] = counter
    }

    private static func gatewayEeroHasIP(_ networkData: [String: Any]) -> Bool {
      let eeros = DictionaryValue.dictArray(in: networkData, path: ["eeros", "data"])
      for eero in eeros {
        let isGateway = DictionaryValue.bool(in: eero, path: ["gateway"]) ?? false
        guard isGateway else { continue }
        if hasAnyValue(in: eero, paths: [["ip_address"], ["ip"]]) {
          return true
        }
      }
      return false
    }

    private static func firstPresentValue(
      in data: [String: Any],
      paths: [[String]]
    ) -> Any? {
      for path in paths {
        let value = DictionaryValue.value(in: data, path: path)
        if hasValue(value) {
          return value
        }
      }
      return nil
    }

    private static func hasAnyValue(
      in data: [String: Any],
      paths: [[String]]
    ) -> Bool {
      firstPresentValue(in: data, paths: paths) != nil
    }

    private static func hasValue(_ value: Any?) -> Bool {
      guard let value else {
        return false
      }

      if value is NSNull {
        return false
      }

      if let text = value as? String {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }

      if let array = value as? [Any] {
        return !array.isEmpty
      }

      if let dict = value as? [String: Any] {
        return !dict.isEmpty
      }

      return true
    }
  }

  private func fetchActivitySnapshot(networkURL: String, timezoneIdentifier: String) async
    -> [String: Any]?
  {
    let periods = ["day", "week", "month"]
    var networkUsage: [String: Any] = [:]
    var eeroUsage: [String: Any] = [:]
    var deviceUsage: [String: Any] = [:]

    for period in periods {
      var networkValues = await fetchDataUsageSeries(
        path: "\(networkURL)/data_usage",
        timezoneIdentifier: timezoneIdentifier,
        period: period
      )
      if networkValues == nil {
        networkValues = await fetchDataUsageSeries(
          path: "\(networkURL)/data_usage/breakdown",
          timezoneIdentifier: timezoneIdentifier,
          period: period
        )
      }
      if let values = networkValues {
        networkUsage["data_usage_\(period)"] = values
      }

      var eeroValues = await fetchDataUsageSeries(
        path: "\(networkURL)/data_usage/eeros",
        timezoneIdentifier: timezoneIdentifier,
        period: period
      )
      if eeroValues == nil {
        eeroValues = await fetchDataUsageSeries(
          path: "\(networkURL)/data_usage/eeros/summary",
          timezoneIdentifier: timezoneIdentifier,
          period: period
        )
      }
      if let values = eeroValues {
        eeroUsage["data_usage_\(period)"] = values
      }
    }

    // Pull per-device usage rollups when available; keep best-effort so the app remains usable for non-premium networks.
    if let values = await fetchDeviceUsageSnapshot(
      networkURL: networkURL, timezoneIdentifier: timezoneIdentifier, period: "day")
    {
      deviceUsage["data_usage_day"] = values
    }
    if let values = await fetchDeviceUsageSnapshot(
      networkURL: networkURL, timezoneIdentifier: timezoneIdentifier, period: "week")
    {
      deviceUsage["data_usage_week"] = values
    }
    if let values = await fetchDeviceUsageSnapshot(
      networkURL: networkURL, timezoneIdentifier: timezoneIdentifier, period: "month")
    {
      deviceUsage["data_usage_month"] = values
    }
    if let timelines = await fetchDeviceUsageTimelines(
      networkURL: networkURL,
      timezoneIdentifier: timezoneIdentifier,
      from: deviceUsage,
      limit: 5
    ), !timelines.isEmpty {
      deviceUsage["device_timelines"] = timelines
    }

    var activity: [String: Any] = [:]
    if !networkUsage.isEmpty {
      activity["network"] = networkUsage
    }
    if !eeroUsage.isEmpty {
      activity["eeros"] = eeroUsage
    }
    if !deviceUsage.isEmpty {
      activity["devices"] = deviceUsage
    }

    return activity.isEmpty ? nil : activity
  }

  private func fetchDeviceUsageTimelines(
    networkURL: String,
    timezoneIdentifier: String,
    from deviceUsage: [String: Any],
    limit: Int
  ) async -> [[String: Any]]? {
    let sourceRows = topDeviceUsageRows(from: deviceUsage, limit: limit)
    guard !sourceRows.isEmpty else {
      return nil
    }

    guard
      let queryWindow = activityQueryWindow(timezoneIdentifier: timezoneIdentifier, period: "day")
    else {
      return nil
    }

    var timelines: [[String: Any]] = []
    timelines.reserveCapacity(sourceRows.count)

    for row in sourceRows {
      guard let macAddress = row.macAddress,
        let encodedMAC = macAddress.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
      else {
        continue
      }

      let queryItems = [
        URLQueryItem(name: "start", value: queryWindow.start),
        URLQueryItem(name: "end", value: queryWindow.end),
        URLQueryItem(name: "cadence", value: "hourly"),
        URLQueryItem(name: "timezone", value: timezoneIdentifier),
      ]

      guard
        let queryPath = withQueryItems(
          pathOrURL: "\(networkURL)/data_usage/devices/\(encodedMAC)", queryItems: queryItems),
        let response = try? await call(
          method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true)
      else {
        continue
      }

      var payload: [String: Any] = [
        "resource_key": row.resourceKey,
        "mac": macAddress,
      ]
      if let displayName = row.displayName {
        payload["display_name"] = displayName
      }
      payload["payload"] = response
      timelines.append(payload)
    }

    return timelines.isEmpty ? nil : timelines
  }

  private func topDeviceUsageRows(from deviceUsage: [String: Any], limit: Int) -> [(
    resourceKey: String, macAddress: String?, displayName: String?
  )] {
    let candidateRows = [
      Self.usageRows(in: deviceUsage, path: ["data_usage_month"]),
      Self.usageRows(in: deviceUsage, path: ["data_usage_week"]),
      Self.usageRows(in: deviceUsage, path: ["data_usage_day"]),
    ]
    .flatMap { $0 }

    guard !candidateRows.isEmpty else {
      return []
    }

    var scoreByResource: [String: Int] = [:]
    var metadataByResource: [String: (macAddress: String?, displayName: String?)] = [:]

    for row in candidateRows {
      guard let resourceKey = Self.resourceKeyForUsageRow(row) else {
        continue
      }

      let usage = Self.usageTotals([row])
      let usageScore = max(0, usage.download ?? 0) + max(0, usage.upload ?? 0)
      scoreByResource[resourceKey, default: 0] += usageScore

      let macAddress =
        DictionaryValue.string(in: row, path: ["mac"])
        ?? Self.macAddressFromResourceKey(resourceKey)
      let displayName =
        DictionaryValue.string(in: row, path: ["display_name"])
        ?? DictionaryValue.string(in: row, path: ["nickname"])
        ?? DictionaryValue.string(in: row, path: ["hostname"])

      if metadataByResource[resourceKey] == nil {
        metadataByResource[resourceKey] = (macAddress: macAddress, displayName: displayName)
      } else {
        let existing = metadataByResource[resourceKey]
        metadataByResource[resourceKey] = (
          macAddress: existing?.macAddress ?? macAddress,
          displayName: existing?.displayName ?? displayName
        )
      }
    }

    return
      scoreByResource
      .sorted { lhs, rhs in
        if lhs.value != rhs.value {
          return lhs.value > rhs.value
        }
        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
      }
      .prefix(max(1, limit))
      .map { entry in
        let metadata = metadataByResource[entry.key]
        return (
          resourceKey: entry.key,
          macAddress: metadata?.macAddress,
          displayName: metadata?.displayName
        )
      }
  }

  private static func macAddressFromResourceKey(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(":") || trimmed.contains("-") {
      let normalized = trimmed.replacingOccurrences(of: "-", with: ":")
      let components = normalized.split(separator: ":")
      if components.count == 6, components.allSatisfy({ $0.count == 2 }) {
        return components.joined(separator: ":").uppercased()
      }
    }

    let alphanumerics = String(
      trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    guard alphanumerics.count == 12 else {
      return nil
    }

    var octets: [String] = []
    octets.reserveCapacity(6)
    var index = alphanumerics.startIndex
    for _ in 0..<6 {
      let next = alphanumerics.index(index, offsetBy: 2)
      octets.append(String(alphanumerics[index..<next]).uppercased())
      index = next
    }
    return octets.joined(separator: ":")
  }

  private func fetchDeviceUsageSnapshot(
    networkURL: String, timezoneIdentifier: String, period: String
  ) async -> Any? {
    guard
      let queryWindow = activityQueryWindow(timezoneIdentifier: timezoneIdentifier, period: period)
    else {
      return nil
    }

    let queryItems = [
      URLQueryItem(name: "start", value: queryWindow.start),
      URLQueryItem(name: "end", value: queryWindow.end),
      URLQueryItem(name: "cadence", value: queryWindow.cadence),
      URLQueryItem(name: "timezone", value: timezoneIdentifier),
    ]

    guard
      let queryPath = withQueryItems(
        pathOrURL: "\(networkURL)/data_usage/devices", queryItems: queryItems),
      let response = try? await call(
        method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true)
    else {
      return nil
    }

    if let dict = response as? [String: Any] {
      return dict
    }
    if let rows = response as? [[String: Any]] {
      return ["values": rows]
    }
    return nil
  }

  private func fetchChannelUtilizationSnapshot(
    networkID: String,
    networkURL: String,
    resources: [String: String],
    timezoneIdentifier: String,
    eeroDevices: [[String: Any]]
  ) async -> Any? {
    // Keep this to a short window so it stays fast and doesn't bloat UI.
    let now = Date()
    let start = now.addingTimeInterval(-6 * 3600)
    let end = now

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let basePathCandidates: [String] = [
      "/2.2/networks/\(networkID)/channel_utilization",
      resources["channel_utilization"],
      "\(networkURL)/channel_utilization",
    ].compactMap { path in
      guard let path else { return nil }
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    let canonicalBands = [
      "band_2_4GHz",
      "band_5GHz_low",
      "band_5GHz_high",
      "band_5GHz_full",
      "band_6GHz",
    ]
    var discoveredBands: Set<String> = []
    for eero in eeroDevices {
      if let bands = DictionaryValue.value(in: eero, path: ["wifi_bands"]) as? [String] {
        bands
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .forEach { discoveredBands.insert($0) }
      }
      if let bands = DictionaryValue.value(in: eero, path: ["wifiBands"]) as? [String] {
        bands
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .forEach { discoveredBands.insert($0) }
      }
    }
    let bandCandidates = (discoveredBands.isEmpty ? canonicalBands : Array(discoveredBands))
      .sorted()

    let eeroIDs: [Int] = Array(
      Set(
        eeroDevices.compactMap { eero in
          if let numericID = Self.integerValue(DictionaryValue.value(in: eero, path: ["id"])) {
            return numericID
          }
          if let stringID = DictionaryValue.string(in: eero, path: ["id"]),
            let numericID = Int(stringID)
          {
            return numericID
          }
          if let url = DictionaryValue.string(in: eero, path: ["url"]) {
            let derivedID = DictionaryValue.id(fromURL: url)
            if let numericID = Int(derivedID) {
              return numericID
            }
          }
          return nil
        }
      )
    ).sorted()

    let commonItems = [
      URLQueryItem(name: "start", value: formatter.string(from: start)),
      URLQueryItem(name: "end", value: formatter.string(from: end)),
      URLQueryItem(name: "granularity", value: "15"),
      URLQueryItem(name: "gap_data_placeholder", value: "-1"),
    ]

    var queryVariants: [[URLQueryItem]] = []
    for eeroID in eeroIDs.prefix(4) {
      for band in bandCandidates.prefix(6) {
        queryVariants.append(
          commonItems + [
            URLQueryItem(name: "eero_id", value: String(eeroID)),
            URLQueryItem(name: "band", value: band),
          ])
      }
    }
    for band in bandCandidates.prefix(6) {
      queryVariants.append(
        commonItems + [
          URLQueryItem(name: "band", value: band)
        ])
    }
    for eeroID in eeroIDs.prefix(4) {
      queryVariants.append(
        commonItems + [
          URLQueryItem(name: "eero_id", value: String(eeroID))
        ])
    }
    queryVariants.append(commonItems)
    queryVariants.append([
      URLQueryItem(name: "start", value: formatter.string(from: start)),
      URLQueryItem(name: "end", value: formatter.string(from: end)),
      URLQueryItem(name: "granularity", value: "15"),
      URLQueryItem(name: "gap_data_placeholder", value: "-1"),
      URLQueryItem(name: "timezone", value: timezoneIdentifier),
    ])
    queryVariants.append([
      URLQueryItem(name: "start", value: formatter.string(from: start)),
      URLQueryItem(name: "end", value: formatter.string(from: end)),
      URLQueryItem(name: "granularity", value: "fifteen_minutes"),
      URLQueryItem(name: "gap_data_placeholder", value: "true"),
      URLQueryItem(name: "timezone", value: timezoneIdentifier),
    ])

    for basePath in basePathCandidates {
      for queryItems in queryVariants {
        guard let queryPath = withQueryItems(pathOrURL: basePath, queryItems: queryItems),
          let response = try? await call(
            method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true),
          channelUtilizationResponseHasData(response)
        else {
          continue
        }
        return response
      }
    }

    return nil
  }

  private func channelUtilizationResponseHasData(_ response: Any) -> Bool {
    if let rows = response as? [[String: Any]] {
      return !rows.isEmpty
    }
    if let dict = response as? [String: Any] {
      if let rows = dict["utilization"] as? [[String: Any]] {
        return !rows.isEmpty
      }
      if let rows = dict["data"] as? [[String: Any]] {
        return !rows.isEmpty
      }
      if let rows = dict["values"] as? [[String: Any]] {
        return !rows.isEmpty
      }
      if let rows = dict["channels"] as? [[String: Any]] {
        return !rows.isEmpty
      }
      return !dict.isEmpty
    }
    return false
  }

  private func fetchDataUsageSeries(path: String, timezoneIdentifier: String, period: String) async
    -> [[String: Any]]?
  {
    guard
      let queryWindow = activityQueryWindow(timezoneIdentifier: timezoneIdentifier, period: period)
    else {
      return nil
    }

    let queryItems = [
      URLQueryItem(name: "start", value: queryWindow.start),
      URLQueryItem(name: "end", value: queryWindow.end),
      URLQueryItem(name: "cadence", value: queryWindow.cadence),
      URLQueryItem(name: "timezone", value: timezoneIdentifier),
    ]

    guard let queryPath = withQueryItems(pathOrURL: path, queryItems: queryItems),
      let response = try? await call(
        method: .get, pathOrURL: queryPath, json: nil, requiresAuth: true)
    else {
      return nil
    }

    if let rows = response as? [[String: Any]] {
      return rows
    }
    if let dict = response as? [String: Any] {
      if let values = dict["data"] as? [[String: Any]], !values.isEmpty {
        return values
      }
      if let dataDict = dict["data"] as? [String: Any] {
        if let values = dataDict["values"] as? [[String: Any]], !values.isEmpty {
          return values
        }
        if let series = dataDict["series"] as? [[String: Any]], !series.isEmpty {
          return series
        }
      }
      if let values = dict["values"] as? [[String: Any]] {
        return values
      }
      if let series = dict["series"] as? [[String: Any]] {
        return series
      }
      let download = DictionaryValue.value(in: dict, path: ["download"])
      let upload = DictionaryValue.value(in: dict, path: ["upload"])
      if download != nil || upload != nil {
        var row: [String: Any] = [:]
        if let download {
          row["download"] = download
        }
        if let upload {
          row["upload"] = upload
        }
        return [row]
      }
    }
    return nil
  }

  private func withQueryItems(pathOrURL: String, queryItems: [URLQueryItem]) -> String? {
    guard let resolved = try? resolveURL(pathOrURL),
      var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
    else {
      return nil
    }

    var existing = components.queryItems ?? []
    existing.append(contentsOf: queryItems)
    components.queryItems = existing
    return components.url?.absoluteString
  }

  private func activityQueryWindow(timezoneIdentifier: String, period: String) -> (
    start: String, end: String, cadence: String
  )? {
    let timezone = TimeZone(identifier: timezoneIdentifier) ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone

    let now = Date()

    let startDate: Date
    let endDate: Date
    let cadence: String

    switch period {
    case "day":
      let start = calendar.startOfDay(for: now)
      guard let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) else {
        return nil
      }
      startDate = start
      endDate = end
      cadence = "hourly"
    case "week":
      let weekday = calendar.component(.weekday, from: now)
      let daysFromSunday = weekday - 1
      let startOfToday = calendar.startOfDay(for: now)
      guard let start = calendar.date(byAdding: .day, value: -daysFromSunday, to: startOfToday),
        let end = calendar.date(byAdding: DateComponents(day: 7, second: -1), to: start)
      else {
        return nil
      }
      startDate = start
      endDate = end
      cadence = "daily"
    case "month":
      guard
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
        let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart)
      else {
        return nil
      }
      startDate = monthStart
      endDate = end
      cadence = "daily"
    default:
      return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (
      start: formatter.string(from: startDate),
      end: formatter.string(from: endDate),
      cadence: cadence
    )
  }

  func perform(_ action: EeroAction) async throws {
    let body = action.payload.isEmpty ? nil : action.payload.mapValues(\.anyValue)
    _ = try await call(
      method: action.method,
      pathOrURL: action.endpoint,
      json: body,
      requiresAuth: true
    )
  }

  private func call(
    method: HTTPMethod,
    pathOrURL: String,
    json: [String: Any]?,
    requiresAuth: Bool,
    retryOnAuthFailure: Bool = true
  ) async throws -> Any {
    let url = try resolveURL(pathOrURL)
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.httpMethod = method.rawValue

    if requiresAuth {
      guard let token = userToken, !token.isEmpty else {
        throw EeroAPIError.unauthenticated
      }
      request.addValue("s=\(token)", forHTTPHeaderField: "Cookie")
    }

    if let json {
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw EeroAPIError.invalidResponse
    }

    if (200..<300).contains(http.statusCode) {
      return try decodeDataEnvelope(data)
    }

    let message =
      (try? decodeErrorMessage(data))
      ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)

    if http.statusCode == 401,
      requiresAuth,
      retryOnAuthFailure,
      pathOrURL != "/2.2/login/refresh"
    {
      _ = try await refreshSession()
      return try await call(
        method: method,
        pathOrURL: pathOrURL,
        json: json,
        requiresAuth: requiresAuth,
        retryOnAuthFailure: false
      )
    }

    throw EeroAPIError.server(code: http.statusCode, message: message)
  }

  private func resolveURL(_ pathOrURL: String) throws -> URL {
    if let absolute = URL(string: pathOrURL), absolute.scheme != nil {
      return absolute
    }
    guard let relative = URL(string: pathOrURL, relativeTo: baseURL) else {
      throw EeroAPIError.invalidResponse
    }
    return relative
  }

  private func decodeDataEnvelope(_ data: Data) throws -> Any {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    if let dict = object as? [String: Any], let payload = dict["data"] {
      return payload
    }
    return object
  }

  private func decodeErrorMessage(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    if let dict = object as? [String: Any],
      let meta = dict["meta"] as? [String: Any]
    {
      let code = meta["code"] as? Int
      let error = meta["error"] as? String
      if let code, let error {
        return "\(error) (\(code))"
      }
      if let error {
        return error
      }
    }
    if let dict = object as? [String: Any],
      let message = dict["message"] as? String
    {
      return message
    }
    return "Unknown API error"
  }

  private static func parseNetwork(_ data: [String: Any]) -> EeroNetwork {
    let url = DictionaryValue.string(in: data, path: ["url"]) ?? ""
    let id = stableIdentifier(
      primary: DictionaryValue.id(fromURL: url),
      fallbacks: [
        url, DictionaryValue.string(in: data, path: ["name"]),
        DictionaryValue.string(in: data, path: ["nickname_label"]),
      ],
      prefix: "network"
    )
    let name = DictionaryValue.string(in: data, path: ["name"]) ?? "Network"
    let nickname = DictionaryValue.string(in: data, path: ["nickname_label"])
    let status = DictionaryValue.string(in: data, path: ["status"])
    let premiumCapable =
      DictionaryValue.bool(in: data, path: ["capabilities", "premium", "capable"]) ?? false
    let premiumStatus = DictionaryValue.string(in: data, path: ["premium_status"]) ?? ""
    let premiumEnabled = premiumCapable && ["active", "trialing"].contains(premiumStatus)
    let resources = DictionaryValue.stringMap(in: data, path: ["resources"])
    let guestNetworkData = DictionaryValue.dict(in: data, path: ["guest_network"]) ?? [:]

    let adBlockProfiles = Set(
      (DictionaryValue.value(in: data, path: ["premium_dns", "ad_block_settings", "profiles"])
        as? [String]) ?? [])

    var clients = DictionaryValue.dictArray(in: data, path: ["devices", "data"]).map(
      Self.parseClient)
    let profiles = DictionaryValue.dictArray(in: data, path: ["profiles", "data"]).map {
      parseProfile($0, adBlockProfiles: adBlockProfiles)
    }
    var devices = DictionaryValue.dictArray(in: data, path: ["eeros", "data"]).map(Self.parseDevice)

    let usageDayByDeviceID = usageByResourceID(
      in: data,
      candidatePaths: [
        ["activity", "eeros", "data_usage_day"],
        ["activity", "eeros", "data_usage_day", "values"],
      ]
    )
    let usageWeekByDeviceID = usageByResourceID(
      in: data,
      candidatePaths: [
        ["activity", "eeros", "data_usage_week"],
        ["activity", "eeros", "data_usage_week", "values"],
      ]
    )
    let usageMonthByDeviceID = usageByResourceID(
      in: data,
      candidatePaths: [
        ["activity", "eeros", "data_usage_month"],
        ["activity", "eeros", "data_usage_month", "values"],
      ]
    )

    let usageDayByClientID = usageByResourceID(
      in: data,
      candidatePaths: [
        ["activity", "devices", "data_usage_day"],
        ["activity", "devices", "data_usage_day", "values"],
      ]
    )
    let usageWeekByClientID = usageByResourceID(
      in: data,
      candidatePaths: [
        ["activity", "devices", "data_usage_week"],
        ["activity", "devices", "data_usage_week", "values"],
      ]
    )
    let usageMonthByClientID = usageByResourceID(
      in: data,
      candidatePaths: [
        ["activity", "devices", "data_usage_month"],
        ["activity", "devices", "data_usage_month", "values"],
      ]
    )

    let normalizedUsageDayByClientID = normalizeUsageLookup(usageDayByClientID)
    let normalizedUsageWeekByClientID = normalizeUsageLookup(usageWeekByClientID)
    let normalizedUsageMonthByClientID = normalizeUsageLookup(usageMonthByClientID)

    clients = clients.map { client in
      var updated = client
      if let usageDay = usageValue(
        for: client, direct: usageDayByClientID, normalized: normalizedUsageDayByClientID)
      {
        updated.usageDayDownload = usageDay.download
        updated.usageDayUpload = usageDay.upload
      }
      if let usageWeek = usageValue(
        for: client, direct: usageWeekByClientID, normalized: normalizedUsageWeekByClientID)
      {
        updated.usageWeekDownload = usageWeek.download
        updated.usageWeekUpload = usageWeek.upload
      }
      if let usageMonth = usageValue(
        for: client, direct: usageMonthByClientID, normalized: normalizedUsageMonthByClientID)
      {
        updated.usageMonthDownload = usageMonth.download
        updated.usageMonthUpload = usageMonth.upload
      }
      return updated
    }

    let connectedBySourceID = Dictionary(
      grouping: clients.compactMap { client -> (String, String)? in
        guard client.connected,
          let sourceURL = client.sourceURL,
          !sourceURL.isEmpty
        else {
          return nil
        }
        let sourceID = DictionaryValue.id(fromURL: sourceURL)
        guard !sourceID.isEmpty else {
          return nil
        }
        return (sourceID, client.name)
      }, by: \.0
    ).mapValues { rows in
      rows.map(\.1).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    let clientNameByResourceID: [String: String] = Dictionary(
      uniqueKeysWithValues: clients.compactMap { client in
        let candidates = [
          client.id,
          trimStablePrefix(client.id),
          client.sourceURL.map { DictionaryValue.id(fromURL: $0) },
          client.mac,
        ]
        for candidate in candidates {
          let normalized = normalizeKey(candidate)
          if !normalized.isEmpty {
            return (normalized, client.name)
          }
        }
        return nil
      })

    let connectedBySourceLocation = Dictionary(
      grouping: clients.compactMap { client -> (String, String)? in
        guard client.connected,
          let sourceLocation = client.sourceLocation?.trimmingCharacters(
            in: .whitespacesAndNewlines),
          !sourceLocation.isEmpty
        else {
          return nil
        }
        return (sourceLocation.lowercased(), client.name)
      }, by: \.0
    ).mapValues { rows in
      rows.map(\.1).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    devices = devices.map { device in
      var updated = device

      var inferredNames: Set<String> = []

      let sourceIDLookupKeys: [String?] = [
        device.id, trimStablePrefix(device.id), device.macAddress,
      ]
      for key in sourceIDLookupKeys {
        guard let key else { continue }
        if let names = connectedBySourceID[key], !names.isEmpty {
          inferredNames.formUnion(names)
        }
      }

      if inferredNames.isEmpty {
        let locationKey = device.name.lowercased()
        if let names = connectedBySourceLocation[locationKey], !names.isEmpty {
          inferredNames.formUnion(names)
        }
      }

      if let wirelessAttachments = updated.wirelessAttachments {
        for attachment in wirelessAttachments {
          let candidates = [
            attachment.url.map { DictionaryValue.id(fromURL: $0) },
            attachment.displayName,
          ]
          for candidate in candidates {
            let normalized = normalizeKey(candidate)
            guard !normalized.isEmpty else { continue }
            if let resolvedName = clientNameByResourceID[normalized] {
              inferredNames.insert(resolvedName)
            }
          }
        }
      }

      for status in updated.ethernetStatuses {
        let candidates = [
          status.neighborURL.map { DictionaryValue.id(fromURL: $0) }, status.neighborName,
        ]
        for candidate in candidates {
          let normalized = normalizeKey(candidate)
          guard !normalized.isEmpty else { continue }
          if let resolvedName = clientNameByResourceID[normalized] {
            inferredNames.insert(resolvedName)
          }
        }
      }

      if !inferredNames.isEmpty {
        let sorted = inferredNames.sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        updated.connectedClientNames = sorted
        if updated.connectedClientCount == nil {
          updated.connectedClientCount = sorted.count
        }
      }

      let usageLookupKeys: [String?] = [device.id, trimStablePrefix(device.id), device.macAddress]
      if let usageDay = firstUsageValue(in: usageDayByDeviceID, keys: usageLookupKeys) {
        updated.usageDayDownload = usageDay.download
        updated.usageDayUpload = usageDay.upload
      }
      if let usageWeek = firstUsageValue(in: usageWeekByDeviceID, keys: usageLookupKeys) {
        updated.usageWeekDownload = usageWeek.download
        updated.usageWeekUpload = usageWeek.upload
      }
      if let usageMonth = firstUsageValue(in: usageMonthByDeviceID, keys: usageLookupKeys) {
        updated.usageMonthDownload = usageMonth.download
        updated.usageMonthUpload = usageMonth.upload
      }

      return updated
    }

    let connectedClientsCount = clients.filter(\.connected).count
    let connectedGuestClientsCount = clients.filter { $0.connected && $0.isGuest }.count

    let blacklistedDevices = DictionaryValue.dictArray(
      in: data, path: ["device_blacklist", "data"])
    let blacklistedNames = blacklistedDevices.compactMap { entry in
      DictionaryValue.string(in: entry, path: ["nickname"])
        ?? DictionaryValue.string(in: entry, path: ["hostname"])
        ?? DictionaryValue.string(in: entry, path: ["mac"])
    }

    let routingData = DictionaryValue.dict(in: data, path: ["routing"]) ?? [:]
    let routingReservations = DictionaryValue.dictArray(
      in: routingData, path: ["reservations", "data"])
    let routingForwards = DictionaryValue.dictArray(in: routingData, path: ["forwards", "data"])
    let routingPinholes = DictionaryValue.dictArray(in: routingData, path: ["pinholes", "data"])
    let standaloneReservations = DictionaryValue.dictArray(
      in: data, path: ["reservations", "data"])
    let standaloneForwards = DictionaryValue.dictArray(in: data, path: ["forwards", "data"])
    let reservationData = routingReservations.isEmpty ? standaloneReservations : routingReservations
    let forwardData = routingForwards.isEmpty ? standaloneForwards : routingForwards

    let speedTestRecord = parseSpeedTestRecord(data["speedtest"])
    let threadDetails = parseThreadDetails(data)

    let historicalInsightsCapable =
      DictionaryValue.bool(in: data, path: ["capabilities", "historical_insights", "capable"])
      ?? false
    let perDeviceInsightsCapable =
      DictionaryValue.bool(in: data, path: ["capabilities", "per_device_insights", "capable"])
      ?? false
    let insightsAvailable =
      historicalInsightsCapable || perDeviceInsightsCapable || data["insights_response"] != nil
      || data["ouicheck_response"] != nil

    let burstSummary = parseBurstReporterSummary(data)
    let gatewayDevice = devices.first(where: \.isGateway)
    let gatewayIP =
      DictionaryValue.string(in: data, path: ["gateway_ip"]) ?? gatewayDevice?.ipAddress
    let meshQuality = average(devices.compactMap(\.meshQualityBars).map(Double.init))
    let wiredBackhaulCount = devices.filter { $0.wiredBackhaul == true }.count
    let wirelessBackhaulCount = devices.filter { $0.wiredBackhaul == false }.count
    let meshSummary: NetworkMeshSummary? =
      devices.isEmpty
      ? nil
      : NetworkMeshSummary(
        eeroCount: devices.count,
        onlineEeroCount: devices.filter { deviceStatusIsOnline($0.status) }.count,
        gatewayName: gatewayDevice?.name,
        gatewayMACAddress: gatewayDevice?.macAddress,
        gatewayIP: gatewayIP,
        averageMeshQualityBars: meshQuality,
        wiredBackhaulCount: wiredBackhaulCount,
        wirelessBackhaulCount: wirelessBackhaulCount
      )
    let channelUtilization = parseChannelUtilizationSummary(data)
    let wirelessCongestion = parseWirelessCongestion(
      clients, channelUtilization: channelUtilization)
    let activitySummary = parseNetworkActivitySummary(data, clients: clients)
    let realtimeSummary = parseRealtimeSummary(clients)
    let proxiedNodes = parseProxiedNodesSummary(data)

    return EeroNetwork(
      id: id,
      name: name,
      nickname: nickname,
      status: status,
      premiumEnabled: premiumEnabled,
      connectedClientsCount: connectedClientsCount,
      connectedGuestClientsCount: connectedGuestClientsCount,
      guestNetworkEnabled: DictionaryValue.bool(in: guestNetworkData, path: ["enabled"])
        ?? DictionaryValue.bool(in: data, path: ["guest_network", "enabled"])
        ?? false,
      guestNetworkName: DictionaryValue.string(in: guestNetworkData, path: ["name"])
        ?? DictionaryValue.string(in: data, path: ["guest_network", "name"]),
      guestNetworkPassword: DictionaryValue.string(in: guestNetworkData, path: ["password"])
        ?? DictionaryValue.string(in: data, path: ["guest_network", "password"]),
      guestNetworkDetails: GuestNetworkDetails(
        enabled: DictionaryValue.bool(in: guestNetworkData, path: ["enabled"]),
        name: DictionaryValue.string(in: guestNetworkData, path: ["name"]),
        password: DictionaryValue.string(in: guestNetworkData, path: ["password"])
      ),
      backupInternetEnabled: DictionaryValue.bool(in: data, path: ["backup_internet_enabled"]),
      resources: resources,
      features: NetworkFeatureState(
        adBlock: DictionaryValue.bool(
          in: data, path: ["premium_dns", "ad_block_settings", "enabled"]),
        blockMalware: DictionaryValue.bool(
          in: data, path: ["premium_dns", "dns_policies", "block_malware"]),
        bandSteering: DictionaryValue.bool(in: data, path: ["band_steering"]),
        upnp: DictionaryValue.bool(in: data, path: ["upnp"]),
        wpa3: DictionaryValue.bool(in: data, path: ["wpa3"]),
        threadEnabled: DictionaryValue.bool(in: data, path: ["thread", "enabled"]),
        sqm: DictionaryValue.bool(in: data, path: ["sqm"]),
        ipv6Upstream: DictionaryValue.bool(in: data, path: ["ipv6_upstream"])
      ),
      ddns: NetworkDDNSSummary(
        enabled: DictionaryValue.bool(in: data, path: ["ddns", "enabled"]),
        subdomain: DictionaryValue.string(in: data, path: ["ddns", "subdomain"])
      ),
      health: NetworkHealthSummary(
        internetStatus: DictionaryValue.string(in: data, path: ["health", "internet", "status"]),
        internetUp: DictionaryValue.bool(in: data, path: ["health", "internet", "isp_up"]),
        eeroNetworkStatus: DictionaryValue.string(
          in: data, path: ["health", "eero_network", "status"])
      ),
      diagnostics: NetworkDiagnosticsSummary(
        status: DictionaryValue.string(in: data, path: ["diagnostics", "status"])
      ),
      updates: NetworkUpdateSummary(
        hasUpdate: DictionaryValue.bool(in: data, path: ["updates", "has_update"])
          ?? DictionaryValue.bool(in: data, path: ["updates", "update_required"]),
        canUpdateNow: DictionaryValue.bool(in: data, path: ["updates", "can_update_now"]),
        targetFirmware: DictionaryValue.string(in: data, path: ["updates", "target_firmware"]),
        minRequiredFirmware: DictionaryValue.string(
          in: data, path: ["updates", "min_required_firmware"]),
        updateToFirmware: DictionaryValue.string(
          in: data, path: ["updates", "update_to_firmware"]),
        updateStatus: DictionaryValue.string(in: data, path: ["updates", "update_status"])
          ?? DictionaryValue.string(in: data, path: ["updates", "updates_status"])
          ?? DictionaryValue.string(in: data, path: ["updates", "state"])
          ?? DictionaryValue.string(in: data, path: ["updates", "status"])
          ?? DictionaryValue.string(in: data, path: ["update_status"])
          ?? DictionaryValue.string(in: data, path: ["updates_status"])
          ?? DictionaryValue.string(in: data, path: ["firmware_update_status"]),
        preferredUpdateHour: DictionaryValue.int(
          in: data, path: ["updates", "preferred_update_hour"]),
        scheduledUpdateTime: stringValue(
          DictionaryValue.value(in: data, path: ["updates", "scheduled_update_time"])),
        lastUpdateStarted: stringValue(
          DictionaryValue.value(in: data, path: ["updates", "last_update_started"]))
      ),
      speed: NetworkSpeedSummary(
        measuredDownValue: DictionaryValue.double(in: data, path: ["speed", "down", "value"])
          ?? speedTestRecord?.downMbps,
        measuredDownUnits: DictionaryValue.string(in: data, path: ["speed", "down", "units"])
          ?? "Mbps",
        measuredUpValue: DictionaryValue.double(in: data, path: ["speed", "up", "value"])
          ?? speedTestRecord?.upMbps,
        measuredUpUnits: DictionaryValue.string(in: data, path: ["speed", "up", "units"]) ?? "Mbps",
        measuredAt: stringValue(DictionaryValue.value(in: data, path: ["speed", "date"]))
          ?? speedTestRecord?.date,
        latestSpeedTest: speedTestRecord
      ),
      support: NetworkSupportSummary(
        supportPhone: DictionaryValue.string(in: data, path: ["support", "support_phone"]),
        contactURL: DictionaryValue.string(in: data, path: ["support", "contact_url"]),
        helpURL: DictionaryValue.string(in: data, path: ["support", "help_url"]),
        emailWebFormURL: DictionaryValue.string(in: data, path: ["support", "email_web_form_url"]),
        name: DictionaryValue.string(in: data, path: ["support", "name"])
      ),
      acCompatibility: parseACCompatibility(data["ac_compat"]),
      security: NetworkSecuritySummary(
        blacklistedDeviceCount: blacklistedDevices.count,
        blacklistedDeviceNames: blacklistedNames
      ),
      routing: NetworkRoutingSummary(
        reservationCount: reservationData.count,
        forwardCount: forwardData.count,
        pinholeCount: routingPinholes.count,
        reservations: reservationData.map(Self.parseReservation),
        forwards: forwardData.map(Self.parseForward)
      ),
      insights: NetworkInsightsSummary(
        available: insightsAvailable,
        lastError: nil
      ),
      threadDetails: threadDetails,
      burstReporters: burstSummary,
      gatewayIP: gatewayIP,
      mesh: meshSummary,
      wirelessCongestion: wirelessCongestion,
      activity: activitySummary,
      realtime: realtimeSummary,
      channelUtilization: channelUtilization,
      proxiedNodes: proxiedNodes,
      clients: clients,
      profiles: profiles,
      devices: devices,
      lastUpdated: Date()
    )
  }

  private static func parseClient(_ data: [String: Any]) -> EeroClient {
    let url = DictionaryValue.string(in: data, path: ["url"])
    let id = stableIdentifier(
      primary: DictionaryValue.id(
        fromURL: url ?? DictionaryValue.string(in: data, path: ["resource_url"])),
      fallbacks: [
        DictionaryValue.string(in: data, path: ["mac"]),
        DictionaryValue.string(in: data, path: ["ip"]),
        DictionaryValue.string(in: data, path: ["ipv4"]),
        DictionaryValue.string(in: data, path: ["hostname"]),
        DictionaryValue.string(in: data, path: ["nickname"]),
      ],
      prefix: "client"
    )
    let name =
      DictionaryValue.string(in: data, path: ["nickname"])
      ?? DictionaryValue.string(in: data, path: ["hostname"])
      ?? DictionaryValue.string(in: data, path: ["mac"])
      ?? "Client"
    let rxChannelWidth =
      DictionaryValue.string(in: data, path: ["connectivity", "rx_rate_info", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["connectivity", "rx_rate", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["connectivity", "rxRateInfo", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["connectivity", "rxRate", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["rx_rate_info", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["rx_rate", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["rxRateInfo", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["rxRate", "channel_width"])
    let txChannelWidth =
      DictionaryValue.string(in: data, path: ["connectivity", "tx_rate_info", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["connectivity", "tx_rate", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["connectivity", "txRateInfo", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["connectivity", "txRate", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["tx_rate_info", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["tx_rate", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["txRateInfo", "channel_width"])
      ?? DictionaryValue.string(in: data, path: ["txRate", "channel_width"])
    let sharedLinkRateMbps = firstRateMbps(
      in: data,
      pathPrefixes: [
        ["connectivity", "link_rate"],
        ["connectivity", "linkRate"],
        ["connectivity", "link_speed"],
        ["connectivity", "linkSpeed"],
        ["connectivity", "bitrate"],
        ["link_rate"],
        ["linkRate"],
        ["link_speed"],
        ["linkSpeed"],
        ["bitrate"],
      ]
    )
    let rxRateMbps =
      firstRateMbps(
        in: data,
        pathPrefixes: [
          ["connectivity", "rx_rate_mbps"],
          ["connectivity", "rxRateMbps"],
          ["connectivity", "rx_mbps"],
          ["connectivity", "rxMbps"],
          ["connectivity", "rx_rate_info"],
          ["connectivity", "rx_rate"],
          ["connectivity", "rxRateInfo"],
          ["connectivity", "rxRate"],
          ["connectivity", "rx_bitrate"],
          ["rx_rate_mbps"],
          ["rxRateMbps"],
          ["rx_mbps"],
          ["rxMbps"],
          ["rx_rate_info"],
          ["rx_rate"],
          ["rxRateInfo"],
          ["rxRate"],
          ["rx_bitrate"],
        ]
      ) ?? sharedLinkRateMbps
    let txRateMbps =
      firstRateMbps(
        in: data,
        pathPrefixes: [
          ["connectivity", "tx_rate_mbps"],
          ["connectivity", "txRateMbps"],
          ["connectivity", "tx_mbps"],
          ["connectivity", "txMbps"],
          ["connectivity", "tx_rate_info"],
          ["connectivity", "tx_rate"],
          ["connectivity", "txRateInfo"],
          ["connectivity", "txRate"],
          ["connectivity", "tx_bitrate"],
          ["tx_rate_mbps"],
          ["txRateMbps"],
          ["tx_mbps"],
          ["txMbps"],
          ["tx_rate_info"],
          ["tx_rate"],
          ["txRateInfo"],
          ["txRate"],
          ["tx_bitrate"],
        ]
      ) ?? sharedLinkRateMbps
    let usageDownMbps = firstNumericValue(
      in: data,
      paths: [
        ["usage", "down_mbps"],
        ["usage", "downMbps"],
        ["usage", "download_mbps"],
        ["usage", "downloadMbps"],
        ["usage", "downstream_mbps"],
        ["usage", "downstreamMbps"],
        ["usage", "current_download_mbps"],
        ["usage", "currentDownloadMbps"],
        ["down_mbps"],
        ["downMbps"],
        ["download_mbps"],
        ["downloadMbps"],
        ["downstream_mbps"],
        ["downstreamMbps"],
      ]
    )
    let usageUpMbps = firstNumericValue(
      in: data,
      paths: [
        ["usage", "up_mbps"],
        ["usage", "upMbps"],
        ["usage", "upload_mbps"],
        ["usage", "uploadMbps"],
        ["usage", "upstream_mbps"],
        ["usage", "upstreamMbps"],
        ["usage", "current_upload_mbps"],
        ["usage", "currentUploadMbps"],
        ["up_mbps"],
        ["upMbps"],
        ["upload_mbps"],
        ["uploadMbps"],
        ["upstream_mbps"],
        ["upstreamMbps"],
      ]
    )
    let usageDownPercentCurrent = firstIntegerValue(
      in: data,
      paths: [
        ["usage", "down_percent_current_usage"],
        ["usage", "down_percent_current"],
        ["usage", "downPercentCurrentUsage"],
        ["usage", "downPercentCurrent"],
        ["usage", "download_percent_current_usage"],
        ["usage", "downloadPercentCurrentUsage"],
        ["usage", "downstream_percent_current_usage"],
        ["usage", "downstreamPercentCurrentUsage"],
        ["usage", "down_percent_current_load"],
        ["usage", "downPercentCurrentLoad"],
        ["down_percent_current_usage"],
        ["down_percent_current"],
        ["downPercentCurrentUsage"],
        ["downPercentCurrent"],
        ["download_percent_current_usage"],
        ["downloadPercentCurrentUsage"],
        ["downstream_percent_current_usage"],
        ["downstreamPercentCurrentUsage"],
        ["down_percent_current_load"],
        ["downPercentCurrentLoad"],
      ]
    )
    let usageUpPercentCurrent = firstIntegerValue(
      in: data,
      paths: [
        ["usage", "up_percent_current_usage"],
        ["usage", "up_percent_current"],
        ["usage", "upPercentCurrentUsage"],
        ["usage", "upPercentCurrent"],
        ["usage", "upload_percent_current_usage"],
        ["usage", "uploadPercentCurrentUsage"],
        ["usage", "upstream_percent_current_usage"],
        ["usage", "upstreamPercentCurrentUsage"],
        ["usage", "up_percent_current_load"],
        ["usage", "upPercentCurrentLoad"],
        ["up_percent_current_usage"],
        ["up_percent_current"],
        ["upPercentCurrentUsage"],
        ["upPercentCurrent"],
        ["upload_percent_current_usage"],
        ["uploadPercentCurrentUsage"],
        ["upstream_percent_current_usage"],
        ["upstreamPercentCurrentUsage"],
        ["up_percent_current_load"],
        ["upPercentCurrentLoad"],
      ]
    )

    return EeroClient(
      id: id,
      name: name,
      mac: DictionaryValue.string(in: data, path: ["mac"]),
      ip: DictionaryValue.string(in: data, path: ["ip"])
        ?? DictionaryValue.string(in: data, path: ["ipv4"]),
      connected: DictionaryValue.bool(in: data, path: ["connected"]) ?? false,
      paused: DictionaryValue.bool(in: data, path: ["paused"]) ?? false,
      wireless: DictionaryValue.bool(in: data, path: ["wireless"]),
      isGuest: DictionaryValue.bool(in: data, path: ["is_guest"]) ?? false,
      connectionType: DictionaryValue.string(in: data, path: ["connection_type"]),
      signal: DictionaryValue.string(in: data, path: ["connectivity", "signal"]),
      signalAverage: DictionaryValue.string(in: data, path: ["connectivity", "signal_avg"]),
      scoreBars: DictionaryValue.int(in: data, path: ["connectivity", "score_bars"]),
      channel: DictionaryValue.int(in: data, path: ["channel"])
        ?? DictionaryValue.int(in: data, path: ["connectivity", "channel"]),
      blacklisted: DictionaryValue.bool(in: data, path: ["blacklisted"]),
      deviceType: DictionaryValue.string(in: data, path: ["device_type"])
        ?? DictionaryValue.string(in: data, path: ["manufacturer_device_type_id"]),
      manufacturer: DictionaryValue.string(in: data, path: ["manufacturer"]),
      lastActive: stringValue(DictionaryValue.value(in: data, path: ["last_active"])),
      isPrivate: DictionaryValue.bool(in: data, path: ["is_private"]),
      interfaceFrequency: stringValue(
        DictionaryValue.value(in: data, path: ["interface", "frequency"])),
      interfaceFrequencyUnit: DictionaryValue.string(
        in: data, path: ["interface", "frequency_unit"]),
      rxChannelWidth: rxChannelWidth,
      txChannelWidth: txChannelWidth,
      rxRateMbps: rxRateMbps,
      txRateMbps: txRateMbps,
      usageDownMbps: usageDownMbps,
      usageUpMbps: usageUpMbps,
      usageDownPercentCurrent: usageDownPercentCurrent,
      usageUpPercentCurrent: usageUpPercentCurrent,
      usageDayDownload: nil,
      usageDayUpload: nil,
      usageWeekDownload: nil,
      usageWeekUpload: nil,
      usageMonthDownload: nil,
      usageMonthUpload: nil,
      sourceLocation: DictionaryValue.string(in: data, path: ["source", "location"]),
      sourceURL: DictionaryValue.string(in: data, path: ["source", "url"]),
      resources: DictionaryValue.stringMap(in: data, path: ["resources"])
    )
  }

  private static func parseProfile(_ data: [String: Any], adBlockProfiles: Set<String>)
    -> EeroProfile
  {
    let url = DictionaryValue.string(in: data, path: ["url"])
    let id = stableIdentifier(
      primary: DictionaryValue.id(fromURL: url),
      fallbacks: [url, DictionaryValue.string(in: data, path: ["name"])],
      prefix: "profile"
    )
    let name = DictionaryValue.string(in: data, path: ["name"]) ?? "Profile"
    let blockedApplications = parseStringArray(
      DictionaryValue.value(in: data, path: ["premium_dns", "blocked_applications"])
        ?? DictionaryValue.value(in: data, path: ["dns_policies", "blocked_applications"])
        ?? DictionaryValue.value(in: data, path: ["blocked_applications"])
        ?? DictionaryValue.value(in: data, path: ["blocked_apps"])
        ?? DictionaryValue.value(in: data, path: ["applications", "blocked"])
    )
    let availableApplications = parseBlockedApplicationCatalog(
      DictionaryValue.value(in: data, path: ["applications_catalog"]),
      blockedApplications: blockedApplications
    )

    return EeroProfile(
      id: id,
      name: name,
      paused: DictionaryValue.bool(in: data, path: ["paused"]) ?? false,
      adBlock: url.map { adBlockProfiles.contains($0) },
      blockedApplications: blockedApplications,
      availableApplications: availableApplications.isEmpty ? nil : availableApplications,
      filters: ProfileFilterState(
        blockAdult: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_pornographic_content"]),
        blockGaming: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_gaming_content"]),
        blockMessaging: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_messaging_content"]),
        blockShopping: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_shopping_content"]),
        blockSocial: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_social_content"]),
        blockStreaming: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_streaming_content"]),
        blockViolent: DictionaryValue.bool(
          in: data, path: ["unified_content_filters", "dns_policies", "block_violent_content"])
      ),
      resources: DictionaryValue.stringMap(in: data, path: ["resources"])
    )
  }

  private static func parseBlockedApplicationCatalog(
    _ payload: Any?,
    blockedApplications: [String]
  ) -> [EeroBlockedApplication] {
    let blockedLookup = Set(
      blockedApplications
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    let blockedNormalizedLookup = Set(blockedLookup.map { normalizeKey($0) })

    var rows: [[String: Any]] = []
    if let dict = payload as? [String: Any] {
      rows = DictionaryValue.dictArray(in: dict, path: ["applications"])
      if rows.isEmpty {
        rows = DictionaryValue.dictArray(in: dict, path: ["data"])
      }
    } else if let directRows = payload as? [[String: Any]] {
      rows = directRows
    }

    var entriesByNormalizedKey: [String: EeroBlockedApplication] = [:]

    for row in rows {
      let appID =
        DictionaryValue.string(in: row, path: ["name"])
        ?? DictionaryValue.string(in: row, path: ["id"])
        ?? DictionaryValue.string(in: row, path: ["application_id"])
        ?? DictionaryValue.string(in: row, path: ["package_name"])
        ?? DictionaryValue.string(in: row, path: ["application"])
      guard let appID = appID?.trimmingCharacters(in: .whitespacesAndNewlines), !appID.isEmpty
      else {
        continue
      }

      let normalizedID = normalizeKey(appID)
      guard !normalizedID.isEmpty else {
        continue
      }

      let displayName =
        DictionaryValue.string(in: row, path: ["display_name"])
        ?? DictionaryValue.string(in: row, path: ["app_name"])
        ?? DictionaryValue.string(in: row, path: ["title"])
        ?? appID
      let categoryIDs = parseStringArray(
        DictionaryValue.value(in: row, path: ["categories"])
          ?? DictionaryValue.value(in: row, path: ["category_ids"])
      )
      let isBlocked =
        DictionaryValue.bool(in: row, path: ["is_blocked"])
        ?? blockedNormalizedLookup.contains(normalizedID)
      let iconURL =
        DictionaryValue.string(in: row, path: ["image_asset_url"])
        ?? DictionaryValue.string(in: row, path: ["icon_url"])

      entriesByNormalizedKey[normalizedID] = EeroBlockedApplication(
        id: appID,
        displayName: displayName,
        isBlocked: isBlocked,
        categoryIDs: categoryIDs,
        iconURL: iconURL
      )
    }

    for blockedApp in blockedLookup {
      let normalizedID = normalizeKey(blockedApp)
      guard !normalizedID.isEmpty else {
        continue
      }
      if entriesByNormalizedKey[normalizedID] == nil {
        entriesByNormalizedKey[normalizedID] = EeroBlockedApplication(
          id: blockedApp,
          displayName: blockedApp,
          isBlocked: true,
          categoryIDs: [],
          iconURL: nil
        )
      }
    }

    return entriesByNormalizedKey.values.sorted { lhs, rhs in
      if lhs.isBlocked != rhs.isBlocked {
        return lhs.isBlocked && !rhs.isBlocked
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  private static func parseDevice(_ data: [String: Any]) -> EeroDevice {
    let url = DictionaryValue.string(in: data, path: ["url"])
    let id = stableIdentifier(
      primary: DictionaryValue.id(fromURL: url),
      fallbacks: [
        DictionaryValue.string(in: data, path: ["mac_address"]),
        DictionaryValue.string(in: data, path: ["serial"]),
        DictionaryValue.string(in: data, path: ["ip_address"]),
        DictionaryValue.string(in: data, path: ["ip"]),
        DictionaryValue.string(in: data, path: ["location"]),
        DictionaryValue.string(in: data, path: ["nickname"]),
      ],
      prefix: "eero"
    )

    let portDetails = DictionaryValue.dictArray(in: data, path: ["port_details"])
      .map { detail in
        let position = DictionaryValue.int(in: detail, path: ["position"])
        let portName = DictionaryValue.string(in: detail, path: ["port_name"])
        let ethernetAddress = DictionaryValue.string(in: detail, path: ["ethernet_address"])
        let stableID = stableIdentifier(
          primary: "\(id)-port-\(position.map(String.init) ?? "?")",
          fallbacks: [portName, ethernetAddress],
          prefix: "port"
        )
        return EeroPortDetailSummary(
          id: stableID, position: position, portName: portName, ethernetAddress: ethernetAddress)
      }

    let legacyEthernetStatuses = DictionaryValue.dictArray(
      in: data, path: ["ethernet_status", "statuses"]
    ).map { status in
      let interfaceNumber =
        DictionaryValue.int(in: status, path: ["interfaceNumber"])
        ?? DictionaryValue.int(in: status, path: ["interface_number"])
      let portName =
        DictionaryValue.string(in: status, path: ["port_name"])
        ?? DictionaryValue.string(in: status, path: ["name"])
      let hasCarrier =
        DictionaryValue.bool(in: status, path: ["hasCarrier"])
        ?? DictionaryValue.bool(in: status, path: ["has_carrier"])
      let isWanPort =
        DictionaryValue.bool(in: status, path: ["isWanPort"])
        ?? DictionaryValue.bool(in: status, path: ["is_wan_port"])
      let speedTag = portSpeedLabel(
        negotiated: DictionaryValue.value(in: status, path: ["speed"])
          ?? DictionaryValue.value(in: status, path: ["negotiated_speed"])
          ?? DictionaryValue.value(in: status, path: ["negotiatedSpeed"]),
        supported: DictionaryValue.value(in: status, path: ["original_speed"])
          ?? DictionaryValue.value(in: status, path: ["supported_speed"])
          ?? DictionaryValue.value(in: status, path: ["supportedSpeed"]),
        fallback: DictionaryValue.value(in: status, path: ["link_speed"])
          ?? DictionaryValue.value(in: status, path: ["speed_mbps"])
      )
      let peerCount =
        firstIntValue(
          in: [status],
          paths: [
            ["peer_count"],
            ["peerCount"],
            ["num_peers"],
            ["numPeers"],
            ["peers_count"],
            ["peersCount"],
          ]
        )
        ?? firstArrayLength(
          in: [status],
          paths: [
            ["peers"],
            ["peer_urls"],
            ["peerings"],
            ["connections"],
          ]
        )
      let powerSaving =
        DictionaryValue.bool(in: status, path: ["power_saving"])
        ?? DictionaryValue.bool(in: status, path: ["powerSaving"])
      let originalSpeed =
        DictionaryValue.string(in: status, path: ["original_speed"])
        ?? DictionaryValue.string(in: status, path: ["supported_speed"])

      let neighborMeta = DictionaryValue.dict(in: status, path: ["neighbor", "metadata"]) ?? [:]
      let neighborName = DictionaryValue.string(in: neighborMeta, path: ["location"])
      let neighborURL = DictionaryValue.string(in: neighborMeta, path: ["url"])
      let neighborPortName = DictionaryValue.string(in: neighborMeta, path: ["port_name"])
      let neighborPort = DictionaryValue.int(in: neighborMeta, path: ["port"])

      let statusID = stableIdentifier(
        primary: "\(id)-if-\(interfaceNumber.map(String.init) ?? "?")",
        fallbacks: [portName, speedTag, neighborURL, neighborName],
        prefix: "eth"
      )

      return EeroEthernetPortStatus(
        id: statusID,
        interfaceNumber: interfaceNumber,
        portName: portName,
        hasCarrier: hasCarrier,
        peerCount: peerCount,
        isWanPort: isWanPort,
        speedTag: speedTag,
        powerSaving: powerSaving,
        originalSpeed: originalSpeed,
        neighborName: neighborName,
        neighborURL: neighborURL,
        neighborPortName: neighborPortName,
        neighborPort: neighborPort,
        connectionKind: nil,
        connectionType: nil
      )
    }

    let connectionEthernetStatuses =
      DictionaryValue
      .dictArray(in: data, path: ["connections", "ports", "interfaces"])
      .map { interface in
        parseConnectionEthernetStatus(interface, deviceID: id)
      }

    let ethernetStatuses = mergeEthernetStatuses(
      preferred: connectionEthernetStatuses,
      fallback: legacyEthernetStatuses
    )

    let wirelessConnectionRows = DictionaryValue.dictArray(
      in: data, path: ["connections", "wireless_devices"])
    var wirelessAttachments: [EeroWirelessAttachmentSummary] = []
    wirelessAttachments.reserveCapacity(wirelessConnectionRows.count)

    for attachment in wirelessConnectionRows {
      let metadata = DictionaryValue.dict(in: attachment, path: ["metadata"]) ?? attachment
      let displayName =
        DictionaryValue.string(in: metadata, path: ["display_name"])
        ?? DictionaryValue.string(in: metadata, path: ["location"])
      let url = DictionaryValue.string(in: metadata, path: ["url"])
      let kind =
        DictionaryValue.string(in: attachment, path: ["kind"])
        ?? DictionaryValue.string(in: attachment, path: ["type"])
        ?? DictionaryValue.string(in: metadata, path: ["kind"])
        ?? DictionaryValue.string(in: metadata, path: ["type"])
      let model =
        DictionaryValue.string(in: metadata, path: ["model"])
        ?? DictionaryValue.string(in: metadata, path: ["model_name"])
      let deviceType = DictionaryValue.string(in: metadata, path: ["device_type"])

      guard displayName != nil || url != nil || model != nil || deviceType != nil else {
        continue
      }

      let stableID = stableIdentifier(
        primary: DictionaryValue.id(fromURL: url),
        fallbacks: [displayName, url, model, deviceType],
        prefix: "wireless"
      )

      wirelessAttachments.append(
        EeroWirelessAttachmentSummary(
          id: stableID,
          displayName: displayName,
          url: url,
          kind: kind,
          model: model,
          deviceType: deviceType
        )
      )
    }

    return EeroDevice(
      id: id,
      name: DictionaryValue.string(in: data, path: ["location"])
        ?? DictionaryValue.string(in: data, path: ["nickname"])
        ?? "eero",
      model: DictionaryValue.string(in: data, path: ["model"]),
      modelNumber: DictionaryValue.string(in: data, path: ["model_number"]),
      serial: DictionaryValue.string(in: data, path: ["serial"]),
      macAddress: DictionaryValue.string(in: data, path: ["mac_address"]),
      isGateway: DictionaryValue.bool(in: data, path: ["gateway"]) ?? false,
      status: DictionaryValue.string(in: data, path: ["status"]),
      statusLightEnabled: DictionaryValue.bool(in: data, path: ["led_on"]),
      statusLightBrightness: DictionaryValue.int(in: data, path: ["led_brightness"]),
      updateAvailable: DictionaryValue.bool(in: data, path: ["update_available"]),
      ipAddress: DictionaryValue.string(in: data, path: ["ip_address"])
        ?? DictionaryValue.string(in: data, path: ["ip"]),
      osVersion: DictionaryValue.string(in: data, path: ["os_version"]),
      lastRebootAt: rebootTimestampString(from: data),
      connectedClientCount: DictionaryValue.int(in: data, path: ["connected_clients_count"]),
      connectedClientNames: nil,
      connectedWiredClientCount: DictionaryValue.int(
        in: data, path: ["connected_wired_clients_count"]),
      connectedWirelessClientCount: DictionaryValue.int(
        in: data, path: ["connected_wireless_clients_count"]),
      meshQualityBars: DictionaryValue.int(in: data, path: ["mesh_quality_bars"]),
      wiredBackhaul: DictionaryValue.bool(in: data, path: ["wired"]),
      wifiBands: (DictionaryValue.value(in: data, path: ["bands"]) as? [String]) ?? [],
      portDetails: portDetails,
      ethernetStatuses: ethernetStatuses,
      wirelessAttachments: wirelessAttachments.isEmpty ? nil : wirelessAttachments,
      usageDayDownload: nil,
      usageDayUpload: nil,
      usageWeekDownload: nil,
      usageWeekUpload: nil,
      usageMonthDownload: nil,
      usageMonthUpload: nil,
      supportExpired: DictionaryValue.bool(in: data, path: ["update_status", "support_expired"]),
      supportExpirationString: DictionaryValue.string(
        in: data, path: ["update_status", "support_expiration_string"]),
      resources: DictionaryValue.stringMap(in: data, path: ["resources"])
    )
  }

  private static func parseConnectionEthernetStatus(
    _ interface: [String: Any],
    deviceID: String
  ) -> EeroEthernetPortStatus {
    let interfaceNumber =
      DictionaryValue.int(in: interface, path: ["interface_number"])
      ?? DictionaryValue.int(in: interface, path: ["interfaceNumber"])
    let portName =
      DictionaryValue.string(in: interface, path: ["name"])
      ?? DictionaryValue.string(in: interface, path: ["port_name"])
    let networkType =
      DictionaryValue.string(in: interface, path: ["network_type"])
      ?? DictionaryValue.string(in: interface, path: ["network_type", "value"])
      ?? DictionaryValue.string(in: interface, path: ["networkType"])
    let isWanPort = networkType?.lowercased().contains("wan")
    let connectionStatus = DictionaryValue.dict(in: interface, path: ["connection_status"]) ?? [:]
    let metadata = DictionaryValue.dict(in: connectionStatus, path: ["metadata"]) ?? [:]
    let advancedAttributes =
      DictionaryValue.dict(in: metadata, path: ["advanced_attributes"]) ?? [:]
    let multiplePeerConnections = dictionaryArrayValue(
      in: [connectionStatus, metadata],
      paths: [
        ["multiple_devices", "connections"],
        ["multiple_devices", "peers"],
        ["multiple_devices", "connections_info"],
        ["multiple_devices", "device_list"],
        ["multiple_devices", "multiple_devices", "connections"],
        ["multiple_devices", "multiple_devices", "connections_info"],
        ["multiple_devices", "multiple_devices", "device_list"],
        ["connections"],
        ["peers"],
        ["peerings"],
        ["multiple_devices", "multiple_devices", "peers"],
        ["multiple_devices", "multiple_devices", "peerings"],
        ["multiple_devices", "multiple_devices", "peer_urls"],
        ["multiple_devices"],
        ["metadata", "multiple_devices", "connections"],
        ["metadata", "multiple_devices", "peers"],
        ["metadata", "multiple_devices", "connections_info"],
        ["metadata", "multiple_devices", "multiple_devices", "connections"],
        ["metadata", "multiple_devices", "multiple_devices", "peers"],
        ["metadata", "multiple_devices", "multiple_devices", "peerings"],
        ["metadata", "multiple_devices", "multiple_devices", "connections_info"],
        ["metadata", "multiple_devices", "multiple_devices", "device_list"],
        ["metadata", "multiple_devices"],
        ["metadata", "multipleDevices"],
        ["multipleDevices"],
      ]
    )
    let multiplePeerURLs = stringArrayValue(
      in: [connectionStatus, metadata],
      paths: [
        ["multiple_devices", "peer_urls"],
        ["multiple_devices", "peerUrls"],
        ["peer_urls"],
        ["peerUrls"],
        ["multiple_devices", "multiple_devices", "peer_urls"],
        ["metadata", "multiple_devices", "peer_urls"],
        ["metadata", "multiple_devices", "multiple_devices", "peer_urls"],
        ["metadata", "multiple_devices", "multiple_devices", "connections", "peer_urls"],
      ]
    )

    let connectionKind = enumLabel(
      from: firstValue(
        in: [connectionStatus, interface],
        paths: [
          ["kind"],
          ["type"],
          ["connection_type"],
          ["connectionType"],
          ["connection_kind"],
          ["connectionKind"],
        ]
      )
    )
    let connectionType = enumLabel(
      from: firstValue(
        in: [advancedAttributes, metadata, connectionStatus],
        paths: [
          ["connection_type"],
          ["connectionType"],
        ]
      )
    )
    let normalizedKind = (connectionKind ?? "").lowercased()
    let indicatesDisconnectedKind =
      normalizedKind.contains("notconnected")
      || normalizedKind.contains("not_connected")
      || normalizedKind.contains("disconnected")
      || normalizedKind.contains("unknown")
    let indicatesConnectedKind =
      normalizedKind.contains("client")
      || normalizedKind.contains("wan")
      || normalizedKind.contains("eero")
      || normalizedKind.contains("proxied")
      || normalizedKind.contains("multiple")

    let negotiatedSpeed = firstValue(
      in: [interface, connectionStatus, metadata, advancedAttributes],
      paths: [
        ["negotiated_speed"],
        ["negotiatedSpeed"],
        ["link_speed"],
        ["linkSpeed"],
        ["speed_mbps"],
      ]
    )
    let supportedSpeed = firstValue(
      in: [interface, connectionStatus, metadata, advancedAttributes],
      paths: [
        ["supported_speed"],
        ["supportedSpeed"],
        ["max_supported_speed"],
        ["maxSupportedSpeed"],
      ]
    )
    let fallbackSpeed = firstValue(
      in: [interface, metadata],
      paths: [
        ["speed"],
        ["port_speed"],
      ]
    )
    let speedTag = portSpeedLabel(
      negotiated: indicatesDisconnectedKind ? nil : negotiatedSpeed,
      supported: supportedSpeed,
      fallback: indicatesDisconnectedKind ? nil : fallbackSpeed
    )

    let neighborName = firstStringValue(
      in: [metadata, advancedAttributes],
      paths: [
        ["location"],
        ["display_name"],
        ["model_name"],
        ["name"],
      ]
    )
    let neighborURL = firstStringValue(
      in: [metadata, advancedAttributes],
      paths: [["url"]]
    )
    let neighborPortName = firstStringValue(
      in: [metadata, advancedAttributes],
      paths: [["port_name"]]
    )
    let neighborPort = firstIntValue(
      in: [metadata, advancedAttributes],
      paths: [["port"]]
    )

    let portStatus =
      DictionaryValue.string(in: interface, path: ["port_status"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    let linkStatus =
      DictionaryValue.string(in: interface, path: ["link_status"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    let hasCarrier: Bool?
    if indicatesDisconnectedKind {
      hasCarrier = false
    } else if portStatus.contains("disconnected") || portStatus.contains("down")
      || linkStatus.contains("down")
    {
      hasCarrier = false
    } else if portStatus.contains("connected") || linkStatus.contains("connected")
      || linkStatus.contains("up")
    {
      hasCarrier = true
    } else if indicatesConnectedKind {
      hasCarrier = true
    } else if normalizedKind.isEmpty {
      hasCarrier = (neighborName != nil || neighborURL != nil || connectionType != nil)
    } else {
      hasCarrier = nil
    }

    let statusID = stableIdentifier(
      primary: "\(deviceID)-if-\(interfaceNumber.map(String.init) ?? "?")",
      fallbacks: [portName, speedTag, neighborURL, neighborName],
      prefix: "eth"
    )
    let multiplePeerCount = multiplePeerStatusCount(
      from: multiplePeerConnections,
      fallback: multiplePeerURLs.isEmpty ? nil : multiplePeerURLs.count
    )
    let inferredPeerCount = inferredMultiplePeerCount(
      from: [connectionStatus, metadata, interface],
      connectionKind: connectionKind
    )
    let peerCount =
      multiplePeerCount
      ?? inferredPeerCount
      ?? firstIntValue(
        in: [interface, metadata, advancedAttributes, connectionStatus],
        paths: [
          ["peer_count"],
          ["peerCount"],
          ["num_peers"],
          ["numPeers"],
          ["peers_count"],
          ["peersCount"],
          ["peer_count_total"],
          ["peerCountTotal"],
          ["multiple_devices", "peer_count"],
          ["multiple_devices", "peerCount"],
          ["multiple_devices", "num_peers"],
          ["multiple_devices", "numPeers"],
          ["multiple_devices", "peers_count"],
          ["multiple_devices", "peersCount"],
          ["multiple_devices", "multiple_devices", "peer_count"],
          ["multiple_devices", "multiple_devices", "peerCount"],
          ["multiple_devices", "multiple_devices", "num_peers"],
          ["multiple_devices", "multiple_devices", "numPeers"],
          ["multiple_devices", "multiple_devices", "peers_count"],
          ["multiple_devices", "multiple_devices", "peersCount"],
          ["multiple_devices", "multiple_devices", "peer_urls_count"],
          ["metadata", "multiple_devices", "peer_count"],
          ["metadata", "multiple_devices", "peerCount"],
          ["metadata", "multiple_devices", "num_peers"],
          ["metadata", "multiple_devices", "numPeers"],
          ["metadata", "multiple_devices", "peers_count"],
          ["metadata", "multiple_devices", "peersCount"],
          ["multipleDevices", "peer_count"],
          ["multipleDevices", "peerCount"],
          ["multipleDevices", "numPeers"],
          ["multipleDevices", "multipleDevices", "peer_count"],
          ["multipleDevices", "multipleDevices", "peerCount"],
          ["multiple_devices", "peer_urls_count"],
        ]
      )
      ?? firstArrayLength(
        in: [interface, metadata, advancedAttributes, connectionStatus],
        paths: [
          ["peers"],
          ["peer_urls"],
          ["peerings"],
          ["connections"],
          ["multiple_devices", "peers"],
          ["multiple_devices", "peer_urls"],
          ["multiple_devices", "peerings"],
          ["multiple_devices", "connections"],
          ["multiple_devices", "connections_info"],
          ["multiple_devices", "multiple_devices", "connections"],
          ["multiple_devices", "multiple_devices", "connections_info"],
          ["multiple_devices", "multiple_devices", "peer_urls"],
          ["multiple_devices", "device_list"],
          ["metadata", "multiple_devices", "peers"],
          ["metadata", "multiple_devices", "peer_urls"],
          ["metadata", "multiple_devices", "peerings"],
          ["metadata", "multiple_devices", "multiple_devices", "peer_urls"],
          ["metadata", "multiple_devices", "multiple_devices", "connections"],
          ["metadata", "multiple_devices", "multiple_devices", "connections_info"],
          ["metadata", "multiple_devices", "multiple_devices", "device_list"],
          ["metadata", "multiple_devices", "connections"],
        ]
      )

    var resolvedPeerName = neighborName
    var resolvedPeerURL = neighborURL
    var resolvedPeerPortName = neighborPortName
    var resolvedPeerPort = neighborPort

    if peerCount == 1 {
      if let firstPeer = multiplePeerConnections.first {
        let peerMetadata = DictionaryValue.dict(in: firstPeer, path: ["metadata"]) ?? firstPeer
        let peerAdvanced =
          DictionaryValue.dict(in: peerMetadata, path: ["advanced_attributes"]) ?? [:]

        resolvedPeerName =
          firstStringValue(
            in: [peerMetadata, peerAdvanced],
            paths: [
              ["location"],
              ["display_name"],
              ["model_name"],
              ["name"],
            ]
          ) ?? resolvedPeerName
        resolvedPeerURL =
          firstStringValue(
            in: [peerMetadata, peerAdvanced],
            paths: [["url"]]
          ) ?? resolvedPeerURL
        resolvedPeerPortName =
          firstStringValue(
            in: [peerMetadata, peerAdvanced],
            paths: [["port_name"]]
          ) ?? resolvedPeerPortName
        resolvedPeerPort =
          firstIntValue(
            in: [peerMetadata, peerAdvanced],
            paths: [["port"], ["portNumber"], ["port_number"]]
          ) ?? resolvedPeerPort
      } else if let firstURL = multiplePeerURLs.first {
        resolvedPeerName = resolvedPeerName ?? firstURL
        resolvedPeerURL = resolvedPeerURL ?? firstURL
      }
    }

    return EeroEthernetPortStatus(
      id: statusID,
      interfaceNumber: interfaceNumber,
      portName: portName,
      hasCarrier: hasCarrier,
      peerCount: peerCount,
      isWanPort: isWanPort,
      speedTag: speedTag,
      powerSaving: nil,
      originalSpeed: nil,
      neighborName: resolvedPeerName,
      neighborURL: resolvedPeerURL,
      neighborPortName: resolvedPeerPortName,
      neighborPort: resolvedPeerPort,
      connectionKind: connectionKind,
      connectionType: connectionType
    )
  }

  private static func dictionaryArrayValue(
    in dictionaries: [[String: Any]],
    paths: [[String]]
  ) -> [[String: Any]] {
    for dictionary in dictionaries {
      for path in paths {
        guard let value = DictionaryValue.value(in: dictionary, path: path) else {
          continue
        }
        if let rows = value as? [[String: Any]] {
          return rows
        }
        if let values = value as? [Any] {
          let rows = values.compactMap { $0 as? [String: Any] }
          if !rows.isEmpty {
            return rows
          }
        }
        if let dict = value as? [String: Any] {
          let valueRows = dict.compactMap { candidate -> [String: Any]? in
            if let row = candidate.value as? [String: Any] {
              return row
            }
            return nil
          }
          if !valueRows.isEmpty {
            return valueRows
          }

          let stringRows = dict.compactMap { candidate -> [String: Any]? in
            guard let text = candidate.value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
              return nil
            }
            return ["url": text]
          }
          if !stringRows.isEmpty {
            return stringRows
          }
        }
        if let value = value as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return [["url": value]]
        }
      }
    }
    return []
  }

  private static func stringArrayValue(
    in dictionaries: [[String: Any]],
    paths: [[String]]
  ) -> [String] {
    for dictionary in dictionaries {
      for path in paths {
        guard let value = DictionaryValue.value(in: dictionary, path: path) else {
          continue
        }
        if let rows = value as? [String] {
          return rows
        }
        if let values = value as? [Any] {
          let rows = values.compactMap { item in
            (item as? String).map { value in
              value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
          }.filter { !$0.isEmpty }
          if !rows.isEmpty {
            return rows
          }
          return []
        }
        if let dict = value as? [String: Any] {
          let rows = dict.values.compactMap { value in
            (value as? String).map { value in
              value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
          }.filter { !$0.isEmpty }
          if !rows.isEmpty {
            return rows
          }
        }
        if let value = value as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return [value.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
      }
    }
    return []
  }

  private static func multiplePeerStatusCount(from statuses: [[String: Any]], fallback: Int?)
    -> Int?
  {
    if !statuses.isEmpty {
      return statuses.count
    }
    return fallback
  }

  private static func inferredMultiplePeerCount(
    from dictionaries: [[String: Any]],
    connectionKind: String?
  ) -> Int? {
    guard (connectionKind ?? "").lowercased().contains("multiple") else {
      return nil
    }

    var inferred: Int?
    for dictionary in dictionaries {
      if let count = inferredMultiplePeerCount(in: dictionary, depth: 0) {
        inferred = max(inferred ?? count, count)
      }
    }
    return inferred
  }

  private static func inferredMultiplePeerCount(
    in value: Any,
    depth: Int
  ) -> Int? {
    guard depth < 5 else {
      return nil
    }
    if let directCount = arrayValueCount(value, for: "") {
      return directCount
    }
    guard let dictionary = value as? [String: Any] else {
      return nil
    }

    var inferred: Int?
    for (key, candidate) in dictionary {
      let normalized = key.lowercased()
      if normalized.contains("metadata") || normalized.contains("advanced") {
        if let count = inferredMultiplePeerCount(in: candidate, depth: depth + 1) {
          inferred = max(inferred ?? count, count)
        }
        continue
      }
      guard
        normalized.contains("peer")
          || normalized.contains("device")
          || normalized.contains("connection")
          || normalized.contains("multiple")
      else {
        continue
      }
      if let count = arrayValueCount(candidate, for: normalized)
        ?? inferredMultiplePeerCount(in: candidate, depth: depth + 1)
      {
        inferred = max(inferred ?? count, count)
      }
    }
    return inferred
  }

  private static func arrayValueCount(_ value: Any, for keyHint: String) -> Int? {
    if let rows = value as? [[String: Any]] {
      return rows.count
    }
    if let rows = value as? [Any] {
      return rows.count
    }
    if let dict = value as? [String: Any] {
      if keyHint.contains("urls") || keyHint.contains("list") {
        return dict.count
      }
      let stringValues = dict.values.compactMap { $0 as? String }.filter { !$0.isEmpty }.count
      let dictValues = dict.values.compactMap { $0 as? [String: Any] }.count
      let urlMaps = dict.values.compactMap { $0 as? [Any] }.count
      if stringValues > 0 {
        return stringValues
      }
      if dictValues > 0 {
        return max(dictValues, dict.count)
      }
      if urlMaps > 0 {
        return urlMaps
      }
      let entries = dict.values.compactMap { candidate -> Int? in
        switch candidate {
        case let rows as [[String: Any]]:
          return rows.isEmpty ? nil : rows.count
        case let rows as [Any]:
          return rows.isEmpty ? nil : rows.count
        case let candidate as [String: Any]:
          return candidate.isEmpty ? nil : 1
        case is String:
          return 1
        default:
          return nil
        }
      }
      return entries.isEmpty ? nil : entries.count
    }
    return nil
  }

  private static func firstValue(in dictionaries: [[String: Any]], paths: [[String]]) -> Any? {
    for dictionary in dictionaries {
      for path in paths {
        if let value = DictionaryValue.value(in: dictionary, path: path) {
          return value
        }
      }
    }
    return nil
  }

  private static func firstStringValue(in dictionaries: [[String: Any]], paths: [[String]])
    -> String?
  {
    for dictionary in dictionaries {
      for path in paths {
        if let value = DictionaryValue.string(in: dictionary, path: path),
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return value
        }
      }
    }
    return nil
  }

  private static func firstIntValue(in dictionaries: [[String: Any]], paths: [[String]]) -> Int? {
    for dictionary in dictionaries {
      for path in paths {
        if let value = DictionaryValue.int(in: dictionary, path: path) {
          return value
        }
      }
    }
    return nil
  }

  private static func firstArrayLength(
    in dictionaries: [[String: Any]],
    paths: [[String]]
  ) -> Int? {
    for dictionary in dictionaries {
      for path in paths {
        if let value = DictionaryValue.value(in: dictionary, path: path) {
          if let dictArray = value as? [[String: Any]] {
            return dictArray.count
          }
          if let genericArray = value as? [Any] {
            return genericArray.count
          }
          if let dict = value as? [String: Any] {
            return dict.count
          }
        }
      }
    }
    return nil
  }

  private static func firstNumericValue(in data: [String: Any], paths: [[String]]) -> Double? {
    for path in paths {
      if let value = numericValue(DictionaryValue.value(in: data, path: path)) {
        return value
      }
    }
    return nil
  }

  private static func firstIntegerValue(in data: [String: Any], paths: [[String]]) -> Int? {
    for path in paths {
      if let value = integerValue(DictionaryValue.value(in: data, path: path)) {
        return value
      }
    }
    return nil
  }

  private static func rebootTimestampString(from data: [String: Any]) -> String? {
    let candidates: [Any?] = [
      DictionaryValue.value(in: data, path: ["last_reboot"]),
      DictionaryValue.value(in: data, path: ["last_reboot_at"]),
      DictionaryValue.value(in: data, path: ["last_boot"]),
      DictionaryValue.value(in: data, path: ["last_boot_at"]),
      DictionaryValue.value(in: data, path: ["last_reboot_timestamp"]),
      DictionaryValue.value(in: data, path: ["last_heartbeat"]),
      DictionaryValue.value(in: data, path: ["lastHeartbeat"]),
      DictionaryValue.value(in: data, path: ["joined"]),
      DictionaryValue.value(in: data, path: ["metadata", "last_reboot"]),
      DictionaryValue.value(in: data, path: ["metadata", "last_reboot_at"]),
      DictionaryValue.value(in: data, path: ["metadata", "last_heartbeat"]),
      DictionaryValue.value(in: data, path: ["status", "last_reboot"]),
      DictionaryValue.value(in: data, path: ["status", "last_reboot_at"]),
      DictionaryValue.value(in: data, path: ["status", "last_boot"]),
      DictionaryValue.value(in: data, path: ["status", "last_boot_at"]),
      DictionaryValue.value(in: data, path: ["status", "last_reboot_timestamp"]),
      DictionaryValue.value(in: data, path: ["status", "last_heartbeat"]),
      DictionaryValue.value(in: data, path: ["status", "lastHeartbeat"]),
      DictionaryValue.value(in: data, path: ["update_status", "last_reboot"]),
      DictionaryValue.value(in: data, path: ["update_status", "last_heartbeat"]),
      DictionaryValue.value(in: data, path: ["diagnostics", "last_reboot"]),
      DictionaryValue.value(in: data, path: ["diagnostics", "last_heartbeat"]),
    ]

    for candidate in candidates {
      guard let candidate else { continue }
      if let date = dateValue(candidate) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
      }
      if let text = stringValue(candidate)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      {
        return text
      }
    }

    return nil
  }

  private static func mergeEthernetStatuses(
    preferred: [EeroEthernetPortStatus],
    fallback: [EeroEthernetPortStatus]
  ) -> [EeroEthernetPortStatus] {
    guard !preferred.isEmpty else {
      return fallback
    }
    guard !fallback.isEmpty else {
      return preferred
    }

    func lookupKeys(for status: EeroEthernetPortStatus) -> [String] {
      var keys: [String] = []
      if let interfaceNumber = status.interfaceNumber {
        keys.append("if:\(interfaceNumber)")
      }
      if let portName = status.portName {
        let normalized = normalizeKey(portName)
        if !normalized.isEmpty {
          keys.append("port:\(normalized)")
        }
      }
      return keys
    }

    var fallbackByKey: [String: EeroEthernetPortStatus] = [:]
    for status in fallback {
      for key in lookupKeys(for: status) where fallbackByKey[key] == nil {
        fallbackByKey[key] = status
      }
    }

    var consumedKeys: Set<String> = []
    var merged: [EeroEthernetPortStatus] = []
    merged.reserveCapacity(max(preferred.count, fallback.count))

    for status in preferred {
      var enriched = status
      let keys = lookupKeys(for: status)
      let fallbackMatch = keys.compactMap { fallbackByKey[$0] }.first
      if let fallbackMatch {
        if enriched.speedTag == nil {
          enriched.speedTag = fallbackMatch.speedTag
        }
        if enriched.peerCount == nil {
          enriched.peerCount = fallbackMatch.peerCount
        }
        if enriched.originalSpeed == nil {
          enriched.originalSpeed = fallbackMatch.originalSpeed
        }
        if enriched.powerSaving == nil {
          enriched.powerSaving = fallbackMatch.powerSaving
        }
        if enriched.isWanPort == nil {
          enriched.isWanPort = fallbackMatch.isWanPort
        }
        if enriched.hasCarrier == nil {
          enriched.hasCarrier = fallbackMatch.hasCarrier
        }
        if enriched.neighborName == nil {
          enriched.neighborName = fallbackMatch.neighborName
        }
        if enriched.neighborURL == nil {
          enriched.neighborURL = fallbackMatch.neighborURL
        }
        if enriched.neighborPortName == nil {
          enriched.neighborPortName = fallbackMatch.neighborPortName
        }
        if enriched.neighborPort == nil {
          enriched.neighborPort = fallbackMatch.neighborPort
        }
      }
      consumedKeys.formUnion(keys)
      merged.append(enriched)
    }

    for status in fallback {
      let keys = lookupKeys(for: status)
      if keys.contains(where: consumedKeys.contains) {
        continue
      }
      merged.append(status)
    }

    return merged
  }

  private static func portSpeedLabel(
    negotiated: Any?,
    supported: Any?,
    fallback: Any?
  ) -> String? {
    let negotiatedLabel = portSpeedValue(negotiated)
    let supportedLabel = portSpeedValue(supported)
    let fallbackLabel = portSpeedValue(fallback)

    if let negotiatedLabel, let supportedLabel, negotiatedLabel != supportedLabel {
      return "\(negotiatedLabel) (max \(supportedLabel))"
    }
    if let negotiatedLabel {
      return negotiatedLabel
    }
    if let supportedLabel {
      return "max \(supportedLabel)"
    }
    return fallbackLabel
  }

  private static func portSpeedValue(_ value: Any?) -> String? {
    guard let value else {
      return nil
    }

    if let dict = value as? [String: Any] {
      if let directLabel = stringValue(dict["tag"])
        ?? stringValue(dict["name"])
        ?? stringValue(dict["label"])
        ?? stringValue(dict["display"])
        ?? stringValue(dict["value"])
      {
        return normalizedPortSpeedText(directLabel)
      }
      if let nestedValue = dict["value"],
        let nestedLabel = portSpeedValue(nestedValue)
      {
        return nestedLabel
      }
      if let nestedRate = dict["rate"],
        let nestedLabel = portSpeedValue(nestedRate)
      {
        return nestedLabel
      }
      if let nestedRate = dict["rate_info"],
        let nestedLabel = portSpeedValue(nestedRate)
      {
        return nestedLabel
      }
      if let nestedRate = dict["rateInfo"],
        let nestedLabel = portSpeedValue(nestedRate)
      {
        return nestedLabel
      }
      if let rate = integerValue(dict["rate"]) {
        return normalizedPortSpeedText(String(rate))
      }
      if let rateMbps = numericValue(dict["rate_mbps"])
        ?? numericValue(dict["rateMbps"])
        ?? numericValue(dict["mbps"])
      {
        return normalizedPortSpeedText(String(rateMbps))
      }
      if let rateBps = numericValue(dict["rate_bps"])
        ?? numericValue(dict["rateBps"])
        ?? numericValue(dict["bps"])
      {
        return normalizedPortSpeedText(String(rateBps))
      }
    }

    if let text = stringValue(value) {
      return normalizedPortSpeedText(text)
    }

    if let number = integerValue(value) {
      if let enumLabel = phyRateLabel(forEnumValue: number) {
        return enumLabel
      }
      return normalizedPortSpeedText(String(number))
    }

    return nil
  }

  private static func normalizedPortSpeedText(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let uppercased = trimmed.uppercased()
    if let phyRate = phyRateLabel(forToken: uppercased) {
      return phyRate
    }

    let compactNumeric = trimmed.replacingOccurrences(of: "_", with: "")
    if !compactNumeric.contains("."),
      let enumValue = Int(compactNumeric),
      let enumLabel = phyRateLabel(forEnumValue: enumValue)
    {
      return enumLabel
    }

    if let numeric = Double(compactNumeric) {
      if numeric > 100_000_000 {
        return formattedBitRate(numeric)
      }
      if numeric >= 1_000 {
        return String(format: "%.1f Gbps", numeric / 1_000)
      }
      if numeric >= 10 {
        return String(format: "%.0f Mbps", numeric)
      }
    }

    return trimmed
  }

  private static func phyRateLabel(forToken token: String) -> String? {
    switch token {
    case "P10":
      return "10 Mbps"
    case "P100":
      return "100 Mbps"
    case "P1000":
      return "1 Gbps"
    case "P2500":
      return "2.5 Gbps"
    case "P5000":
      return "5 Gbps"
    case "P10000":
      return "10 Gbps"
    default:
      return nil
    }
  }

  private static func phyRateLabel(forEnumValue value: Int) -> String? {
    switch value {
    case 0:
      return "10 Mbps"
    case 1:
      return "100 Mbps"
    case 2:
      return "1 Gbps"
    case 3:
      return "2.5 Gbps"
    case 4:
      return "5 Gbps"
    case 5:
      return "10 Gbps"
    default:
      return nil
    }
  }

  private static func parseReservation(_ data: [String: Any]) -> NetworkReservation {
    let url = DictionaryValue.string(in: data, path: ["url"])
    return NetworkReservation(
      id: stableIdentifier(
        primary: DictionaryValue.id(fromURL: url),
        fallbacks: [
          url, DictionaryValue.string(in: data, path: ["ip"]),
          DictionaryValue.string(in: data, path: ["mac"]),
        ],
        prefix: "reservation"
      ),
      description: DictionaryValue.string(in: data, path: ["description"]),
      ip: DictionaryValue.string(in: data, path: ["ip"]),
      mac: DictionaryValue.string(in: data, path: ["mac"])
    )
  }

  private static func parseForward(_ data: [String: Any]) -> NetworkPortForward {
    let url = DictionaryValue.string(in: data, path: ["url"])
    return NetworkPortForward(
      id: stableIdentifier(
        primary: DictionaryValue.id(fromURL: url),
        fallbacks: [
          url,
          DictionaryValue.string(in: data, path: ["ip"]),
          DictionaryValue.string(in: data, path: ["description"]),
          DictionaryValue.string(in: data, path: ["protocol"]),
        ],
        prefix: "forward"
      ),
      description: DictionaryValue.string(in: data, path: ["description"]),
      ip: DictionaryValue.string(in: data, path: ["ip"]),
      gatewayPort: DictionaryValue.int(in: data, path: ["gateway_port"]),
      clientPort: DictionaryValue.int(in: data, path: ["client_port"]),
      protocolName: DictionaryValue.string(in: data, path: ["protocol"]),
      enabled: DictionaryValue.bool(in: data, path: ["enabled"])
    )
  }

  private static func parseACCompatibility(_ value: Any?) -> NetworkACCompatibilitySummary {
    if let dict = value as? [String: Any] {
      return NetworkACCompatibilitySummary(
        enabled: DictionaryValue.bool(in: dict, path: ["enabled"])
          ?? DictionaryValue.bool(in: dict, path: ["value"]),
        state: DictionaryValue.string(in: dict, path: ["state"])
      )
    }
    if let boolValue = value as? Bool {
      return NetworkACCompatibilitySummary(enabled: boolValue, state: nil)
    }
    if let number = value as? NSNumber {
      return NetworkACCompatibilitySummary(enabled: number.boolValue, state: nil)
    }
    return NetworkACCompatibilitySummary(enabled: nil, state: nil)
  }

  private static func parseSpeedTestRecord(_ value: Any?) -> SpeedTestRecord? {
    if let rows = value as? [[String: Any]], let first = rows.first {
      return SpeedTestRecord(
        upMbps: DictionaryValue.double(in: first, path: ["up_mbps"]),
        downMbps: DictionaryValue.double(in: first, path: ["down_mbps"]),
        date: stringValue(DictionaryValue.value(in: first, path: ["date"]))
      )
    }

    if let dict = value as? [String: Any] {
      let upMbps =
        DictionaryValue.double(in: dict, path: ["up_mbps"])
        ?? DictionaryValue.double(in: dict, path: ["up", "value"])
      let downMbps =
        DictionaryValue.double(in: dict, path: ["down_mbps"])
        ?? DictionaryValue.double(in: dict, path: ["down", "value"])
      let date = stringValue(DictionaryValue.value(in: dict, path: ["date"]))
      if upMbps != nil || downMbps != nil || date != nil {
        return SpeedTestRecord(upMbps: upMbps, downMbps: downMbps, date: date)
      }
    }

    return nil
  }

  private static func parseThreadDetails(_ data: [String: Any]) -> ThreadNetworkDetails? {
    let threadData = DictionaryValue.dict(in: data, path: ["thread"]) ?? [:]
    let details = ThreadNetworkDetails(
      name: DictionaryValue.string(in: threadData, path: ["name"]),
      channel: DictionaryValue.int(in: threadData, path: ["channel"]),
      panID: DictionaryValue.string(in: threadData, path: ["pan_id"]),
      xpanID: DictionaryValue.string(in: threadData, path: ["xpan_id"]),
      commissioningCredential: DictionaryValue.string(
        in: threadData, path: ["commissioning_credential"]),
      activeOperationalDataset: DictionaryValue.string(
        in: threadData, path: ["active_operational_dataset"])
    )

    if details.name == nil,
      details.channel == nil,
      details.panID == nil,
      details.xpanID == nil,
      details.commissioningCredential == nil,
      details.activeOperationalDataset == nil
    {
      return nil
    }
    return details
  }

  private static func parseBurstReporterSummary(_ data: [String: Any]) -> BurstReporterSummary? {
    guard let burstData = DictionaryValue.dict(in: data, path: ["burst_reporters"]) else {
      return nil
    }
    return BurstReporterSummary(status: DictionaryValue.string(in: burstData, path: ["status"]))
  }

  private static func usageByResourceID(in data: [String: Any], path: [String]) -> [String: (
    download: Int?, upload: Int?
  )] {
    let rows = usageRows(in: data, path: path)
    var summary: [String: (download: Int?, upload: Int?)] = [:]

    for row in rows {
      guard let resourceID = resourceKeyForUsageRow(row) else {
        continue
      }

      var aggregate = summary[resourceID] ?? (download: nil, upload: nil)
      accumulateUsage(in: &aggregate, row: row)
      summary[resourceID] = aggregate
    }

    return summary.filter { $0.value.download != nil || $0.value.upload != nil }
  }

  private static func usageByResourceID(
    in data: [String: Any],
    candidatePaths: [[String]]
  ) -> [String: (download: Int?, upload: Int?)] {
    for path in candidatePaths {
      let values = usageByResourceID(in: data, path: path)
      if !values.isEmpty {
        return values
      }
    }
    return [:]
  }

  private static func usageRows(in data: [String: Any], path: [String]) -> [[String: Any]] {
    let directRows = DictionaryValue.dictArray(in: data, path: path)
    if !directRows.isEmpty {
      return directRows
    }
    if let dict = DictionaryValue.dict(in: data, path: path),
      let values = dict["data"] as? [[String: Any]],
      !values.isEmpty
    {
      return values
    }
    if let dict = DictionaryValue.dict(in: data, path: path),
      let values = dict["values"] as? [[String: Any]]
    {
      return values
    }
    if let dict = DictionaryValue.dict(in: data, path: path),
      let series = dict["series"] as? [[String: Any]],
      !series.isEmpty
    {
      return series
    }
    if let dict = DictionaryValue.dict(in: data, path: path) {
      let hasDirectTotals =
        integerValue(dict["download"]) != nil
        || integerValue(dict["upload"]) != nil
        || integerValue(dict["down"]) != nil
        || integerValue(dict["up"]) != nil
        || integerValue(dict["downstream"]) != nil
        || integerValue(dict["upstream"]) != nil
        || integerValue(dict["rx"]) != nil
        || integerValue(dict["tx"]) != nil
      if hasDirectTotals {
        return [dict]
      }
    }
    return []
  }

  private enum UsageDirection {
    case download
    case upload
  }

  private static func usageByteValue(in row: [String: Any], direction: UsageDirection) -> Int? {
    let candidatePaths: [[String]]
    switch direction {
    case .download:
      candidatePaths = [
        ["download"],
        ["down"],
        ["downstream"],
        ["rx"],
        ["download_bytes"],
        ["down_bytes"],
        ["downstream_bytes"],
        ["rx_bytes"],
        ["download", "value"],
        ["down", "value"],
        ["downstream", "value"],
        ["rx", "value"],
        ["totals", "download"],
        ["totals", "down"],
        ["totals", "downstream"],
        ["totals", "rx"],
        ["stats", "download"],
        ["stats", "down"],
        ["stats", "downstream"],
        ["stats", "rx"],
        ["data", "download"],
        ["data", "down"],
        ["data", "downstream"],
        ["data", "rx"],
        ["usage", "download"],
        ["usage", "down"],
        ["usage", "downstream"],
        ["usage", "rx"],
      ]
    case .upload:
      candidatePaths = [
        ["upload"],
        ["up"],
        ["upstream"],
        ["tx"],
        ["upload_bytes"],
        ["up_bytes"],
        ["upstream_bytes"],
        ["tx_bytes"],
        ["upload", "value"],
        ["up", "value"],
        ["upstream", "value"],
        ["tx", "value"],
        ["totals", "upload"],
        ["totals", "up"],
        ["totals", "upstream"],
        ["totals", "tx"],
        ["stats", "upload"],
        ["stats", "up"],
        ["stats", "upstream"],
        ["stats", "tx"],
        ["data", "upload"],
        ["data", "up"],
        ["data", "upstream"],
        ["data", "tx"],
        ["usage", "upload"],
        ["usage", "up"],
        ["usage", "upstream"],
        ["usage", "tx"],
      ]
    }

    for path in candidatePaths {
      if let value = integerValue(DictionaryValue.value(in: row, path: path)) {
        return value
      }
    }
    return nil
  }

  private static func usageDirection(for row: [String: Any]) -> UsageDirection? {
    let rawType =
      DictionaryValue.string(in: row, path: ["type"])
      ?? DictionaryValue.string(in: row, path: ["data_usage_type"])
      ?? DictionaryValue.string(in: row, path: ["direction"])
      ?? DictionaryValue.string(in: row, path: ["metric"])
      ?? DictionaryValue.string(in: row, path: ["insight_type_name"])
    return usageDirection(fromRawType: rawType)
  }

  private static func usageDirection(fromRawType rawType: String?) -> UsageDirection? {
    guard let rawType = rawType?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawType.isEmpty
    else {
      return nil
    }

    let normalized = rawType.lowercased()
    if normalized.contains("download")
      || normalized.contains("downstream")
      || normalized.contains("receive")
      || normalized.contains("ingress")
      || normalized == "down"
      || normalized == "rx"
    {
      return .download
    }
    if normalized.contains("upload")
      || normalized.contains("upstream")
      || normalized.contains("transmit")
      || normalized.contains("egress")
      || normalized == "up"
      || normalized == "tx"
    {
      return .upload
    }
    return nil
  }

  private static func usageSeriesTotal(in row: [String: Any], direction: UsageDirection?) -> Int? {
    if let sum = integerValue(
      DictionaryValue.value(in: row, path: ["sum"])
        ?? DictionaryValue.value(in: row, path: ["total"])
        ?? DictionaryValue.value(in: row, path: ["total_bytes"])
    ) {
      return max(0, sum)
    }

    let seriesRows = DictionaryValue.dictArray(in: row, path: ["values"])
    if !seriesRows.isEmpty {
      var total = 0
      var sawValue = false
      for sample in seriesRows {
        if let direction,
          let directional = usageByteValue(in: sample, direction: direction)
        {
          total += max(0, directional)
          sawValue = true
          continue
        }
        if let value = integerValue(DictionaryValue.value(in: sample, path: ["value"])) {
          total += max(0, value)
          sawValue = true
        }
      }
      if sawValue {
        return total
      }
    }

    if let direction,
      let direct = usageByteValue(in: row, direction: direction)
    {
      return max(0, direct)
    }

    if let value = integerValue(
      DictionaryValue.value(in: row, path: ["value"])
        ?? DictionaryValue.value(in: row, path: ["bytes"])
    ) {
      return max(0, value)
    }

    return nil
  }

  private static func accumulateUsage(
    in aggregate: inout (download: Int?, upload: Int?),
    row: [String: Any]
  ) {
    if let direction = usageDirection(for: row),
      let total = usageSeriesTotal(in: row, direction: direction)
    {
      switch direction {
      case .download:
        aggregate.download = (aggregate.download ?? 0) + max(0, total)
      case .upload:
        aggregate.upload = (aggregate.upload ?? 0) + max(0, total)
      }
      return
    }

    if let down = usageByteValue(in: row, direction: .download) {
      aggregate.download = (aggregate.download ?? 0) + max(0, down)
    }
    if let up = usageByteValue(in: row, direction: .upload) {
      aggregate.upload = (aggregate.upload ?? 0) + max(0, up)
    }
  }

  private static func resourceKeyForUsageRow(_ row: [String: Any]) -> String? {
    let urlPaths: [[String]] = [
      ["url"],
      ["source", "url"],
      ["device", "url"],
      ["resource", "url"],
    ]
    for path in urlPaths {
      if let url = DictionaryValue.string(in: row, path: path) {
        let id = DictionaryValue.id(fromURL: url)
        if !id.isEmpty {
          return id
        }
      }
    }

    let macPaths: [[String]] = [
      ["mac"],
      ["device", "mac"],
      ["source", "mac"],
    ]
    for path in macPaths {
      if let mac = DictionaryValue.string(in: row, path: path),
        !mac.isEmpty,
        !isPlaceholderMACAddress(mac)
      {
        return mac
      }
    }

    let idPaths: [[String]] = [
      ["resource_key"],
      ["resource_id"],
      ["resource", "id"],
      ["source", "id"],
      ["source", "resource_id"],
      ["device", "id"],
      ["device", "resource_id"],
      ["id"],
    ]
    for path in idPaths {
      guard let identifier = DictionaryValue.string(in: row, path: path),
        !identifier.isEmpty
      else {
        continue
      }
      let urlID = DictionaryValue.id(fromURL: identifier)
      if !urlID.isEmpty {
        return urlID
      }
      return identifier
    }

    return nil
  }

  private static func isPlaceholderMACAddress(_ value: String) -> Bool {
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

  private static func profileIdentifier(from profile: [String: Any]) -> String? {
    if let identifier = DictionaryValue.string(in: profile, path: ["id"])?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !identifier.isEmpty
    {
      return identifier
    }
    if let url = DictionaryValue.string(in: profile, path: ["url"]) {
      let id = DictionaryValue.id(fromURL: url)
      if !id.isEmpty {
        return id
      }
    }
    return nil
  }

  private static func usageByKey(
    _ key: String, from usage: [String: (download: Int?, upload: Int?)]
  ) -> (download: Int?, upload: Int?)? {
    if let direct = usage[key] {
      return direct
    }
    let normalized = normalizeKey(key)
    guard !normalized.isEmpty else {
      return nil
    }
    return usage.first(where: { normalizeKey($0.key) == normalized })?.value
  }

  private static func firstUsageValue(
    in usage: [String: (download: Int?, upload: Int?)],
    keys: [String?]
  ) -> (download: Int?, upload: Int?)? {
    for key in keys {
      guard let key, !key.isEmpty else { continue }
      if let value = usageByKey(key, from: usage) {
        return value
      }
    }
    return nil
  }

  private static func normalizeUsageLookup(
    _ usage: [String: (download: Int?, upload: Int?)]
  ) -> [String: (download: Int?, upload: Int?)] {
    var normalized: [String: (download: Int?, upload: Int?)] = [:]
    for (key, value) in usage {
      let normalizedKey = normalizeKey(key)
      guard !normalizedKey.isEmpty else { continue }
      normalized[normalizedKey] = value
    }
    return normalized
  }

  private static func usageValue(
    for client: EeroClient,
    direct: [String: (download: Int?, upload: Int?)],
    normalized: [String: (download: Int?, upload: Int?)]
  ) -> (download: Int?, upload: Int?)? {
    if let value = usageByKey(client.id, from: direct) {
      return value
    }

    if let mac = client.mac,
      let value = normalized[normalizeKey(mac)]
    {
      return value
    }

    if let sourceURL = client.sourceURL,
      let value = normalized[normalizeKey(DictionaryValue.id(fromURL: sourceURL))]
    {
      return value
    }

    return nil
  }

  private static func normalizeKey(_ value: String?) -> String {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return ""
    }

    let lowered = value.lowercased()
    let scalarSet = CharacterSet.alphanumerics
    let compact = String(lowered.unicodeScalars.filter { scalarSet.contains($0) })
    if !compact.isEmpty {
      return compact
    }
    return lowered
  }

  private static func trimStablePrefix(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }

    guard let separator = value.firstIndex(of: "-"),
      separator != value.startIndex
    else {
      return value
    }

    let suffixStart = value.index(after: separator)
    guard suffixStart < value.endIndex else {
      return value
    }

    let suffix = String(value[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return suffix.isEmpty ? value : suffix
  }

  private static func stableIdentifier(primary: String?, fallbacks: [String?], prefix: String)
    -> String
  {
    let candidates = [primary] + fallbacks
    for candidate in candidates {
      let normalized = normalizeKey(candidate)
      if !normalized.isEmpty {
        return "\(prefix)-\(normalized)"
      }
    }
    return "\(prefix)-unknown"
  }

  private static func parseNetworkActivitySummary(_ data: [String: Any], clients: [EeroClient])
    -> NetworkActivitySummary?
  {
    let day = usageTotals(usageRows(in: data, path: ["activity", "network", "data_usage_day"]))
    let week = usageTotals(usageRows(in: data, path: ["activity", "network", "data_usage_week"]))
    let month = usageTotals(usageRows(in: data, path: ["activity", "network", "data_usage_month"]))
    let busiestDevices = parseTopDeviceUsage(data, clients: clients)
    let busiestTimelines = parseDeviceUsageTimelines(
      data, clients: clients, topDevices: busiestDevices)

    if day.download == nil, day.upload == nil,
      week.download == nil, week.upload == nil,
      month.download == nil, month.upload == nil,
      busiestDevices.isEmpty,
      busiestTimelines.isEmpty
    {
      return nil
    }

    return NetworkActivitySummary(
      networkDataUsageDayDownload: day.download,
      networkDataUsageDayUpload: day.upload,
      networkDataUsageWeekDownload: week.download,
      networkDataUsageWeekUpload: week.upload,
      networkDataUsageMonthDownload: month.download,
      networkDataUsageMonthUpload: month.upload,
      busiestDevices: busiestDevices,
      busiestDeviceTimelines: busiestTimelines.isEmpty ? nil : busiestTimelines
    )
  }

  private static func parseTopDeviceUsage(_ data: [String: Any], clients: [EeroClient])
    -> [TopDeviceUsage]
  {
    let dayRows = usageRows(in: data, path: ["activity", "devices", "data_usage_day"])
    let weekRows = usageRows(in: data, path: ["activity", "devices", "data_usage_week"])
    let monthRows = usageRows(in: data, path: ["activity", "devices", "data_usage_month"])

    let day = usageByResourceID(in: data, path: ["activity", "devices", "data_usage_day"])
    let week = usageByResourceID(in: data, path: ["activity", "devices", "data_usage_week"])
    let month = usageByResourceID(in: data, path: ["activity", "devices", "data_usage_month"])

    let keys = Set(day.keys).union(week.keys).union(month.keys)
    guard !keys.isEmpty else {
      return []
    }

    var clientLookup: [String: EeroClient] = [:]
    for client in clients {
      let candidates = [
        client.id, client.mac, client.sourceURL.map { DictionaryValue.id(fromURL: $0) },
      ]
      for candidate in candidates {
        let normalized = normalizeKey(candidate)
        guard !normalized.isEmpty else { continue }
        if clientLookup[normalized] == nil {
          clientLookup[normalized] = client
        }
      }
    }

    var metadataLookup:
      [String: (name: String?, mac: String?, manufacturer: String?, deviceType: String?)] = [:]
    for row in dayRows + weekRows + monthRows {
      guard let resourceKey = resourceKeyForUsageRow(row) else { continue }
      let normalized = normalizeKey(resourceKey)
      guard !normalized.isEmpty else { continue }

      if metadataLookup[normalized] == nil {
        metadataLookup[normalized] = (
          name: DictionaryValue.string(in: row, path: ["display_name"])
            ?? DictionaryValue.string(in: row, path: ["name"])
            ?? DictionaryValue.string(in: row, path: ["nickname"])
            ?? DictionaryValue.string(in: row, path: ["hostname"])
            ?? DictionaryValue.string(in: row, path: ["device", "display_name"])
            ?? DictionaryValue.string(in: row, path: ["source", "location"]),
          mac: DictionaryValue.string(in: row, path: ["mac"])
            ?? DictionaryValue.string(in: row, path: ["device", "mac"]),
          manufacturer: DictionaryValue.string(in: row, path: ["manufacturer"])
            ?? DictionaryValue.string(in: row, path: ["device", "manufacturer"]),
          deviceType: DictionaryValue.string(in: row, path: ["device_type"])
            ?? DictionaryValue.string(in: row, path: ["device", "device_type"])
        )
      }
    }

    var entries: [TopDeviceUsage] = []
    entries.reserveCapacity(keys.count)

    for key in keys {
      let normalized = normalizeKey(key)
      let client = clientLookup[normalized]
      let metadata = metadataLookup[normalized]

      let name =
        client?.name
        ?? metadata?.name
        ?? key
      let macAddress = client?.mac ?? metadata?.mac
      let manufacturer = client?.manufacturer ?? metadata?.manufacturer
      let deviceType = client?.deviceType ?? metadata?.deviceType

      entries.append(
        TopDeviceUsage(
          id: stableIdentifier(
            primary: key, fallbacks: [macAddress, name], prefix: "usage-device"),
          name: name,
          macAddress: macAddress,
          manufacturer: manufacturer,
          deviceType: deviceType,
          dayDownloadBytes: usageByKey(key, from: day)?.download,
          dayUploadBytes: usageByKey(key, from: day)?.upload,
          weekDownloadBytes: usageByKey(key, from: week)?.download,
          weekUploadBytes: usageByKey(key, from: week)?.upload,
          monthDownloadBytes: usageByKey(key, from: month)?.download,
          monthUploadBytes: usageByKey(key, from: month)?.upload
        )
      )
    }

    func total(_ entry: TopDeviceUsage, period: String) -> Int {
      switch period {
      case "month":
        return max(0, (entry.monthDownloadBytes ?? 0) + (entry.monthUploadBytes ?? 0))
      case "week":
        return max(0, (entry.weekDownloadBytes ?? 0) + (entry.weekUploadBytes ?? 0))
      default:
        return max(0, (entry.dayDownloadBytes ?? 0) + (entry.dayUploadBytes ?? 0))
      }
    }

    return
      entries
      .sorted { lhs, rhs in
        let lhsMonth = total(lhs, period: "month")
        let rhsMonth = total(rhs, period: "month")
        if lhsMonth != rhsMonth {
          return lhsMonth > rhsMonth
        }
        let lhsWeek = total(lhs, period: "week")
        let rhsWeek = total(rhs, period: "week")
        if lhsWeek != rhsWeek {
          return lhsWeek > rhsWeek
        }
        let lhsDay = total(lhs, period: "day")
        let rhsDay = total(rhs, period: "day")
        if lhsDay != rhsDay {
          return lhsDay > rhsDay
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  private static func parseDeviceUsageTimelines(
    _ data: [String: Any],
    clients: [EeroClient],
    topDevices: [TopDeviceUsage]
  ) -> [DeviceUsageTimeline] {
    let timelineRows = DictionaryValue.dictArray(
      in: data, path: ["activity", "devices", "device_timelines"])
    guard !timelineRows.isEmpty else {
      return []
    }

    var topLookup: [String: TopDeviceUsage] = [:]
    for device in topDevices {
      let candidates = [device.id, trimStablePrefix(device.id), device.macAddress, device.name]
      for candidate in candidates {
        let normalized = normalizeKey(candidate)
        guard !normalized.isEmpty else { continue }
        if topLookup[normalized] == nil {
          topLookup[normalized] = device
        }
      }
    }

    var clientLookup: [String: EeroClient] = [:]
    for client in clients {
      let candidates = [
        client.id, trimStablePrefix(client.id), client.mac,
        client.sourceURL.map { DictionaryValue.id(fromURL: $0) },
      ]
      for candidate in candidates {
        let normalized = normalizeKey(candidate)
        guard !normalized.isEmpty else { continue }
        if clientLookup[normalized] == nil {
          clientLookup[normalized] = client
        }
      }
    }

    var timelines: [DeviceUsageTimeline] = []
    timelines.reserveCapacity(timelineRows.count)

    for row in timelineRows {
      let payload = DictionaryValue.value(in: row, path: ["payload"])
      let samples = parseTimelineSamples(from: payload)
      guard !samples.isEmpty else {
        continue
      }

      let resourceKey =
        DictionaryValue.string(in: row, path: ["resource_key"])
        ?? DictionaryValue.string(in: row, path: ["id"])
        ?? DictionaryValue.string(in: row, path: ["mac"])
        ?? DictionaryValue.string(in: row, path: ["display_name"])
        ?? "timeline"
      let normalizedResource = normalizeKey(resourceKey)
      let top = topLookup[normalizedResource]
      let client = clientLookup[normalizedResource]

      let embeddedDevice =
        DictionaryValue.dict(in: payload as? [String: Any] ?? [:], path: ["device"]) ?? [:]
      let embeddedName =
        DictionaryValue.string(in: embeddedDevice, path: ["display_name"])
        ?? DictionaryValue.string(in: embeddedDevice, path: ["nickname"])
        ?? DictionaryValue.string(in: embeddedDevice, path: ["hostname"])
      let embeddedMAC = DictionaryValue.string(in: embeddedDevice, path: ["mac"])

      let macAddress =
        DictionaryValue.string(in: row, path: ["mac"])
        ?? embeddedMAC
        ?? top?.macAddress
        ?? client?.mac
      let displayName =
        DictionaryValue.string(in: row, path: ["display_name"])
        ?? embeddedName
        ?? top?.name
        ?? client?.name
        ?? resourceKey

      timelines.append(
        DeviceUsageTimeline(
          id: stableIdentifier(
            primary: resourceKey, fallbacks: [macAddress, displayName], prefix: "usage-timeline"),
          name: displayName,
          macAddress: macAddress,
          samples: samples
        )
      )
    }

    return timelines.sorted { lhs, rhs in
      let lhsTotal = lhs.samples.reduce(0) {
        $0 + max(0, $1.downloadBytes) + max(0, $1.uploadBytes)
      }
      let rhsTotal = rhs.samples.reduce(0) {
        $0 + max(0, $1.downloadBytes) + max(0, $1.uploadBytes)
      }
      if lhsTotal != rhsTotal {
        return lhsTotal > rhsTotal
      }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private static func parseTimelineSamples(from payload: Any?) -> [DeviceUsageTimelineSample] {
    if let dict = payload as? [String: Any] {
      if let seriesSamples = parseTimelineSeriesSamples(from: dict), !seriesSamples.isEmpty {
        return seriesSamples
      }
      let fallbackSamples = parseDirectTimelineSamples(from: dict)
      if !fallbackSamples.isEmpty {
        return fallbackSamples
      }
    }

    if let rows = payload as? [[String: Any]], !rows.isEmpty {
      return parseDirectTimelineSamples(from: ["values": rows])
    }

    return []
  }

  private static func parseTimelineSeriesSamples(from payload: [String: Any])
    -> [DeviceUsageTimelineSample]?
  {
    let seriesRows = DictionaryValue.dictArray(in: payload, path: ["series"])
    guard !seriesRows.isEmpty else {
      return nil
    }

    var downloadByTime: [TimeInterval: Int] = [:]
    var uploadByTime: [TimeInterval: Int] = [:]

    for series in seriesRows {
      let rawType =
        DictionaryValue.string(in: series, path: ["type"])
        ?? DictionaryValue.string(in: series, path: ["data_usage_type"])
        ?? DictionaryValue.string(in: series, path: ["insight_type_name"])
        ?? ""
      let direction = usageDirection(fromRawType: rawType)
      let isDownload = direction == .download
      let isUpload = direction == .upload
      guard isDownload || isUpload else {
        continue
      }

      let valueRows = DictionaryValue.dictArray(in: series, path: ["values"])
      for value in valueRows {
        guard
          let timestamp = dateValue(
            DictionaryValue.value(in: value, path: ["time"])
              ?? DictionaryValue.value(in: value, path: ["timestamp"]))
        else {
          continue
        }
        let sampleValue = max(
          0,
          integerValue(DictionaryValue.value(in: value, path: ["value"]))
            ?? (direction.flatMap { usageByteValue(in: value, direction: $0) } ?? 0)
        )
        let key = timestamp.timeIntervalSince1970
        if isDownload {
          downloadByTime[key] = sampleValue
        }
        if isUpload {
          uploadByTime[key] = sampleValue
        }
      }
    }

    let timestamps = Set(downloadByTime.keys).union(uploadByTime.keys).sorted()
    guard !timestamps.isEmpty else {
      return nil
    }

    return timestamps.map { timestamp in
      let date = Date(timeIntervalSince1970: timestamp)
      return DeviceUsageTimelineSample(
        id: stableIdentifier(primary: "\(timestamp)", fallbacks: [], prefix: "timeline-sample"),
        timestamp: date,
        downloadBytes: max(0, downloadByTime[timestamp] ?? 0),
        uploadBytes: max(0, uploadByTime[timestamp] ?? 0)
      )
    }
  }

  private static func parseDirectTimelineSamples(from payload: [String: Any])
    -> [DeviceUsageTimelineSample]
  {
    let rows = usageRows(in: payload, path: ["values"])
    guard !rows.isEmpty else {
      return []
    }

    var samples: [DeviceUsageTimelineSample] = []
    samples.reserveCapacity(rows.count)

    for row in rows {
      guard
        let timestamp = dateValue(
          DictionaryValue.value(in: row, path: ["time"])
            ?? DictionaryValue.value(in: row, path: ["timestamp"])
            ?? DictionaryValue.value(in: row, path: ["date"])
        )
      else {
        continue
      }

      let download = max(0, usageByteValue(in: row, direction: .download) ?? 0)
      let upload = max(0, usageByteValue(in: row, direction: .upload) ?? 0)
      if download == 0, upload == 0 {
        continue
      }

      samples.append(
        DeviceUsageTimelineSample(
          id: stableIdentifier(
            primary: "\(timestamp.timeIntervalSince1970)", fallbacks: [], prefix: "timeline-sample"),
          timestamp: timestamp,
          downloadBytes: download,
          uploadBytes: upload
        )
      )
    }

    return samples.sorted { $0.timestamp < $1.timestamp }
  }

  private static func parseRealtimeSummary(_ clients: [EeroClient]) -> NetworkRealtimeSummary? {
    let activeUsageClients = clients.filter {
      $0.connected && ($0.usageDownMbps != nil || $0.usageUpMbps != nil)
    }
    guard !activeUsageClients.isEmpty else {
      return nil
    }

    let downMbps = activeUsageClients.reduce(0.0) { $0 + max(0, $1.usageDownMbps ?? 0) }
    let upMbps = activeUsageClients.reduce(0.0) { $0 + max(0, $1.usageUpMbps ?? 0) }

    return NetworkRealtimeSummary(
      downloadMbps: downMbps,
      uploadMbps: upMbps,
      sourceLabel: "eero client telemetry",
      sampledAt: Date()
    )
  }

  private static func parseProxiedNodesSummary(_ data: [String: Any]) -> ProxiedNodesSummary? {
    guard let proxied = DictionaryValue.dict(in: data, path: ["proxied_nodes"]) else {
      return nil
    }

    let devices = DictionaryValue.dictArray(in: proxied, path: ["devices"])
    let online = devices.filter { device in
      let rawStatus =
        DictionaryValue.string(in: device, path: ["status"])
        ?? DictionaryValue.string(in: device, path: ["status", "value"])
        ?? ""
      let normalized = rawStatus.lowercased()
      return normalized == "green" || normalized.contains("online")
    }.count

    let offline = devices.filter { device in
      let rawStatus =
        DictionaryValue.string(in: device, path: ["status"])
        ?? DictionaryValue.string(in: device, path: ["status", "value"])
        ?? ""
      let normalized = rawStatus.lowercased()
      return normalized == "red" || normalized.contains("offline")
    }.count

    return ProxiedNodesSummary(
      enabled: DictionaryValue.bool(in: proxied, path: ["enabled"]),
      totalDevices: devices.count,
      onlineDevices: online,
      offlineDevices: offline
    )
  }

  private static func parseChannelUtilizationSummary(_ data: [String: Any])
    -> NetworkChannelUtilizationSummary?
  {
    let raw = data["channel_utilization"]
    let channelPayload: [String: Any]

    if let dict = raw as? [String: Any] {
      channelPayload = dict
    } else if let rows = raw as? [[String: Any]] {
      channelPayload = ["utilization": rows]
    } else {
      return nil
    }

    let eeroRows = DictionaryValue.dictArray(in: channelPayload, path: ["eeros"])
    var eeroNameLookup: [String: String] = [:]
    for eero in eeroRows {
      let candidateName =
        DictionaryValue.string(in: eero, path: ["location"])
        ?? DictionaryValue.string(in: eero, path: ["nickname"])
        ?? DictionaryValue.string(in: eero, path: ["name"])
        ?? DictionaryValue.string(in: eero, path: ["model"])
      guard let candidateName, !candidateName.isEmpty else { continue }

      if let numericID = integerValue(DictionaryValue.value(in: eero, path: ["id"])) {
        eeroNameLookup[String(numericID)] = candidateName
      }
      if let stringID = DictionaryValue.string(in: eero, path: ["id"]) {
        eeroNameLookup[stringID] = candidateName
      }
      if let url = DictionaryValue.string(in: eero, path: ["url"]) {
        let key = DictionaryValue.id(fromURL: url)
        if !key.isEmpty {
          eeroNameLookup[key] = candidateName
        }
      }
    }

    let utilizationRows = DictionaryValue.dictArray(in: channelPayload, path: ["utilization"])
    guard !utilizationRows.isEmpty else {
      return nil
    }

    let radios = utilizationRows.compactMap { row -> ChannelUtilizationRadio? in
      let eeroID =
        stringValue(DictionaryValue.value(in: row, path: ["eero_id"]))
        ?? stringValue(DictionaryValue.value(in: row, path: ["eeroId"]))
      let bandValue =
        DictionaryValue.string(in: row, path: ["band"])
        ?? DictionaryValue.string(in: row, path: ["band", "value"])
      let controlChannel = integerValue(DictionaryValue.value(in: row, path: ["channel"]))
      let centerChannel = integerValue(DictionaryValue.value(in: row, path: ["center_channel"]))
      let channelBandwidth = DictionaryValue.string(in: row, path: ["channel_bandwidth"])
      let averageUtilization = integerValue(
        DictionaryValue.value(in: row, path: ["average_utilization"]))
      let maxUtilization = integerValue(DictionaryValue.value(in: row, path: ["max_utilization"]))
      let p99Utilization = integerValue(DictionaryValue.value(in: row, path: ["p99_utilization"]))
      let frequencyMHz = integerValue(DictionaryValue.value(in: row, path: ["frequency"]))

      let timeSeriesRows = DictionaryValue.dictArray(in: row, path: ["time_series_data"])
      let timeSeries = timeSeriesRows.compactMap { sampleRow -> ChannelUtilizationSample? in
        guard
          let timestamp = dateFromEpoch(
            numericValue(DictionaryValue.value(in: sampleRow, path: ["timestamp"])))
        else {
          return nil
        }

        let busy = integerValue(DictionaryValue.value(in: sampleRow, path: ["busy"]))
        let noise = integerValue(DictionaryValue.value(in: sampleRow, path: ["noise"]))
        let rxTx = integerValue(DictionaryValue.value(in: sampleRow, path: ["rx_tx"]))
        let rxOther = integerValue(DictionaryValue.value(in: sampleRow, path: ["rx_other"]))
        let sampleID = stableIdentifier(
          primary:
            "\(timestamp.timeIntervalSince1970)-\(busy ?? -1)-\(noise ?? -1)-\(rxTx ?? -1)-\(rxOther ?? -1)",
          fallbacks: [],
          prefix: "radio-sample"
        )

        return ChannelUtilizationSample(
          id: sampleID,
          timestamp: timestamp,
          busyPercent: busy,
          noisePercent: noise,
          rxTxPercent: rxTx,
          rxOtherPercent: rxOther
        )
      }

      let radioID = stableIdentifier(
        primary:
          "\(eeroID ?? "unknown")-\(bandValue ?? "band")-\(controlChannel.map(String.init) ?? "?")",
        fallbacks: [channelBandwidth],
        prefix: "radio"
      )

      return ChannelUtilizationRadio(
        id: radioID,
        eeroID: eeroID,
        eeroName: lookupEeroName(for: eeroID, in: eeroNameLookup),
        band: bandValue,
        controlChannel: controlChannel,
        centerChannel: centerChannel,
        channelBandwidth: channelBandwidth,
        frequencyMHz: frequencyMHz,
        averageUtilization: averageUtilization,
        maxUtilization: maxUtilization,
        p99Utilization: p99Utilization,
        timeSeries: timeSeries
      )
    }

    guard !radios.isEmpty else {
      return nil
    }

    return NetworkChannelUtilizationSummary(
      radios: radios.sorted { lhs, rhs in
        let lhsUtilization = lhs.averageUtilization ?? Int.min
        let rhsUtilization = rhs.averageUtilization ?? Int.min
        if lhsUtilization != rhsUtilization {
          return lhsUtilization > rhsUtilization
        }
        let lhsMax = lhs.maxUtilization ?? Int.min
        let rhsMax = rhs.maxUtilization ?? Int.min
        return lhsMax > rhsMax
      },
      sampledAt: Date()
    )
  }

  private static func lookupEeroName(for eeroID: String?, in names: [String: String]) -> String? {
    guard let eeroID, !eeroID.isEmpty else {
      return nil
    }
    if let direct = names[eeroID] {
      return direct
    }
    let normalized = normalizeKey(eeroID)
    return names.first { normalizeKey($0.key) == normalized }?.value
  }

  private static func dateFromEpoch(_ epoch: Double?) -> Date? {
    guard let epoch else {
      return nil
    }
    let seconds = epoch > 1_000_000_000_000 ? epoch / 1_000 : epoch
    return Date(timeIntervalSince1970: seconds)
  }

  private static func dateValue(_ value: Any?) -> Date? {
    if let date = value as? Date {
      return date
    }
    if let epoch = numericValue(value) {
      return dateFromEpoch(epoch)
    }
    if let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    {
      let isoFormatter = ISO8601DateFormatter()
      isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = isoFormatter.date(from: text) {
        return date
      }
      isoFormatter.formatOptions = [.withInternetDateTime]
      if let date = isoFormatter.date(from: text) {
        return date
      }

      let fallbackFormatter = DateFormatter()
      fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
      fallbackFormatter.timeZone = TimeZone(secondsFromGMT: 0)
      fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
      if let date = fallbackFormatter.date(from: text) {
        return date
      }
    }
    return nil
  }

  private static func parseWirelessCongestion(
    _ clients: [EeroClient],
    channelUtilization: NetworkChannelUtilizationSummary?
  ) -> WirelessCongestionSummary? {
    let wirelessClients = clients.filter { ($0.wireless ?? false) && $0.connected }
    guard !wirelessClients.isEmpty else {
      return nil
    }

    let scoreBars = wirelessClients.compactMap(\.scoreBars).map(Double.init)
    let signals = wirelessClients.compactMap { parseSignalDBM($0.signal) }

    let poorSignalCount = wirelessClients.filter { client in
      if let signal = parseSignalDBM(client.signal) {
        return signal <= -70
      }
      if let bars = client.scoreBars {
        return bars <= 2
      }
      return false
    }.count

    let estimatedChannelGroups = Dictionary(grouping: wirelessClients) { client -> String in
      let band = deriveBandLabel(client: client) ?? "Unavailable"
      let channelText = client.channel.map(String.init) ?? "?"
      return "\(channelText)-\(band)"
    }

    var congestedChannels =
      estimatedChannelGroups
      .compactMap { key, grouped -> CongestedChannelSummary? in
        guard grouped.count >= 2 else {
          return nil
        }
        let channel = grouped.first?.channel
        let band = deriveBandLabel(client: grouped.first)
        let averageSignal = average(
          grouped.compactMap { parseSignalDBM($0.signal) }.map(Double.init))
        return CongestedChannelSummary(
          key: key,
          channel: channel,
          band: band,
          clientCount: grouped.count,
          averageSignalDbm: averageSignal.map { Int($0.rounded()) }
        )
      }
      .sorted {
        if $0.clientCount == $1.clientCount {
          return ($0.averageSignalDbm ?? Int.min) < ($1.averageSignalDbm ?? Int.min)
        }
        return $0.clientCount > $1.clientCount
      }

    if let channelUtilization {
      let clientCountLookup = estimatedChannelGroups.reduce(into: [String: Int]()) {
        partial, pair in
        partial[pair.key] = pair.value.count
      }

      let radioCongestion = channelUtilization.radios.compactMap {
        radio -> CongestedChannelSummary? in
        let band = radio.band ?? "Unavailable"
        let channel = radio.controlChannel
        let lookupKey = "\(channel.map(String.init) ?? "?")-\(band)"
        let estimatedClients = clientCountLookup[lookupKey] ?? 0
        let utilizationScore = max(0, radio.averageUtilization ?? 0)
        guard utilizationScore > 0 else {
          return nil
        }
        return CongestedChannelSummary(
          key: stableIdentifier(
            primary: "\(lookupKey)-\(radio.eeroID ?? "")", fallbacks: [radio.eeroName],
            prefix: "channel"),
          channel: channel,
          band: band,
          clientCount: max(estimatedClients, utilizationScore),
          averageSignalDbm: nil
        )
      }

      if !radioCongestion.isEmpty {
        congestedChannels = radioCongestion.sorted { lhs, rhs in
          if lhs.clientCount == rhs.clientCount {
            return (lhs.channel ?? Int.max) < (rhs.channel ?? Int.max)
          }
          return lhs.clientCount > rhs.clientCount
        }
      }
    }

    return WirelessCongestionSummary(
      wirelessClientCount: wirelessClients.count,
      poorSignalClientCount: poorSignalCount,
      averageScoreBars: average(scoreBars),
      averageSignalDbm: average(signals.map(Double.init)),
      congestedChannels: Array(congestedChannels.prefix(6))
    )
  }

  private static func deviceStatusIsOnline(_ status: String?) -> Bool {
    guard let normalized = status?.lowercased() else {
      return false
    }
    if normalized == "green" || normalized == "healthy" || normalized == "active" {
      return true
    }
    return normalized.contains("connected")
      || normalized.contains("online")
      || normalized.contains("up")
      || normalized == "ok"
  }

  private static func deriveBandLabel(client: EeroClient?) -> String? {
    guard let client else { return nil }

    if let channel = client.channel {
      switch channel {
      case 1...14:
        return "2.4 GHz"
      case 15...191:
        return "5 GHz"
      default:
        return "6 GHz"
      }
    }

    if let frequency = numericValue(client.interfaceFrequency) {
      if frequency >= 5900 {
        return "6 GHz"
      }
      if frequency >= 4900 {
        return "5 GHz"
      }
      return "2.4 GHz"
    }

    return nil
  }

  private static func parseSignalDBM(_ signal: String?) -> Int? {
    guard let signal else {
      return nil
    }
    let prefix = signal.split(separator: " ").first.map(String.init) ?? signal
    return Int(prefix)
  }

  private static func usageTotals(_ rows: [[String: Any]]) -> (download: Int?, upload: Int?) {
    var totals: (download: Int?, upload: Int?) = (download: nil, upload: nil)
    for row in rows {
      accumulateUsage(in: &totals, row: row)
    }
    return totals
  }

  private static func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else {
      return nil
    }
    let total = values.reduce(0, +)
    return total / Double(values.count)
  }

  private static func enumLabel(from value: Any?) -> String? {
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let dict = value as? [String: Any] {
      return stringValue(dict["value"])
        ?? stringValue(dict["name"])
        ?? stringValue(dict["tag"])
        ?? stringValue(dict["label"])
    }
    return stringValue(value)
  }

  private static func firstRateMbps(
    in data: [String: Any],
    pathPrefixes: [[String]]
  ) -> Double? {
    for prefix in pathPrefixes {
      let direct = DictionaryValue.value(in: data, path: prefix)
      if let rate = rateMbps(from: direct) {
        return rate
      }

      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rate_mbps"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rateMbps"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["mbps"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rate"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rate_info"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rateInfo"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rate_bps"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["rateBps"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["bps"])) {
        return rate
      }
      if let rate = rateMbps(from: DictionaryValue.value(in: data, path: prefix + ["value"])) {
        return rate
      }
    }
    return nil
  }

  private static func rateMbps(from value: Any?) -> Double? {
    guard let value else {
      return nil
    }

    if let dict = value as? [String: Any] {
      if let mbps = numericValue(dict["rate_mbps"])
        ?? numericValue(dict["rateMbps"])
        ?? numericValue(dict["mbps"])
        ?? numericValue(dict["value_mbps"])
        ?? numericValue(dict["valueMbps"])
        ?? numericValue(dict["link_speed_mbps"])
        ?? numericValue(dict["linkSpeedMbps"])
      {
        return mbps
      }

      if let bps = numericValue(dict["rate_bps"])
        ?? numericValue(dict["rateBps"])
        ?? numericValue(dict["bps"])
        ?? numericValue(dict["value_bps"])
        ?? numericValue(dict["valueBps"])
      {
        return bps / 1_000_000
      }

      if let nested = dict["rate"],
        let nestedRate = rateMbps(from: nested)
      {
        return nestedRate
      }
      if let nested = dict["rate_info"],
        let nestedRate = rateMbps(from: nested)
      {
        return nestedRate
      }
      if let nested = dict["rateInfo"],
        let nestedRate = rateMbps(from: nested)
      {
        return nestedRate
      }
      if let nested = dict["value"],
        let nestedRate = rateMbps(from: nested)
      {
        return nestedRate
      }
    }

    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, let parsed = parseRateStringInMbps(trimmed) {
        return parsed
      }
    }

    if let numeric = numericValue(value) {
      if numeric > 100_000 {
        return numeric / 1_000_000
      }
      return numeric
    }

    return nil
  }

  private static func parseRateStringInMbps(_ text: String) -> Double? {
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
      if number > 100_000 {
        return number / 1_000_000
      }
      return number
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

    if number > 100_000 {
      return number / 1_000_000
    }
    return number
  }

  private static func parseStringArray(_ value: Any?) -> [String] {
    if let strings = value as? [String] {
      return
        strings
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    if let rows = value as? [[String: Any]] {
      return rows.compactMap { row in
        DictionaryValue.string(in: row, path: ["id"])
          ?? DictionaryValue.string(in: row, path: ["name"])
          ?? DictionaryValue.string(in: row, path: ["value"])
          ?? DictionaryValue.string(in: row, path: ["title"])
      }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    }
    return []
  }

  private static func formattedBitRate(_ bitsPerSecond: Double) -> String {
    if bitsPerSecond >= 1_000_000_000 {
      return String(format: "%.1f Gbps", bitsPerSecond / 1_000_000_000)
    }
    if bitsPerSecond >= 1_000_000 {
      return String(format: "%.0f Mbps", bitsPerSecond / 1_000_000)
    }
    if bitsPerSecond >= 1_000 {
      return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
    }
    return String(format: "%.0f bps", bitsPerSecond)
  }

  private static func numericValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string)
    }
    return nil
  }

  private static func integerValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
      return int
    }
    if let int64 = value as? Int64 {
      if int64 > Int64(Int.max) || int64 < Int64(Int.min) {
        return nil
      }
      return Int(int64)
    }
    if let number = value as? NSNumber {
      let int64 = number.int64Value
      if int64 > Int64(Int.max) || int64 < Int64(Int.min) {
        return nil
      }
      return Int(int64)
    }
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if let int64 = Int64(trimmed) {
        if int64 > Int64(Int.max) || int64 < Int64(Int.min) {
          return nil
        }
        return Int(int64)
      }
      if let int = Int(trimmed) {
        return int
      }
      if let double = Double(trimmed), double.isFinite {
        if double > Double(Int.max) || double < Double(Int.min) {
          return nil
        }
        return Int(double.rounded())
      }
    }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let text = value as? String {
      return text
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    return nil
  }
}
