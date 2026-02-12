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
        let action = EeroAction(
            kind: .setGuestNetwork,
            networkID: network.id,
            endpoint: "/2.2/networks/\(network.id)/guestnetwork",
            method: .put,
            payload: ["enabled": .bool(enabled)],
            label: "Set Guest Network to \(enabled ? "On" : "Off") for \(network.displayName)",
            riskLevel: .low,
            queueEligible: true
        )
        submitAction(action)
    }

    func setNetworkFeature(network: EeroNetwork, key: String, enabled: Bool) {
        let action: EeroAction

        switch key {
        case "thread_enabled":
            let base = network.resources["thread"] ?? "/2.2/networks/\(network.id)/thread"
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
                endpoint: "/2.2/networks/\(network.id)/dns_policies/adblock",
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
                endpoint: "/2.2/networks/\(network.id)/dns_policies/network",
                method: .post,
                payload: ["block_malware": .bool(enabled)],
                label: "Set Malware Blocking to \(enabled ? "On" : "Off")",
                riskLevel: .moderate,
                queueEligible: true
            )
        default:
            let settingsURL = network.resources["settings"] ?? "/2.2/networks/\(network.id)/settings"
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

        let action = EeroAction(
            kind: .setClientPaused,
            networkID: network.id,
            targetID: client.id,
            endpoint: "/2.3/networks/\(network.id)/devices/\(mac)",
            method: .put,
            payload: ["paused": .bool(paused)],
            label: "\(paused ? "Pause" : "Resume") client \(client.name)",
            riskLevel: .low,
            queueEligible: true
        )

        submitAction(action)
    }

    func setProfilePaused(network: EeroNetwork, profile: EeroProfile, paused: Bool) {
        let action = EeroAction(
            kind: .setProfilePaused,
            networkID: network.id,
            targetID: profile.id,
            endpoint: "/2.2/networks/\(network.id)/profiles/\(profile.id)",
            method: .put,
            payload: ["paused": .bool(paused)],
            label: "\(paused ? "Pause" : "Resume") profile \(profile.name)",
            riskLevel: .low,
            queueEligible: true
        )

        submitAction(action)
    }

    func setProfileFilter(network: EeroNetwork, profile: EeroProfile, key: String, enabled: Bool) {
        let action = EeroAction(
            kind: .setProfileContentFilter,
            networkID: network.id,
            targetID: profile.id,
            endpoint: "/2.2/networks/\(network.id)/dns_policies/profiles/\(profile.id)",
            method: .post,
            payload: [key: .bool(enabled)],
            label: "Set \(profile.name) filter \(key) to \(enabled ? "On" : "Off")",
            riskLevel: .moderate,
            queueEligible: true
        )

        submitAction(action)
    }

    func setProfileBlockedApps(network: EeroNetwork, profile: EeroProfile, apps: [String]) {
        let normalized = apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let action = EeroAction(
            kind: .setProfileBlockedApps,
            networkID: network.id,
            targetID: profile.id,
            endpoint: "/2.2/networks/\(network.id)/dns_policies/profiles/\(profile.id)/applications/blocked",
            method: .put,
            payload: ["applications": .array(normalized.map(JSONValue.string))],
            label: "Update blocked apps for \(profile.name)",
            riskLevel: .moderate,
            queueEligible: true
        )

        submitAction(action)
    }

    func setDeviceStatusLight(network: EeroNetwork, device: EeroDevice, enabled: Bool) {
        let endpoint = device.resources["led_action"] ?? "/2.2/eeros/\(device.id)/led"
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
        let endpoint = device.resources["reboot"] ?? "/2.2/eeros/\(device.id)/reboot"
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
        let endpoint = network.resources["reboot"] ?? "/2.2/networks/\(network.id)/reboot"
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
        let endpoint = network.resources["speedtest"] ?? "/2.2/networks/\(network.id)/speedtest"
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
        let endpoint = network.resources["burst_reporters"] ?? "/2.2/networks/\(network.id)/burst_reporters"
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
            accountSnapshot = snapshot
            cachedFreshness = CachedDataFreshness(fetchedAt: snapshot.fetchedAt)
            if selectedNetworkID == nil {
                selectedNetworkID = snapshot.networks.first?.id
            }
            offlineStateStore.save(snapshot)

            cloudState = .reachable
            lastErrorMessage = nil

            await actionExecutor.replayQueuedActions()
            await refreshQueuedActions()
        } catch {
            cloudState = .unreachable
            lastErrorMessage = "\(reason.capitalized) refresh failed: \(error.localizedDescription)"

            if accountSnapshot == nil, let cached = offlineStateStore.load() {
                accountSnapshot = cached
                cachedFreshness = CachedDataFreshness(fetchedAt: cached.fetchedAt)
                selectedNetworkID = cached.networks.first?.id
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
                      let counters = Self.readInterfaceCounters(interfaceName: interfaceName) else {
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
                      counters.outBytes >= previous.outBytes else {
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

    nonisolated private static func extractRouteValue(prefix: String, from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return trimmed.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated private static func readInterfaceCounters(interfaceName: String) -> (timestamp: Date, inBytes: UInt64, outBytes: UInt64)? {
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
