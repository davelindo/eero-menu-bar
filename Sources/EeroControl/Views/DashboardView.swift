import Charts
import SwiftUI

private enum UsageWindow: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }
}

private struct ThroughputPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let downloadMbps: Double
    let uploadMbps: Double
    let sourceLabel: String
    let contextLabel: String
}

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState

    @State private var usageWindow: UsageWindow = .day
    @State private var throughputHistory: [ThroughputPoint] = []
    @State private var selectedTimelineID: String?

    private let cardColumns = [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)]
    private let historyRetentionSeconds: TimeInterval = 900
    private let maxHistorySamples: Int = 300

    private var selectedNetwork: EeroNetwork? {
        appState.selectedNetwork
    }

    private var latestThroughput: ThroughputPoint? {
        throughputHistory.last
    }

    private var chartYMax: Double {
        let maximum = throughputHistory
            .flatMap { [$0.downloadMbps, $0.uploadMbps] }
            .max() ?? 0
        return max(10, maximum * 1.25)
    }

    private var chartDomain: ClosedRange<Date> {
        let now = Date()
        guard let first = throughputHistory.first?.timestamp,
              let last = throughputHistory.last?.timestamp else {
            return now.addingTimeInterval(-60) ... now
        }

        if abs(last.timeIntervalSince(first)) < 1 {
            return first.addingTimeInterval(-60) ... last.addingTimeInterval(1)
        }

        return first ... last
    }

    private var pendingQueueCount: Int {
        appState.queuedActions.filter { $0.status == .pending }.count
    }

    private var failedQueueCount: Int {
        appState.queuedActions.filter { $0.status == .failed }.count
    }

    private var queueSummary: String {
        if pendingQueueCount == 0, failedQueueCount == 0 {
            return "No queued actions"
        }
        return "\(pendingQueueCount) pending · \(failedQueueCount) failed"
    }

    var body: some View {
        ScrollView {
            if let network = selectedNetwork {
                VStack(alignment: .leading, spacing: 12) {
                    networkPulseCard(network: network)

                    LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 12) {
                        throughputTimelineCard(network: network)
                        busiestDevicesCard(network: network)
                        meshAndRadiosCard(network: network)
                        routerPortsCard(network: network)
                        controlCenterCard(network: network)
                        operationsCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            } else {
                SectionCard(title: "Dashboard") {
                    Text("No network selected")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            rebuildHistoryFromCurrentState(reset: true)
        }
        .onChange(of: appState.selectedNetworkID) { _ in
            rebuildHistoryFromCurrentState(reset: true)
        }
        .onChange(of: selectedNetwork?.lastUpdated) { _ in
            rebuildHistoryFromCurrentState(reset: false)
        }
    }

    private func networkPulseCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Network Pulse") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .top)], spacing: 8) {
                pulseTile(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Status",
                    value: network.status ?? "Unknown",
                    detail: network.displayName,
                    tone: toneForText(network.status)
                )

                pulseTile(
                    icon: "person.3.fill",
                    title: "Clients Online",
                    value: "\(network.connectedClientsCount)",
                    detail: "Guest: \(network.connectedGuestClientsCount)",
                    tone: .success
                )

                pulseTile(
                    icon: "wifi",
                    title: "Guest LAN",
                    value: network.guestNetworkEnabled ? "Enabled" : "Disabled",
                    detail: network.guestNetworkName ?? "Guest network",
                    tone: network.guestNetworkEnabled ? .accent : .neutral
                )

                pulseTile(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Mesh",
                    value: "\(network.mesh?.onlineEeroCount ?? 0)/\(network.mesh?.eeroCount ?? max(1, network.devices.count)) online",
                    detail: network.mesh?.gatewayName ?? "Gateway unknown",
                    tone: (network.mesh?.onlineEeroCount ?? 0) > 0 ? .success : .warning
                )

                pulseTile(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Last Speed Test",
                    value: speedPairText(network),
                    detail: network.speed.measuredAt ?? "No sample",
                    tone: .accent
                )
            }
        }
    }

    private func throughputTimelineCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Traffic Timeline") {
            if throughputHistory.count > 1 {
                Chart {
                    ForEach(throughputHistory) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Download", point.downloadMbps)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Upload", point.uploadMbps)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXScale(domain: chartDomain)
                .chartYScale(domain: 0 ... chartYMax)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
            } else {
                Label("No eero realtime telemetry in this refresh.", systemImage: "waveform.path.ecg")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                metricPill(icon: "arrow.down", label: "Download", value: latestThroughput.map { formatMbps($0.downloadMbps) } ?? "--", tone: .success)
                metricPill(icon: "arrow.up", label: "Upload", value: latestThroughput.map { formatMbps($0.uploadMbps) } ?? "--", tone: .accent)
            }

            Text(latestThroughput?.sourceLabel ?? "Source: \(network.realtime?.sourceLabel ?? "Unavailable")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(latestThroughput?.contextLabel ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func busiestDevicesCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Busiest Devices") {
            let entries = usageEntries(for: network, window: usageWindow)
            let timelines = (network.activity?.busiestDeviceTimelines ?? []).filter { !$0.samples.isEmpty }
            let activeTimeline = timelines.first(where: { $0.id == selectedTimelineID }) ?? timelines.first

            Picker("Usage Window", selection: $usageWindow) {
                ForEach(UsageWindow.allCases) { window in
                    Text(window.rawValue).tag(window)
                }
            }
            .pickerStyle(.segmented)

            if let activeTimeline {
                if timelines.count > 1 {
                    Picker("Timeline Device", selection: Binding(
                        get: { activeTimeline.id },
                        set: { selectedTimelineID = $0 }
                    )) {
                        ForEach(timelines) { timeline in
                            Text(timeline.name).tag(timeline.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Chart {
                    ForEach(activeTimeline.samples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Download", Double(max(0, sample.downloadBytes)))
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Upload", Double(max(0, sample.uploadBytes)))
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartYScale(domain: 0 ... timelineYMax(for: activeTimeline.samples))
                .chartXScale(domain: timelineDomain(for: activeTimeline.samples))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let byteValue = value.as(Double.self) {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(byteValue), countStyle: .binary))
                            }
                        }
                    }
                }
                .frame(height: 170)

                Text("24-hour usage timeline for \(activeTimeline.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if entries.isEmpty {
                Text("No per-device usage telemetry available yet for this network.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(6)) { entry in
                    infoRow(
                        icon: "desktopcomputer",
                        label: entry.label,
                        value: "↓\(formattedByteCount(entry.downloadBytes)) ↑\(formattedByteCount(entry.uploadBytes))",
                        tone: .neutral
                    )
                }
            }
        }
    }

    private func meshAndRadiosCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Mesh and Radio Analytics") {
            if let mesh = network.mesh {
                infoRow(icon: "point.3.connected.trianglepath.dotted", label: "eero Nodes", value: "\(mesh.onlineEeroCount)/\(mesh.eeroCount) online", tone: .neutral)
                infoRow(icon: "house.fill", label: "Gateway", value: mesh.gatewayName ?? "Unknown", tone: .neutral)
                infoRow(icon: "arrow.left.arrow.right", label: "Backhaul", value: "Wired \(mesh.wiredBackhaulCount) · Wireless \(mesh.wirelessBackhaulCount)", tone: .neutral)
                infoRow(icon: "dot.scope", label: "Mesh Quality", value: mesh.averageMeshQualityBars.map { String(format: "%.1f / 4", $0) } ?? "Unknown", tone: .accent)
            }

            if let proxied = network.proxiedNodes {
                infoRow(icon: "wifi.exclamationmark", label: "Proxied Nodes", value: "\(proxied.onlineDevices)/\(proxied.totalDevices) online", tone: proxied.offlineDevices > 0 ? .warning : .success)
            }

            if let radios = network.channelUtilization?.radios, !radios.isEmpty {
                if let primaryRadio = radios.first, !primaryRadio.timeSeries.isEmpty {
                    Chart {
                        ForEach(primaryRadio.timeSeries) { sample in
                            LineMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("Busy", sample.busyPercent ?? 0)
                            )
                            .foregroundStyle(.orange)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYScale(domain: 0 ... 100)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisTick()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .frame(height: 120)

                    Text("Focused radio: \(radioLabel(primaryRadio))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ForEach(radios.prefix(6)) { radio in
                    infoRow(
                        icon: "wave.3.right",
                        label: radioLabel(radio),
                        value: "Avg \(radio.averageUtilization.map { "\($0)%" } ?? "--") · Max \(radio.maxUtilization.map { "\($0)%" } ?? "--")",
                        tone: (radio.averageUtilization ?? 0) >= 70 ? .warning : .neutral
                    )
                }
            } else if let congestion = network.wirelessCongestion {
                infoRow(icon: "wifi", label: "Wireless Clients", value: "\(congestion.wirelessClientCount)", tone: .neutral)
                infoRow(icon: "antenna.radiowaves.left.and.right", label: "Poor Signal", value: "\(congestion.poorSignalClientCount)", tone: congestion.poorSignalClientCount > 0 ? .warning : .success)
                ForEach(congestion.congestedChannels.prefix(6)) { channel in
                    infoRow(
                        icon: "dot.radiowaves.left.and.right",
                        label: "CH \(channel.channel.map(String.init) ?? "?") · \(channel.band ?? "Unknown")",
                        value: "\(channel.clientCount) weighted load",
                        tone: .neutral
                    )
                }
            } else {
                Text("No radio analytics available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func routerPortsCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Router and Port Stats") {
            if network.devices.isEmpty {
                Text("No eero node details available for this network.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(network.devices) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: device.isGateway ? "house.fill" : "router")
                                .foregroundStyle(device.isGateway ? Color.blue : Color.secondary)
                            Text(device.name)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(device.status ?? "Unknown")
                                .font(.caption)
                                .foregroundStyle(toneForText(device.status).foregroundColor)
                        }

                        infoRow(icon: "person.2.fill", label: "Connected Clients", value: "Total \(device.connectedClientCount ?? 0) · Wired \(device.connectedWiredClientCount ?? 0) · Wireless \(device.connectedWirelessClientCount ?? 0)", tone: .neutral)
                        infoRow(icon: "arrow.left.arrow.right", label: "Backhaul", value: device.wiredBackhaul == true ? "Wired" : (device.wiredBackhaul == false ? "Wireless" : "Unknown"), tone: device.wiredBackhaul == true ? .success : .neutral)
                        infoRow(icon: "wifi", label: "Radio Bands", value: device.wifiBands.isEmpty ? "Unknown" : device.wifiBands.joined(separator: ", "), tone: .neutral)

                        if !device.ethernetStatuses.isEmpty {
                            ForEach(device.ethernetStatuses.prefix(5)) { status in
                                infoRow(
                                    icon: (status.hasCarrier == true) ? "cable.connector" : "cable.connector.slash",
                                    label: status.portName ?? "Port \(status.interfaceNumber.map(String.init) ?? "?")",
                                    value: "\(status.speedTag ?? "speed n/a") · \(status.neighborName ?? "No peer")",
                                    tone: status.hasCarrier == true ? .success : .neutral
                                )
                            }
                        } else if !device.portDetails.isEmpty {
                            ForEach(device.portDetails.prefix(5)) { detail in
                                infoRow(
                                    icon: "cable.connector",
                                    label: detail.portName ?? "Port \(detail.position.map(String.init) ?? "?")",
                                    value: detail.ethernetAddress ?? "No ethernet address",
                                    tone: .neutral
                                )
                            }
                        }

                        if device.id != network.devices.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func controlCenterCard(network: EeroNetwork) -> some View {
        SectionCard(title: "Control Center") {
            controlToggleRow(
                icon: "wifi",
                title: "Guest Network",
                subtitle: network.guestNetworkName ?? "Guest LAN",
                isOn: Binding(
                    get: { network.guestNetworkEnabled },
                    set: { appState.setGuestNetwork(network: network, enabled: $0) }
                ),
                tone: network.guestNetworkEnabled ? .accent : .neutral
            )

            if let adBlock = network.features.adBlock {
                controlToggleRow(
                    icon: "shield.lefthalf.filled",
                    title: "Ad Blocking",
                    subtitle: "DNS policy",
                    isOn: Binding(
                        get: { adBlock },
                        set: { appState.setNetworkFeature(network: network, key: "ad_block", enabled: $0) }
                    ),
                    tone: adBlock ? .success : .neutral
                )
            }

            if let malware = network.features.blockMalware {
                controlToggleRow(
                    icon: "ant.fill",
                    title: "Malware Blocking",
                    subtitle: "DNS policy",
                    isOn: Binding(
                        get: { malware },
                        set: { appState.setNetworkFeature(network: network, key: "block_malware", enabled: $0) }
                    ),
                    tone: malware ? .success : .neutral
                )
            }

            if let upnp = network.features.upnp {
                controlToggleRow(
                    icon: "link.badge.plus",
                    title: "UPnP",
                    subtitle: "Port mapping",
                    isOn: Binding(
                        get: { upnp },
                        set: { appState.setNetworkFeature(network: network, key: "upnp", enabled: $0) }
                    ),
                    tone: upnp ? .accent : .neutral
                )
            }
        }
    }

    private var operationsCard: some View {
        SectionCard(title: "Operations") {
            if let freshness = appState.cachedFreshness {
                infoRow(
                    icon: "clock.fill",
                    label: "Data Age",
                    value: formatAge(freshness.age),
                    tone: freshness.age < 30 ? .success : .warning
                )
            } else {
                infoRow(icon: "clock.fill", label: "Data Age", value: "No cache", tone: .warning)
            }

            infoRow(
                icon: "clock.arrow.circlepath",
                label: "Queue",
                value: queueSummary,
                tone: failedQueueCount > 0 ? .danger : (pendingQueueCount > 0 ? .warning : .success)
            )

            HStack(spacing: 8) {
                Button("Replay Queue") {
                    appState.replayQueuedActions()
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh") {
                    appState.refreshNow()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func pulseTile(icon: String, title: String, value: String, detail: String, tone: AppTone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.foregroundColor)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Circle()
                    .fill(tone.foregroundColor)
                    .frame(width: 7, height: 7)
                    .opacity(tone == .neutral ? 0.5 : 0.95)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .monospacedDigit()

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tone.backgroundColor.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func metricPill(icon: String, label: String, value: String, tone: AppTone) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(tone.foregroundColor)
        .background(tone.backgroundColor.opacity(0.8), in: Capsule())
    }

    private func controlToggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>, tone: AppTone) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tone.backgroundColor.opacity(0.6))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.foregroundColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }

    private func infoRow(icon: String, label: String, value: String, tone: AppTone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone.foregroundColor)
                .frame(width: 16)

            Text(label)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tone.foregroundColor)
        }
        .font(.callout)
    }

    private func usageEntries(for network: EeroNetwork, window: UsageWindow) -> [UsageEntry] {
        let devices = network.activity?.busiestDevices ?? []

        return devices.compactMap { device in
            let (download, upload): (Int, Int)
            switch window {
            case .day:
                download = max(0, device.dayDownloadBytes ?? 0)
                upload = max(0, device.dayUploadBytes ?? 0)
            case .week:
                download = max(0, device.weekDownloadBytes ?? 0)
                upload = max(0, device.weekUploadBytes ?? 0)
            case .month:
                download = max(0, device.monthDownloadBytes ?? 0)
                upload = max(0, device.monthUploadBytes ?? 0)
            }

            guard download > 0 || upload > 0 else {
                return nil
            }

            let label = device.name.isEmpty ? (device.macAddress ?? "Unknown") : device.name
            return UsageEntry(id: device.id, label: label, downloadBytes: download, uploadBytes: upload)
        }
    }

    private func rebuildHistoryFromCurrentState(reset: Bool) {
        if reset {
            throughputHistory.removeAll()
        }

        if let realtime = selectedNetwork?.realtime {
            appendRealtimeThroughputSample(realtime, network: selectedNetwork)
            return
        }
    }

    private func appendRealtimeThroughputSample(_ realtime: NetworkRealtimeSummary, network: EeroNetwork?) {
        let context = network.map { "\($0.connectedClientsCount) online clients" } ?? "Network sample"
        let point = ThroughputPoint(
            timestamp: realtime.sampledAt,
            downloadMbps: max(0, realtime.downloadMbps),
            uploadMbps: max(0, realtime.uploadMbps),
            sourceLabel: "Source: \(realtime.sourceLabel)",
            contextLabel: context
        )
        appendPoint(point)
    }

    private func appendPoint(_ point: ThroughputPoint) {
        if let last = throughputHistory.last,
           abs(point.timestamp.timeIntervalSince(last.timestamp)) < 0.9 {
            throughputHistory[throughputHistory.count - 1] = point
        } else {
            throughputHistory.append(point)
        }

        let cutoff = Date().addingTimeInterval(-historyRetentionSeconds)
        throughputHistory.removeAll { $0.timestamp < cutoff }

        if throughputHistory.count > maxHistorySamples {
            throughputHistory.removeFirst(throughputHistory.count - maxHistorySamples)
        }
    }

    private func radioLabel(_ radio: ChannelUtilizationRadio) -> String {
        let node = radio.eeroName ?? radio.eeroID ?? "eero"
        let band = radio.band ?? "band"
        let channel = radio.controlChannel.map(String.init) ?? "?"
        return "\(node) · \(band) · CH \(channel)"
    }

    private func realtimePairText(_ network: EeroNetwork) -> String {
        if let realtime = network.realtime {
            return "↓\(formatMbps(realtime.downloadMbps)) ↑\(formatMbps(realtime.uploadMbps))"
        }
        return "Unavailable"
    }

    private func realtimeSourceText(_ network: EeroNetwork) -> String {
        if let realtime = network.realtime {
            return realtime.sourceLabel
        }
        return "No realtime source"
    }

    private func timelineYMax(for samples: [DeviceUsageTimelineSample]) -> Double {
        let maximum = samples
            .flatMap { [Double($0.downloadBytes), Double($0.uploadBytes)] }
            .max() ?? 0
        return max(1, maximum * 1.25)
    }

    private func timelineDomain(for samples: [DeviceUsageTimelineSample]) -> ClosedRange<Date> {
        let now = Date()
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else {
            return now.addingTimeInterval(-86_400) ... now
        }
        if abs(last.timeIntervalSince(first)) < 1 {
            return first.addingTimeInterval(-3_600) ... last.addingTimeInterval(1)
        }
        return first ... last
    }

    private func speedPairText(_ network: EeroNetwork) -> String {
        "\(formatSpeed(network.speed.measuredDownValue))/\(formatSpeed(network.speed.measuredUpValue))"
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        }
        if seconds < 3_600 {
            return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
        }
        return "\(Int(seconds / 3_600))h \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60))m"
    }

    private func formattedByteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .binary)
    }

    private func formatSpeed(_ value: Double?) -> String {
        guard let value else { return "?" }
        return String(format: "%.1f", value)
    }

    private func formatMbps(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f Mbps", value)
        }
        if value >= 10 {
            return String(format: "%.1f Mbps", value)
        }
        return String(format: "%.2f Mbps", value)
    }

    private func toneForLanStatus() -> AppTone {
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

    private func toneForCloudStatus() -> AppTone {
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

private struct UsageEntry: Identifiable {
    let id: String
    let label: String
    let downloadBytes: Int
    let uploadBytes: Int
}
