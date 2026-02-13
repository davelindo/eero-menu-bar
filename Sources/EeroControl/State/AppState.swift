import Combine
import Darwin
import Foundation

struct PendingConfirmation: Identifiable {
  let id = UUID()
  let action: EeroAction
  let title: String
  let message: String
}

@MainActor
final class ThroughputStore: ObservableObject {
  struct DisplayKey: Equatable {
    var interfaceName: String
    var downDisplay: String
    var upDisplay: String
  }

  @Published private(set) var snapshot: LocalThroughputSnapshot?
  private var lastDisplayKey: DisplayKey?

  func publish(_ snapshot: LocalThroughputSnapshot?) {
    let key = snapshot.map {
      DisplayKey(
        interfaceName: $0.interfaceName,
        downDisplay: $0.downDisplay,
        upDisplay: $0.upDisplay
      )
    }

    guard key != lastDisplayKey else { return }
    lastDisplayKey = key
    self.snapshot = snapshot
  }
}

@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  @Published var authState: AuthState = .restoring
  @Published var cloudState: CloudReachabilityState = .unknown
  @Published var accountSnapshot: EeroAccountSnapshot?
  @Published var cachedFreshness: CachedDataFreshness?
  @Published var offlineSnapshot: OfflineProbeSnapshot = .empty
  @Published var queuedActions: [QueuedAction] = []

  @Published var selectedNetworkID: String?
  @Published var isRefreshing = false
  @Published var lastErrorMessage: String?

  @Published var loginInput: String = ""
  @Published var verificationCode: String = ""

  @Published var settings: AppSettings {
    didSet {
      let normalized = settings.normalized()
      if settings != normalized {
        settings = normalized
        return
      }
      if settingsStore.settings != normalized {
        settingsStore.settings = normalized
      }
      pollingCoordinator.updateIntervals(
        foreground: normalized.foregroundPollInterval,
        background: normalized.backgroundPollInterval
      )
    }
  }

  @Published var pendingConfirmation: PendingConfirmation?
  let throughputStore: ThroughputStore

  var selectedNetwork: EeroNetwork? {
    guard let accountSnapshot else { return nil }
    let fallback = accountSnapshot.networks.first
    guard let selectedNetworkID else { return fallback }
    return accountSnapshot.networks.first(where: { $0.id == selectedNetworkID }) ?? fallback
  }

  var cloudAndLanStatus: String {
    switch cloudState {
    case .reachable:
      return "\(offlineSnapshot.localHealthLabel) / Cloud OK"
    case .degraded, .unreachable:
      return "\(offlineSnapshot.localHealthLabel) / Cloud Down"
    case .unknown:
      return "Status Unknown"
    }
  }

  private let settingsStore: SettingsStore
  private let apiClient: EeroAPIClient
  private let authService: AuthService
  private let offlineService: OfflineConnectivityService
  private let offlineStateStore: OfflineStateStore
  private let actionExecutor: ActionExecutor
  private let pollingCoordinator: PollingCoordinator

  private var hasStarted = false
  private var isPopoverVisible = false
  private var isWindowVisible = true
  private var lastOfflineProbeRun: Date = .distantPast
  private var throughputTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()

  private init() {
    settingsStore = SettingsStore()
    let initialSettings = settingsStore.settings
    settings = initialSettings
    throughputStore = ThroughputStore()

    apiClient = EeroAPIClient()
    let credentialStore = KeychainCredentialStore()
    authService = AuthService(apiClient: apiClient, credentialStore: credentialStore)
    offlineService = OfflineConnectivityService()
    offlineStateStore = OfflineStateStore()
    let queue = PendingActionQueue()
    actionExecutor = ActionExecutor(apiClient: apiClient, queue: queue)

    pollingCoordinator = PollingCoordinator(
      foregroundInterval: initialSettings.foregroundPollInterval,
      backgroundInterval: initialSettings.backgroundPollInterval
    )

    pollingCoordinator.onTick = { [weak self] in
      await self?.refreshAccount(reason: "poll", forceOfflineProbe: false)
    }

    settingsStore.$settings
      .receive(on: RunLoop.main)
      .sink { [weak self] value in
        guard let self else { return }
        if self.settings != value {
          self.settings = value
        }
      }
      .store(in: &cancellables)
  }

  deinit {
    throughputTask?.cancel()
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    startLocalThroughputMonitoring()

    if let cached = offlineStateStore.load() {
      accountSnapshot = cached
      cachedFreshness = CachedDataFreshness(fetchedAt: cached.fetchedAt)
      selectedNetworkID = cached.networks.first?.id
    }

    Task {
      await refreshQueuedActions()
      await bootstrapSession()
    }
  }

  func setPopoverVisible(_ visible: Bool) {
    isPopoverVisible = visible
    updatePollingMode()
  }

  func setWindowVisible(_ visible: Bool) {
    isWindowVisible = visible
    updatePollingMode()
  }

  func requestLogin() {
    let login = loginInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !login.isEmpty else {
      lastErrorMessage = "Enter a phone number or email first."
      return
    }

    Task {
      do {
        try await authService.login(login: login)
        await MainActor.run {
          authState = .waitingForVerification(login: login)
          lastErrorMessage = nil
        }
      } catch {
        await MainActor.run {
          lastErrorMessage = error.localizedDescription
        }
      }
    }
  }

  func restartAuthentication() {
    verificationCode = ""
    authState = .unauthenticated
    lastErrorMessage = nil
  }

  func verifyLoginCode() {
    let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else {
      lastErrorMessage = "Enter the verification code."
      return
    }

    Task {
      do {
        _ = try await authService.verify(code: code)
        await MainActor.run {
          authState = .authenticated
          verificationCode = ""
          lastErrorMessage = nil
          pollingCoordinator.start()
          updatePollingMode()
        }
        await refreshAccount(reason: "verify", forceOfflineProbe: true)
      } catch {
        await MainActor.run {
          lastErrorMessage = error.localizedDescription
        }
      }
    }
  }

  func logout() {
    Task {
      await authService.logout()
      await MainActor.run {
        authState = .unauthenticated
        cloudState = .unknown
        pollingCoordinator.stop()
        accountSnapshot = nil
        selectedNetworkID = nil
        pendingConfirmation = nil
      }
      await refreshQueuedActions()
    }
  }

  func refreshNow() {
    Task {
      await refreshAccount(reason: "manual", forceOfflineProbe: true)
    }
  }

  func replayQueuedActions() {
    Task {
      await actionExecutor.replayQueuedActions()
      await refreshQueuedActions()
      await refreshAccount(reason: "queue-replay", forceOfflineProbe: true)
    }
  }

  func removeQueuedAction(id: UUID) {
    Task {
      await actionExecutor.removeQueuedAction(id: id)
      await refreshQueuedActions()
    }
  }

  func submitAction(_ action: EeroAction) {
    if requiresConfirmation(for: action) {
      pendingConfirmation = PendingConfirmation(
        action: action,
        title: "Confirm Action",
        message: action.label
      )
      return
    }

    Task {
      await executeAction(action)
    }
  }

  func confirmPendingAction() {
    guard let pending = pendingConfirmation else { return }
    pendingConfirmation = nil
    Task {
      await executeAction(pending.action)
    }
  }

  func cancelPendingAction() {
    pendingConfirmation = nil
  }

  func setGuestNetwork(network: EeroNetwork, enabled: Bool) {
    let networkID = apiID(from: network.id, prefix: "network")
    let action = EeroAction(
      kind: .setGuestNetwork,
      networkID: network.id,
      endpoint: "/2.2/networks/\(networkID)/guestnetwork",
      method: .put,
      payload: ["enabled": .bool(enabled)],
      label: "Set Guest Network to \(enabled ? "On" : "Off") for \(network.displayName)",
      riskLevel: .low,
      queueEligible: true
    )
    submitAction(action)
  }

  func setNetworkFeature(network: EeroNetwork, key: String, enabled: Bool) {
    let networkID = apiID(from: network.id, prefix: "network")
    let action: EeroAction

    switch key {
    case "thread_enabled":
      let base = network.resources["thread"] ?? "/2.2/networks/\(networkID)/thread"
      action = EeroAction(
        kind: .setNetworkFeature,
        networkID: network.id,
        endpoint: "\(base)/enable",
        method: .put,
        payload: ["enabled": .bool(enabled)],
        label: "Set Thread to \(enabled ? "On" : "Off")",
        riskLevel: .moderate,
        queueEligible: true
      )
    case "ad_block":
      action = EeroAction(
        kind: .setNetworkFeature,
        networkID: network.id,
        endpoint: "/2.2/networks/\(networkID)/dns_policies/adblock",
        method: .post,
        payload: ["enable": .bool(enabled)],
        label: "Set Ad Block to \(enabled ? "On" : "Off")",
        riskLevel: .moderate,
        queueEligible: true
      )
    case "block_malware":
      action = EeroAction(
        kind: .setNetworkFeature,
        networkID: network.id,
        endpoint: "/2.2/networks/\(networkID)/dns_policies/network",
        method: .post,
        payload: ["block_malware": .bool(enabled)],
        label: "Set Malware Blocking to \(enabled ? "On" : "Off")",
        riskLevel: .moderate,
        queueEligible: true
      )
    default:
      let settingsURL = network.resources["settings"] ?? "/2.2/networks/\(networkID)/settings"
      action = EeroAction(
        kind: .setNetworkFeature,
        networkID: network.id,
        endpoint: settingsURL,
        method: .put,
        payload: [key: .bool(enabled)],
        label: "Set \(key) to \(enabled ? "On" : "Off")",
        riskLevel: .moderate,
        queueEligible: true
      )
    }

    submitAction(action)
  }

  func setClientPaused(network: EeroNetwork, client: EeroClient, paused: Bool) {
    guard let mac = client.mac else {
      lastErrorMessage = "Client MAC is unavailable for \(client.name)."
      return
    }
    let networkID = apiID(from: network.id, prefix: "network")

    let action = EeroAction(
      kind: .setClientPaused,
      networkID: network.id,
      targetID: client.id,
      endpoint: "/2.3/networks/\(networkID)/devices/\(mac)",
      method: .put,
      payload: ["paused": .bool(paused)],
      label: "\(paused ? "Pause" : "Resume") client \(client.name)",
      riskLevel: .low,
      queueEligible: true
    )

    submitAction(action)
  }

  func setProfilePaused(network: EeroNetwork, profile: EeroProfile, paused: Bool) {
    let networkID = apiID(from: network.id, prefix: "network")
    let profileID = apiID(from: profile.id, prefix: "profile")
    let action = EeroAction(
      kind: .setProfilePaused,
      networkID: network.id,
      targetID: profile.id,
      endpoint: "/2.2/networks/\(networkID)/profiles/\(profileID)",
      method: .put,
      payload: ["paused": .bool(paused)],
      label: "\(paused ? "Pause" : "Resume") profile \(profile.name)",
      riskLevel: .low,
      queueEligible: true
    )

    submitAction(action)
  }

  func setProfileFilter(network: EeroNetwork, profile: EeroProfile, key: String, enabled: Bool) {
    let networkID = apiID(from: network.id, prefix: "network")
    let profileID = apiID(from: profile.id, prefix: "profile")
    let action = EeroAction(
      kind: .setProfileContentFilter,
      networkID: network.id,
      targetID: profile.id,
      endpoint: "/2.2/networks/\(networkID)/dns_policies/profiles/\(profileID)",
      method: .post,
      payload: [key: .bool(enabled)],
      label: "Set \(profile.name) filter \(key) to \(enabled ? "On" : "Off")",
      riskLevel: .moderate,
      queueEligible: true
    )

    submitAction(action)
  }

  func setProfileBlockedApps(network: EeroNetwork, profile: EeroProfile, apps: [String]) {
    let networkID = apiID(from: network.id, prefix: "network")
    let profileID = apiID(from: profile.id, prefix: "profile")
    let normalized = apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
    let action = EeroAction(
      kind: .setProfileBlockedApps,
      networkID: network.id,
      targetID: profile.id,
      endpoint:
        "/2.2/networks/\(networkID)/dns_policies/profiles/\(profileID)/applications/blocked",
      method: .put,
      payload: ["applications": .array(normalized.map(JSONValue.string))],
      label: "Update blocked apps for \(profile.name)",
      riskLevel: .moderate,
      queueEligible: true
    )

    submitAction(action)
  }

  func setDeviceStatusLight(network: EeroNetwork, device: EeroDevice, enabled: Bool) {
    let deviceID = apiID(from: device.id, prefix: "eero")
    let endpoint = device.resources["led_action"] ?? "/2.2/eeros/\(deviceID)/led"
    let action = EeroAction(
      kind: .setDeviceStatusLight,
      networkID: network.id,
      targetID: device.id,
      endpoint: endpoint,
      method: .put,
      payload: ["led_on": .bool(enabled)],
      label: "Set status light on \(device.name) to \(enabled ? "On" : "Off")",
      riskLevel: .low,
      queueEligible: true
    )

    submitAction(action)
  }

  func rebootDevice(network: EeroNetwork, device: EeroDevice) {
    let deviceID = apiID(from: device.id, prefix: "eero")
    let endpoint = device.resources["reboot"] ?? "/2.2/eeros/\(deviceID)/reboot"
    let action = EeroAction(
      kind: .rebootDevice,
      networkID: network.id,
      targetID: device.id,
      endpoint: endpoint,
      method: .post,
      payload: [:],
      label: "Reboot \(device.name)",
      riskLevel: .high,
      queueEligible: false
    )

    submitAction(action)
  }

  func rebootNetwork(_ network: EeroNetwork) {
    let networkID = apiID(from: network.id, prefix: "network")
    let endpoint = network.resources["reboot"] ?? "/2.2/networks/\(networkID)/reboot"
    let action = EeroAction(
      kind: .rebootNetwork,
      networkID: network.id,
      endpoint: endpoint,
      method: .post,
      payload: [:],
      label: "Reboot network \(network.displayName)",
      riskLevel: .high,
      queueEligible: false
    )

    submitAction(action)
  }

  func runNetworkSpeedTest(_ network: EeroNetwork) {
    let networkID = apiID(from: network.id, prefix: "network")
    let endpoint = network.resources["speedtest"] ?? "/2.2/networks/\(networkID)/speedtest"
    let action = EeroAction(
      kind: .runSpeedTest,
      networkID: network.id,
      endpoint: endpoint,
      method: .post,
      payload: [:],
      label: "Run speed test for \(network.displayName)",
      riskLevel: .moderate,
      queueEligible: false
    )

    submitAction(action)
  }

  func runBurstReporters(_ network: EeroNetwork) {
    let networkID = apiID(from: network.id, prefix: "network")
    let endpoint =
      network.resources["burst_reporters"] ?? "/2.2/networks/\(networkID)/burst_reporters"
    let action = EeroAction(
      kind: .runBurstReporters,
      networkID: network.id,
      endpoint: endpoint,
      method: .post,
      payload: [:],
      label: "Run burst reporters for \(network.displayName)",
      riskLevel: .moderate,
      queueEligible: false
    )

    submitAction(action)
  }

  private func apiID(from value: String, prefix: String) -> String {
    let marker = "\(prefix)-"
    guard value.hasPrefix(marker) else {
      return value
    }
    let stripped = String(value.dropFirst(marker.count))
    return stripped.isEmpty ? value : stripped
  }

  private func requiresConfirmation(for action: EeroAction) -> Bool {
    switch action.riskLevel {
    case .high:
      return true
    case .moderate:
      return settings.askConfirmationForModerateRisk
    case .low:
      return false
    }
  }

  private func executeAction(_ action: EeroAction) async {
    let cloudReachable = cloudState == .reachable
    let result = await actionExecutor.execute(action, cloudReachable: cloudReachable)
    await refreshQueuedActions()

    switch result {
    case .success:
      lastErrorMessage = nil
      await refreshAccount(reason: "action", forceOfflineProbe: false)
    case .queued:
      lastErrorMessage = "Action queued until cloud connectivity returns."
    case .rejected(let message), .failed(let message):
      lastErrorMessage = message
    }
  }

  private func bootstrapSession() async {
    let restored = await authService.restoreSession()
    if restored {
      authState = .authenticated
      cloudState = .degraded
      pollingCoordinator.start()
      updatePollingMode()
      await refreshAccount(reason: "startup", forceOfflineProbe: true)
    } else {
      authState = .unauthenticated
      cloudState = .unknown
      await runOfflineProbeSuite(force: true)
    }
  }

  private func updatePollingMode() {
    let mode: PollMode = (isPopoverVisible || isWindowVisible) ? .foreground : .background
    pollingCoordinator.setMode(mode)
  }

  private func refreshAccount(reason: String, forceOfflineProbe: Bool) async {
    guard authState == .authenticated else {
      await runOfflineProbeSuite(force: true)
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let snapshot = try await apiClient.fetchAccount(config: UpdateConfig())
      let hydratedSnapshot = mergedSnapshot(latest: snapshot, fallback: accountSnapshot)

      accountSnapshot = hydratedSnapshot
      cachedFreshness = CachedDataFreshness(fetchedAt: hydratedSnapshot.fetchedAt)
      if selectedNetworkID == nil {
        selectedNetworkID = hydratedSnapshot.networks.first?.id
      }
      offlineStateStore.save(hydratedSnapshot)

      cloudState = .reachable
      lastErrorMessage = nil

      await actionExecutor.replayQueuedActions()
      await refreshQueuedActions()
    } catch {
      if accountSnapshot == nil, let cached = offlineStateStore.load() {
        accountSnapshot = cached
        cachedFreshness = CachedDataFreshness(fetchedAt: cached.fetchedAt)
        selectedNetworkID = cached.networks.first?.id
      }

      if accountSnapshot != nil {
        cloudState = .degraded
        if reason == "poll" {
          lastErrorMessage = nil
        } else {
          lastErrorMessage =
            "\(reason.capitalized) refresh failed; showing cached data: \(error.localizedDescription)"
        }
      } else {
        cloudState = .unreachable
        lastErrorMessage = "\(reason.capitalized) refresh failed: \(error.localizedDescription)"
      }
    }

    await runOfflineProbeSuite(force: forceOfflineProbe || cloudState != .reachable)
  }

  private func runOfflineProbeSuite(force: Bool) async {
    let age = Date().timeIntervalSince(lastOfflineProbeRun)
    if !force, age < 30 {
      return
    }

    let snapshot = await offlineService.runOfflineProbeSuite(gateway: settings.gatewayAddress)
    offlineSnapshot = snapshot
    lastOfflineProbeRun = Date()
  }

  private func refreshQueuedActions() async {
    queuedActions = await actionExecutor.queuedActions()
  }

  private func mergedSnapshot(latest: EeroAccountSnapshot, fallback: EeroAccountSnapshot?)
    -> EeroAccountSnapshot
  {
    guard let fallback else {
      return latest
    }

    let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.networks.map { ($0.id, $0) })
    let mergedNetworks = latest.networks.map { network in
      guard let stale = fallbackByID[network.id] else {
        return network
      }
      return mergedNetwork(latest: network, fallback: stale)
    }

    return EeroAccountSnapshot(
      fetchedAt: latest.fetchedAt,
      networks: mergedNetworks,
      modelAudit: latest.modelAudit ?? fallback.modelAudit
    )
  }

  private func mergedNetwork(latest: EeroNetwork, fallback: EeroNetwork) -> EeroNetwork {
    var network = latest

    network.nickname = network.nickname ?? fallback.nickname
    network.status = network.status ?? fallback.status
    network.guestNetworkName = network.guestNetworkName ?? fallback.guestNetworkName
    network.guestNetworkPassword = network.guestNetworkPassword ?? fallback.guestNetworkPassword
    network.guestNetworkDetails = network.guestNetworkDetails ?? fallback.guestNetworkDetails
    network.backupInternetEnabled = network.backupInternetEnabled ?? fallback.backupInternetEnabled
    network.resources = fallback.resources.merging(
      network.resources, uniquingKeysWith: { _, latestValue in latestValue })

    network.features = NetworkFeatureState(
      adBlock: network.features.adBlock ?? fallback.features.adBlock,
      blockMalware: network.features.blockMalware ?? fallback.features.blockMalware,
      bandSteering: network.features.bandSteering ?? fallback.features.bandSteering,
      upnp: network.features.upnp ?? fallback.features.upnp,
      wpa3: network.features.wpa3 ?? fallback.features.wpa3,
      threadEnabled: network.features.threadEnabled ?? fallback.features.threadEnabled,
      sqm: network.features.sqm ?? fallback.features.sqm,
      ipv6Upstream: network.features.ipv6Upstream ?? fallback.features.ipv6Upstream
    )

    network.ddns = NetworkDDNSSummary(
      enabled: network.ddns.enabled ?? fallback.ddns.enabled,
      subdomain: network.ddns.subdomain ?? fallback.ddns.subdomain
    )

    network.health = NetworkHealthSummary(
      internetStatus: network.health.internetStatus ?? fallback.health.internetStatus,
      internetUp: network.health.internetUp ?? fallback.health.internetUp,
      eeroNetworkStatus: network.health.eeroNetworkStatus ?? fallback.health.eeroNetworkStatus
    )

    network.diagnostics = NetworkDiagnosticsSummary(
      status: network.diagnostics.status ?? fallback.diagnostics.status
    )

    network.updates = NetworkUpdateSummary(
      hasUpdate: network.updates.hasUpdate ?? fallback.updates.hasUpdate,
      canUpdateNow: network.updates.canUpdateNow ?? fallback.updates.canUpdateNow,
      targetFirmware: network.updates.targetFirmware ?? fallback.updates.targetFirmware,
      minRequiredFirmware: network.updates.minRequiredFirmware
        ?? fallback.updates.minRequiredFirmware,
      updateToFirmware: network.updates.updateToFirmware ?? fallback.updates.updateToFirmware,
      updateStatus: network.updates.updateStatus ?? fallback.updates.updateStatus,
      preferredUpdateHour: network.updates.preferredUpdateHour
        ?? fallback.updates.preferredUpdateHour,
      scheduledUpdateTime: network.updates.scheduledUpdateTime
        ?? fallback.updates.scheduledUpdateTime,
      lastUpdateStarted: network.updates.lastUpdateStarted ?? fallback.updates.lastUpdateStarted
    )

    network.speed = NetworkSpeedSummary(
      measuredDownValue: network.speed.measuredDownValue ?? fallback.speed.measuredDownValue,
      measuredDownUnits: network.speed.measuredDownUnits ?? fallback.speed.measuredDownUnits,
      measuredUpValue: network.speed.measuredUpValue ?? fallback.speed.measuredUpValue,
      measuredUpUnits: network.speed.measuredUpUnits ?? fallback.speed.measuredUpUnits,
      measuredAt: network.speed.measuredAt ?? fallback.speed.measuredAt,
      latestSpeedTest: network.speed.latestSpeedTest ?? fallback.speed.latestSpeedTest
    )

    network.support = NetworkSupportSummary(
      supportPhone: network.support.supportPhone ?? fallback.support.supportPhone,
      contactURL: network.support.contactURL ?? fallback.support.contactURL,
      helpURL: network.support.helpURL ?? fallback.support.helpURL,
      emailWebFormURL: network.support.emailWebFormURL ?? fallback.support.emailWebFormURL,
      name: network.support.name ?? fallback.support.name
    )

    network.acCompatibility = NetworkACCompatibilitySummary(
      enabled: network.acCompatibility.enabled ?? fallback.acCompatibility.enabled,
      state: network.acCompatibility.state ?? fallback.acCompatibility.state
    )

    network.insights = NetworkInsightsSummary(
      available: network.insights.available || fallback.insights.available,
      lastError: network.insights.lastError ?? fallback.insights.lastError
    )

    network.threadDetails = network.threadDetails ?? fallback.threadDetails
    network.burstReporters = network.burstReporters ?? fallback.burstReporters
    network.gatewayIP = network.gatewayIP ?? fallback.gatewayIP
    network.mesh = network.mesh ?? fallback.mesh
    network.wirelessCongestion = network.wirelessCongestion ?? fallback.wirelessCongestion
    network.realtime = network.realtime ?? fallback.realtime
    network.channelUtilization = network.channelUtilization ?? fallback.channelUtilization
    network.proxiedNodes = network.proxiedNodes ?? fallback.proxiedNodes

    network.activity = mergedActivity(latest: network.activity, fallback: fallback.activity)

    network.clients = mergedClients(latest: network.clients, fallback: fallback.clients)

    if network.profiles.isEmpty, !fallback.profiles.isEmpty {
      network.profiles = fallback.profiles
    }

    network.devices = mergedDevices(latest: network.devices, fallback: fallback.devices)

    if !network.clients.isEmpty {
      network.connectedClientsCount = network.clients.filter(\.connected).count
      network.connectedGuestClientsCount =
        network.clients.filter { $0.connected && $0.isGuest }.count
    }

    return network
  }

  private func mergedActivity(
    latest: NetworkActivitySummary?,
    fallback: NetworkActivitySummary?
  ) -> NetworkActivitySummary? {
    guard var latest else {
      return fallback
    }
    guard let fallback else {
      return latest
    }

    latest.networkDataUsageDayDownload =
      latest.networkDataUsageDayDownload ?? fallback.networkDataUsageDayDownload
    latest.networkDataUsageDayUpload =
      latest.networkDataUsageDayUpload ?? fallback.networkDataUsageDayUpload
    latest.networkDataUsageWeekDownload =
      latest.networkDataUsageWeekDownload ?? fallback.networkDataUsageWeekDownload
    latest.networkDataUsageWeekUpload =
      latest.networkDataUsageWeekUpload ?? fallback.networkDataUsageWeekUpload
    latest.networkDataUsageMonthDownload =
      latest.networkDataUsageMonthDownload ?? fallback.networkDataUsageMonthDownload
    latest.networkDataUsageMonthUpload =
      latest.networkDataUsageMonthUpload ?? fallback.networkDataUsageMonthUpload

    if latest.busiestDevices.isEmpty {
      latest.busiestDevices = fallback.busiestDevices
    }
    if latest.busiestDeviceTimelines == nil || latest.busiestDeviceTimelines?.isEmpty == true {
      latest.busiestDeviceTimelines = fallback.busiestDeviceTimelines
    }

    return latest
  }

  private func mergedClients(latest: [EeroClient], fallback: [EeroClient]) -> [EeroClient] {
    guard !latest.isEmpty else {
      return fallback
    }
    guard !fallback.isEmpty else {
      return latest
    }

    let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
    let fallbackByMAC: [String: EeroClient] = Dictionary(
      uniqueKeysWithValues: fallback.compactMap { client in
        guard let normalized = normalizedMAC(client.mac) else { return nil }
        return (normalized, client)
      })

    return latest.map { client in
      var merged = client
      let stale =
        fallbackByID[client.id]
        ?? normalizedMAC(client.mac).flatMap { fallbackByMAC[$0] }

      guard let stale else {
        return merged
      }

      merged.mac = merged.mac ?? stale.mac
      merged.ip = merged.ip ?? stale.ip
      merged.connectionType = merged.connectionType ?? stale.connectionType
      merged.signal = merged.signal ?? stale.signal
      merged.signalAverage = merged.signalAverage ?? stale.signalAverage
      merged.scoreBars = merged.scoreBars ?? stale.scoreBars
      merged.channel = merged.channel ?? stale.channel
      merged.blacklisted = merged.blacklisted ?? stale.blacklisted
      merged.deviceType = merged.deviceType ?? stale.deviceType
      merged.manufacturer = merged.manufacturer ?? stale.manufacturer
      merged.lastActive = merged.lastActive ?? stale.lastActive
      merged.isPrivate = merged.isPrivate ?? stale.isPrivate
      merged.interfaceFrequency = merged.interfaceFrequency ?? stale.interfaceFrequency
      merged.interfaceFrequencyUnit = merged.interfaceFrequencyUnit ?? stale.interfaceFrequencyUnit
      merged.rxChannelWidth = merged.rxChannelWidth ?? stale.rxChannelWidth
      merged.txChannelWidth = merged.txChannelWidth ?? stale.txChannelWidth
      merged.rxRateMbps = merged.rxRateMbps ?? stale.rxRateMbps
      merged.txRateMbps = merged.txRateMbps ?? stale.txRateMbps
      merged.usageDownMbps = merged.usageDownMbps ?? stale.usageDownMbps
      merged.usageUpMbps = merged.usageUpMbps ?? stale.usageUpMbps
      merged.usageDownPercentCurrent =
        merged.usageDownPercentCurrent ?? stale.usageDownPercentCurrent
      merged.usageUpPercentCurrent = merged.usageUpPercentCurrent ?? stale.usageUpPercentCurrent
      merged.usageDayDownload = merged.usageDayDownload ?? stale.usageDayDownload
      merged.usageDayUpload = merged.usageDayUpload ?? stale.usageDayUpload
      merged.usageWeekDownload = merged.usageWeekDownload ?? stale.usageWeekDownload
      merged.usageWeekUpload = merged.usageWeekUpload ?? stale.usageWeekUpload
      merged.usageMonthDownload = merged.usageMonthDownload ?? stale.usageMonthDownload
      merged.usageMonthUpload = merged.usageMonthUpload ?? stale.usageMonthUpload
      merged.sourceLocation = merged.sourceLocation ?? stale.sourceLocation
      merged.sourceURL = merged.sourceURL ?? stale.sourceURL
      merged.resources = stale.resources.merging(
        merged.resources, uniquingKeysWith: { _, latestValue in latestValue })
      return merged
    }
  }

  private func mergedDevices(latest: [EeroDevice], fallback: [EeroDevice]) -> [EeroDevice] {
    guard !latest.isEmpty else {
      return fallback
    }
    guard !fallback.isEmpty else {
      return latest
    }

    let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
    let fallbackByMAC: [String: EeroDevice] = Dictionary(
      uniqueKeysWithValues: fallback.compactMap { device in
        guard let normalized = normalizedMAC(device.macAddress) else { return nil }
        return (normalized, device)
      })

    return latest.map { device in
      var merged = device
      let stale =
        fallbackByID[device.id]
        ?? normalizedMAC(device.macAddress).flatMap { fallbackByMAC[$0] }

      guard let stale else {
        return merged
      }

      merged.model = merged.model ?? stale.model
      merged.modelNumber = merged.modelNumber ?? stale.modelNumber
      merged.serial = merged.serial ?? stale.serial
      merged.macAddress = merged.macAddress ?? stale.macAddress
      merged.status = merged.status ?? stale.status
      merged.statusLightEnabled = merged.statusLightEnabled ?? stale.statusLightEnabled
      merged.statusLightBrightness = merged.statusLightBrightness ?? stale.statusLightBrightness
      merged.updateAvailable = merged.updateAvailable ?? stale.updateAvailable
      merged.ipAddress = merged.ipAddress ?? stale.ipAddress
      merged.osVersion = merged.osVersion ?? stale.osVersion
      merged.lastRebootAt = merged.lastRebootAt ?? stale.lastRebootAt
      merged.connectedClientCount = merged.connectedClientCount ?? stale.connectedClientCount
      merged.connectedClientNames = merged.connectedClientNames ?? stale.connectedClientNames
      merged.connectedWiredClientCount =
        merged.connectedWiredClientCount ?? stale.connectedWiredClientCount
      merged.connectedWirelessClientCount =
        merged.connectedWirelessClientCount ?? stale.connectedWirelessClientCount
      merged.meshQualityBars = merged.meshQualityBars ?? stale.meshQualityBars
      merged.wiredBackhaul = merged.wiredBackhaul ?? stale.wiredBackhaul
      if merged.wifiBands.isEmpty {
        merged.wifiBands = stale.wifiBands
      }
      if merged.portDetails.isEmpty {
        merged.portDetails = stale.portDetails
      }
      merged.ethernetStatuses = mergedEthernetStatuses(
        latest: merged.ethernetStatuses, fallback: stale.ethernetStatuses)
      merged.wirelessAttachments = merged.wirelessAttachments ?? stale.wirelessAttachments
      merged.usageDayDownload = merged.usageDayDownload ?? stale.usageDayDownload
      merged.usageDayUpload = merged.usageDayUpload ?? stale.usageDayUpload
      merged.usageWeekDownload = merged.usageWeekDownload ?? stale.usageWeekDownload
      merged.usageWeekUpload = merged.usageWeekUpload ?? stale.usageWeekUpload
      merged.usageMonthDownload = merged.usageMonthDownload ?? stale.usageMonthDownload
      merged.usageMonthUpload = merged.usageMonthUpload ?? stale.usageMonthUpload
      merged.supportExpired = merged.supportExpired ?? stale.supportExpired
      merged.supportExpirationString =
        merged.supportExpirationString ?? stale.supportExpirationString
      merged.resources = stale.resources.merging(
        merged.resources, uniquingKeysWith: { _, latestValue in latestValue })
      return merged
    }
  }

  private func mergedEthernetStatuses(
    latest: [EeroEthernetPortStatus],
    fallback: [EeroEthernetPortStatus]
  ) -> [EeroEthernetPortStatus] {
    guard !latest.isEmpty else {
      return fallback
    }
    guard !fallback.isEmpty else {
      return latest
    }

    var fallbackByKey: [String: EeroEthernetPortStatus] = [:]
    for status in fallback {
      for key in ethernetStatusLookupKeys(status) where fallbackByKey[key] == nil {
        fallbackByKey[key] = status
      }
    }

    var consumedKeys: Set<String> = []
    var merged: [EeroEthernetPortStatus] = []
    merged.reserveCapacity(max(latest.count, fallback.count))

    for status in latest {
      var enriched = status
      let keys = ethernetStatusLookupKeys(status)
      let stale = keys.compactMap { fallbackByKey[$0] }.first
      if let stale {
        enriched.portName = enriched.portName ?? stale.portName
        enriched.hasCarrier = enriched.hasCarrier ?? stale.hasCarrier
        enriched.isWanPort = enriched.isWanPort ?? stale.isWanPort
        enriched.speedTag = enriched.speedTag ?? stale.speedTag
        enriched.peerCount = enriched.peerCount ?? stale.peerCount
        enriched.powerSaving = enriched.powerSaving ?? stale.powerSaving
        enriched.originalSpeed = enriched.originalSpeed ?? stale.originalSpeed
        enriched.neighborName = enriched.neighborName ?? stale.neighborName
        enriched.neighborURL = enriched.neighborURL ?? stale.neighborURL
        enriched.neighborPortName = enriched.neighborPortName ?? stale.neighborPortName
        enriched.neighborPort = enriched.neighborPort ?? stale.neighborPort
        enriched.connectionKind = enriched.connectionKind ?? stale.connectionKind
        enriched.connectionType = enriched.connectionType ?? stale.connectionType
      }

      consumedKeys.formUnion(keys)
      merged.append(enriched)
    }

    for status in fallback {
      let keys = ethernetStatusLookupKeys(status)
      if keys.contains(where: consumedKeys.contains) {
        continue
      }
      merged.append(status)
    }

    return merged
  }

  private func ethernetStatusLookupKeys(_ status: EeroEthernetPortStatus) -> [String] {
    var keys: [String] = []
    if let interfaceNumber = status.interfaceNumber {
      keys.append("if:\(interfaceNumber)")
    }
    if let normalizedPort = normalizedToken(status.portName) {
      keys.append("port:\(normalizedPort)")
    }
    return keys
  }

  private func normalizedMAC(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let token =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ":", with: "")
    return token.isEmpty ? nil : token
  }

  private func normalizedToken(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    let lowered = value.lowercased()
    let scalarSet = CharacterSet.alphanumerics
    let compact = String(lowered.unicodeScalars.filter { scalarSet.contains($0) })
    return compact.isEmpty ? lowered : compact
  }

  private func startLocalThroughputMonitoring() {
    guard throughputTask == nil else { return }

    throughputTask = Task.detached(priority: .utility) { [weak self] in
      var routeInterfaceName: String?
      var lastRouteProbeAt: Date = .distantPast
      var previousCounters: (timestamp: Date, inBytes: UInt64, outBytes: UInt64)?
      var smoothedDownRate: Double?
      var smoothedUpRate: Double?

      while !Task.isCancelled {
        let now = Date()
        if routeInterfaceName == nil || now.timeIntervalSince(lastRouteProbeAt) >= 15 {
          let detected = Self.detectDefaultRouteInterface()
          if detected != routeInterfaceName {
            routeInterfaceName = detected
            previousCounters = nil
            smoothedDownRate = nil
            smoothedUpRate = nil
          }
          lastRouteProbeAt = now
        }

        guard let interfaceName = routeInterfaceName,
          let counters = Self.readInterfaceCounters(interfaceName: interfaceName)
        else {
          await MainActor.run {
            self?.throughputStore.publish(nil)
          }
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          continue
        }

        defer { previousCounters = counters }

        guard let previous = previousCounters else {
          await MainActor.run {
            self?.throughputStore.publish(nil)
          }
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          continue
        }

        guard counters.inBytes >= previous.inBytes,
          counters.outBytes >= previous.outBytes
        else {
          await MainActor.run {
            self?.throughputStore.publish(nil)
          }
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          continue
        }

        let elapsed = max(0.001, counters.timestamp.timeIntervalSince(previous.timestamp))
        let rawDownRate = Double(counters.inBytes - previous.inBytes) / elapsed
        let rawUpRate = Double(counters.outBytes - previous.outBytes) / elapsed
        let downRate = smoothedDownRate.map { ($0 * 0.65) + (rawDownRate * 0.35) } ?? rawDownRate
        let upRate = smoothedUpRate.map { ($0 * 0.65) + (rawUpRate * 0.35) } ?? rawUpRate
        smoothedDownRate = downRate
        smoothedUpRate = upRate

        let snapshot = LocalThroughputSnapshot(
          interfaceName: interfaceName,
          downBytesPerSecond: downRate,
          upBytesPerSecond: upRate,
          sampledAt: counters.timestamp
        )

        await MainActor.run {
          self?.throughputStore.publish(snapshot)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  nonisolated private static func detectDefaultRouteInterface() -> String? {
    let result = ShellCommand.run(executable: "/sbin/route", arguments: ["-n", "get", "default"])
    guard result.succeeded else { return nil }
    return extractRouteValue(prefix: "interface:", from: result.stdout)
  }

  nonisolated private static func extractRouteValue(prefix: String, from output: String) -> String?
  {
    for line in output.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix(prefix) {
        return trimmed.replacingOccurrences(of: prefix, with: "").trimmingCharacters(
          in: .whitespaces)
      }
    }
    return nil
  }

  nonisolated private static func readInterfaceCounters(interfaceName: String) -> (
    timestamp: Date, inBytes: UInt64, outBytes: UInt64
  )? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }

    var pointer = first
    while true {
      let iface = pointer.pointee
      let name = String(cString: iface.ifa_name)
      if name == interfaceName, let data = iface.ifa_data {
        let networkData = data.assumingMemoryBound(to: if_data.self).pointee
        return (Date(), UInt64(networkData.ifi_ibytes), UInt64(networkData.ifi_obytes))
      }
      guard let next = iface.ifa_next else { break }
      pointer = next
    }

    return nil
  }
}
