import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var throughputStore: ThroughputStore

    private let gridColumns = [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)]

    private var selectedNetwork: EeroNetwork? {
        appState.selectedNetwork
    }

    private var realtimeThroughput: LocalThroughputSnapshot? {
        throughputStore.snapshot
    }

    var body: some View {
        ScrollView {
            if let selectedNetwork {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                    operationsCard(network: selectedNetwork)
                    featureControlsCard(network: selectedNetwork)
                    connectivityCard(network: selectedNetwork)
                    meshAndCongestionCard(network: selectedNetwork)
                    performanceAndUpdatesCard(network: selectedNetwork)
                    routingAndSecurityCard(network: selectedNetwork)
                    supportAndThreadCard(network: selectedNetwork)
                    devicesCard(network: selectedNetwork)
                }
                .padding(.top, 2)
            } else {
                SectionCard(title: "Network") {
                    Text("No network selected")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func operationsCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Operations") {
            Text("Use these actions for immediate network maintenance.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Run Speed Test") {
                    appState.runNetworkSpeedTest(network)
                }
                .buttonStyle(.bordered)

                Button("Run Burst Reporters") {
                    appState.runBurstReporters(network)
                }
                .buttonStyle(.bordered)

                Button("Reboot Network") {
                    appState.rebootNetwork(network)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func featureControlsCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Feature Controls") {
            featureControlRow(network: network, label: "Band Steering", key: "band_steering", value: network.features.bandSteering)
            featureControlRow(network: network, label: "UPnP", key: "upnp", value: network.features.upnp)
            featureControlRow(network: network, label: "WPA3", key: "wpa3", value: network.features.wpa3)
            featureControlRow(network: network, label: "Thread", key: "thread_enabled", value: network.features.threadEnabled)
            featureControlRow(network: network, label: "SQM", key: "sqm", value: network.features.sqm)
            featureControlRow(network: network, label: "IPv6 Upstream", key: "ipv6_upstream", value: network.features.ipv6Upstream)
            featureControlRow(network: network, label: "Ad Blocking", key: "ad_block", value: network.features.adBlock)
            featureControlRow(network: network, label: "Malware Blocking", key: "block_malware", value: network.features.blockMalware)
        }
    }

    private func connectivityCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Connectivity") {
            KeyValueRow(label: "Network Status", value: network.status ?? "Unknown", valueTone: toneForText(network.status))
            KeyValueRow(label: "LAN Status", value: appState.offlineSnapshot.localHealthLabel, valueTone: toneForLan())
            KeyValueRow(label: "Cloud State", value: appState.cloudState.rawValue.capitalized, valueTone: toneForCloud())
            KeyValueRow(label: "Internet", value: network.health.internetStatus ?? "Unknown", valueTone: toneForText(network.health.internetStatus))
            KeyValueRow(label: "Internet Up", value: boolLabel(network.health.internetUp))
            KeyValueRow(label: "Mesh Health", value: network.health.eeroNetworkStatus ?? "Unknown", valueTone: toneForText(network.health.eeroNetworkStatus))
            KeyValueRow(label: "Gateway IP", value: network.gatewayIP ?? network.mesh?.gatewayIP ?? "Unknown")
            KeyValueRow(label: "Guest Network", value: boolLabel(network.guestNetworkDetails?.enabled ?? network.guestNetworkEnabled))
            KeyValueRow(label: "Guest SSID", value: network.guestNetworkDetails?.name ?? network.guestNetworkName ?? "Unknown")
            KeyValueRow(label: "Backup Internet", value: boolLabel(network.backupInternetEnabled))
            KeyValueRow(label: "Diagnostics", value: network.diagnostics.status ?? "Unavailable", valueTone: toneForText(network.diagnostics.status))
        }
    }

    private func meshAndCongestionCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Mesh & Radio Analytics") {
            if let mesh = network.mesh {
                KeyValueRow(label: "eero Units Online", value: "\(mesh.onlineEeroCount)/\(mesh.eeroCount)")
                KeyValueRow(label: "Gateway Node", value: mesh.gatewayName ?? "Unknown")
                KeyValueRow(label: "Gateway MAC", value: mesh.gatewayMACAddress ?? "Unknown")
                KeyValueRow(label: "Mesh Quality", value: mesh.averageMeshQualityBars.map { String(format: "%.1f / 4", $0) } ?? "Unknown")
                KeyValueRow(label: "Backhaul", value: "Wired \(mesh.wiredBackhaulCount) · Wireless \(mesh.wirelessBackhaulCount)")
            } else {
                KeyValueRow(label: "eero Units", value: "\(network.devices.count)")
            }

            if let radios = network.channelUtilization?.radios, !radios.isEmpty {
                Divider()
                Text("Channel Utilization")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(radios.prefix(8)) { radio in
                    let label = "\(radio.eeroName ?? radio.eeroID ?? "eero") · \(radio.band ?? "band") · CH \(radio.controlChannel.map(String.init) ?? "?")"
                    let value = "Avg \(radio.averageUtilization.map { "\($0)%" } ?? "--") · Max \(radio.maxUtilization.map { "\($0)%" } ?? "--")"
                    KeyValueRow(
                        label: label,
                        value: value,
                        valueTone: (radio.averageUtilization ?? 0) >= 70 ? .warning : .neutral
                    )
                }
            } else if let congestion = network.wirelessCongestion {
                KeyValueRow(label: "Wireless Clients (sampled)", value: "\(congestion.wirelessClientCount)")
                KeyValueRow(label: "Poor Signal Clients (est.)", value: "\(congestion.poorSignalClientCount)", valueTone: congestion.poorSignalClientCount > 0 ? .warning : .success)
                KeyValueRow(label: "Avg Signal (sampled)", value: congestion.averageSignalDbm.map { String(format: "%.1f dBm", $0) } ?? "Unknown")
                KeyValueRow(label: "Avg Score Bars (sampled)", value: congestion.averageScoreBars.map { String(format: "%.1f / 4", $0) } ?? "Unknown")

                if !congestion.congestedChannels.isEmpty {
                    Divider()
                    Text("Busiest Client Channels (estimated)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(congestion.congestedChannels) { channel in
                        KeyValueRow(
                            label: "CH \(channel.channel.map(String.init) ?? "?") · \(channel.band ?? "Unknown")",
                            value: "\(channel.clientCount) clients · \(channel.averageSignalDbm.map { "\($0) dBm" } ?? "signal n/a")"
                        )
                    }
                }
            } else {
                KeyValueRow(label: "Wireless Load", value: "No channel analytics available")
            }

            if let proxied = network.proxiedNodes {
                Divider()
                KeyValueRow(label: "Proxied Nodes", value: "\(proxied.onlineDevices)/\(proxied.totalDevices) online")
                KeyValueRow(label: "Proxied Feature", value: boolLabel(proxied.enabled))
            }
        }
    }

    private func performanceAndUpdatesCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Performance & Updates") {
            if let realtime = network.realtime {
                KeyValueRow(
                    label: "Realtime Throughput",
                    value: "↓\(String(format: "%.1f", realtime.downloadMbps)) Mbps ↑\(String(format: "%.1f", realtime.uploadMbps)) Mbps",
                    valueTone: .success
                )
                KeyValueRow(label: "Telemetry Source", value: realtime.sourceLabel)
            } else {
                KeyValueRow(
                    label: "Realtime Throughput",
                    value: realtimeThroughput.map { "↓\($0.downDisplay) ↑\($0.upDisplay) (\($0.interfaceName))" } ?? "Unavailable",
                    valueTone: realtimeThroughput == nil ? .neutral : .warning
                )
                KeyValueRow(label: "Telemetry Source", value: "Fallback: Mac default-route interface")
            }
            KeyValueRow(label: "Last Download", value: formattedSpeed(value: network.speed.measuredDownValue, units: network.speed.measuredDownUnits))
            KeyValueRow(label: "Last Upload", value: formattedSpeed(value: network.speed.measuredUpValue, units: network.speed.measuredUpUnits))
            KeyValueRow(label: "Speed Test Sample", value: network.speed.measuredAt ?? "Unknown")
            KeyValueRow(label: "Target Firmware", value: network.updates.targetFirmware ?? "Unknown")
            KeyValueRow(label: "Has Update", value: boolLabel(network.updates.hasUpdate))
            KeyValueRow(label: "Can Update Now", value: boolLabel(network.updates.canUpdateNow))
            KeyValueRow(label: "Update Status", value: network.updates.updateStatus ?? "Unknown", valueTone: toneForText(network.updates.updateStatus))
            KeyValueRow(label: "Preferred Update Hour", value: network.updates.preferredUpdateHour.map(String.init) ?? "Unknown")

            if let activity = network.activity {
                Divider()
                KeyValueRow(label: "Data Usage Today", value: usagePair(download: activity.networkDataUsageDayDownload, upload: activity.networkDataUsageDayUpload))
                KeyValueRow(label: "Data Usage This Week", value: usagePair(download: activity.networkDataUsageWeekDownload, upload: activity.networkDataUsageWeekUpload))
                KeyValueRow(label: "Data Usage This Month", value: usagePair(download: activity.networkDataUsageMonthDownload, upload: activity.networkDataUsageMonthUpload))
                KeyValueRow(label: "Top Device Usage Entries", value: "\(activity.busiestDevices.count)")
            }
        }
    }

    private func routingAndSecurityCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Routing & Security") {
            KeyValueRow(label: "Reservations", value: "\(network.routing.reservationCount)")
            KeyValueRow(label: "Port Forwards", value: "\(network.routing.forwardCount)")
            KeyValueRow(label: "Pinholes", value: "\(network.routing.pinholeCount)")
            KeyValueRow(label: "Blacklisted Devices", value: "\(network.security.blacklistedDeviceCount)")
            KeyValueRow(label: "DDNS", value: network.ddns.subdomain ?? boolLabel(network.ddns.enabled))
            KeyValueRow(label: "AC Compatibility", value: network.acCompatibility.state ?? boolLabel(network.acCompatibility.enabled))
            KeyValueRow(label: "Insights", value: network.insights.available ? "Available" : "Unavailable")
        }
    }

    private func supportAndThreadCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Support & Thread") {
            KeyValueRow(label: "Provider", value: network.support.name ?? "eero")
            KeyValueRow(label: "Support Phone", value: network.support.supportPhone ?? "Unavailable")
            KeyValueRow(label: "Thread Enabled", value: boolLabel(network.features.threadEnabled))
            KeyValueRow(label: "Thread Name", value: network.threadDetails?.name ?? "Unknown")
            KeyValueRow(label: "Thread Channel", value: network.threadDetails?.channel.map(String.init) ?? "Unknown")
            KeyValueRow(label: "PAN ID", value: network.threadDetails?.panID ?? "Unknown")
            KeyValueRow(label: "XPAN ID", value: network.threadDetails?.xpanID ?? "Unknown")

            if let helpURL = network.support.helpURL,
               let url = URL(string: helpURL) {
                Link("Open Help Page", destination: url)
                    .font(.callout.weight(.semibold))
            }
        }
    }

    private func devicesCard(network: EeroNetwork) -> some View {
        SectionCard(title: "eero Devices") {
            if network.devices.isEmpty {
                Text("No eero devices reported for this network.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(network.devices) { device in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.callout.weight(.semibold))
                                Text(device.status ?? "Unknown")
                                    .font(.caption)
                                    .foregroundStyle(toneForText(device.status).foregroundColor)
                            }
                            Spacer()
                            if device.isGateway {
                                StatusChip(icon: "house.fill", text: "Gateway", tone: .accent)
                            }
                        }

                        HStack(spacing: 8) {
                            Button((device.statusLightEnabled ?? false) ? "Status Light Off" : "Status Light On") {
                                appState.setDeviceStatusLight(
                                    network: network,
                                    device: device,
                                    enabled: !(device.statusLightEnabled ?? false)
                                )
                            }
                            .buttonStyle(.bordered)

                            Button("Reboot Device") {
                                appState.rebootDevice(network: network, device: device)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        KeyValueRow(label: "IP Address", value: device.ipAddress ?? "Unknown")
                        KeyValueRow(label: "Model", value: [device.model, device.modelNumber].compactMap { $0 }.joined(separator: " · ").ifEmpty("Unknown"))
                        KeyValueRow(label: "OS Version", value: device.osVersion ?? "Unknown")
                        KeyValueRow(label: "MAC", value: device.macAddress ?? "Unknown")
                        KeyValueRow(label: "Last Reboot", value: device.lastRebootAt ?? "Unknown")
                        KeyValueRow(label: "Attached Clients", value: "\(device.connectedClientCount ?? 0)")
                        KeyValueRow(label: "Wired/Wireless Clients", value: "\(device.connectedWiredClientCount ?? 0)/\(device.connectedWirelessClientCount ?? 0)")
                        KeyValueRow(label: "Backhaul", value: device.wiredBackhaul == true ? "Wired" : (device.wiredBackhaul == false ? "Wireless" : "Unknown"))
                        KeyValueRow(label: "Mesh Quality", value: device.meshQualityBars.map { "\($0) / 4" } ?? "Unknown")
                        KeyValueRow(label: "Radio Bands", value: device.wifiBands.isEmpty ? "Unknown" : device.wifiBands.joined(separator: ", "))

                        if let names = device.connectedClientNames, !names.isEmpty {
                            KeyValueRow(label: "Client Names", value: names.joined(separator: ", "))
                        }

                        if !device.ethernetStatuses.isEmpty {
                            Divider()
                            Text("Ethernet Port Links")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(device.ethernetStatuses.prefix(6)) { status in
                                KeyValueRow(
                                    label: status.portName ?? "Port \(status.interfaceNumber.map(String.init) ?? "?")",
                                    value: "\(status.speedTag ?? "speed n/a") · \(status.neighborName ?? "No peer")",
                                    valueTone: status.hasCarrier == true ? .success : .neutral
                                )
                            }
                        }

                        if device.usageDayDownload != nil || device.usageDayUpload != nil {
                            KeyValueRow(label: "Usage Today", value: usagePair(download: device.usageDayDownload, upload: device.usageDayUpload))
                        }
                        if device.usageWeekDownload != nil || device.usageWeekUpload != nil {
                            KeyValueRow(label: "Usage This Week", value: usagePair(download: device.usageWeekDownload, upload: device.usageWeekUpload))
                        }
                        if device.usageMonthDownload != nil || device.usageMonthUpload != nil {
                            KeyValueRow(label: "Usage This Month", value: usagePair(download: device.usageMonthDownload, upload: device.usageMonthUpload))
                        }

                        if device.id != network.devices.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func featureControlRow(network: EeroNetwork, label: String, key: String, value: Bool?) -> some View {
        Group {
            if let value {
                Toggle(
                    label,
                    isOn: Binding(
                        get: { value },
                        set: { appState.setNetworkFeature(network: network, key: key, enabled: $0) }
                    )
                )
            } else {
                KeyValueRow(label: label, value: "Unavailable")
            }
        }
    }

    private func boolLabel(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Enabled" : "Disabled"
    }

    private func formattedSpeed(value: Double?, units: String?) -> String {
        guard let value else { return "Unknown" }
        let effectiveUnits = (units?.isEmpty == false) ? (units ?? "Mbps") : "Mbps"
        return String(format: "%.1f %@", value, effectiveUnits)
    }

    private func usagePair(download: Int?, upload: Int?) -> String {
        "↓\(formattedByteCount(download)) ↑\(formattedByteCount(upload))"
    }

    private func formattedByteCount(_ value: Int?) -> String {
        guard let value else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .binary)
    }

    private func toneForLan() -> AppTone {
        switch appState.offlineSnapshot.localHealthLabel {
        case "LAN OK":
            return .success
        case "LAN Degraded":
            return .warning
        case "LAN Down":
            return .danger
        default:
            return .neutral
        }
    }

    private func toneForCloud() -> AppTone {
        switch appState.cloudState {
        case .reachable:
            return .success
        case .degraded:
            return .warning
        case .unreachable:
            return .danger
        case .unknown:
            return .neutral
        }
    }

    private func toneForText(_ value: String?) -> AppTone {
        guard let value = value?.lowercased() else { return .neutral }
        if value.contains("connect") || value.contains("ok") || value.contains("up") || value.contains("enabled") || value.contains("available") {
            return .success
        }
        if value.contains("degraded") || value.contains("warn") {
            return .warning
        }
        if value.contains("down") || value.contains("fail") || value.contains("error") || value.contains("disable") {
            return .danger
        }
        return .neutral
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
