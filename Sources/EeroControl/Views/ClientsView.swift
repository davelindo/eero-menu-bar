import SwiftUI

private enum ClientScope: String, CaseIterable, Identifiable {
    case all = "All"
    case primary = "Primary LAN"
    case guest = "Guest LAN"

    var id: String { rawValue }
}

private struct ClientPresentationSnapshot {
    var filtered: [EeroClient]
    var primary: [EeroClient]
    var guest: [EeroClient]
    var primaryOnlineCount: Int
    var guestOnlineCount: Int
    var totalOnlineCount: Int

    static let empty = ClientPresentationSnapshot(
        filtered: [],
        primary: [],
        guest: [],
        primaryOnlineCount: 0,
        guestOnlineCount: 0,
        totalOnlineCount: 0
    )
}

private struct ClientPresentationToken: Equatable {
    var networkID: String?
    var networkLastUpdated: Date?
    var searchQuery: String
    var scope: ClientScope
    var onlineOnly: Bool
    var pausedOnly: Bool
    var blacklistedOnly: Bool
}

struct ClientsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var searchQuery: String = ""
    @State private var scope: ClientScope = .all
    @State private var onlineOnly: Bool = false
    @State private var pausedOnly: Bool = false
    @State private var blacklistedOnly: Bool = false
    @State private var selectedClientID: String?
    @State private var presentation = ClientPresentationSnapshot.empty

    private let listPanelMinWidth: CGFloat = 380
    private let listPanelMaxWidth: CGFloat = 470

    private var selectedNetwork: EeroNetwork? {
        appState.selectedNetwork
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var presentationToken: ClientPresentationToken {
        ClientPresentationToken(
            networkID: selectedNetwork?.id,
            networkLastUpdated: selectedNetwork?.lastUpdated,
            searchQuery: normalizedSearchQuery,
            scope: scope,
            onlineOnly: onlineOnly,
            pausedOnly: pausedOnly,
            blacklistedOnly: blacklistedOnly
        )
    }

    private var filteredClients: [EeroClient] {
        presentation.filtered
    }

    private var primaryClients: [EeroClient] {
        presentation.primary
    }

    private var guestClients: [EeroClient] {
        presentation.guest
    }

    private var selectedClient: EeroClient? {
        guard let selectedNetwork, let selectedClientID else { return nil }
        return selectedNetwork.clients.first(where: { $0.id == selectedClientID })
    }

    private var guestSectionVisible: Bool {
        guard let selectedNetwork else { return !guestClients.isEmpty }
        return selectedNetwork.guestNetworkEnabled || !guestClients.isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            searchAndFilterBar

            if let selectedNetwork {
                content(for: selectedNetwork)
            } else {
                SectionCard(title: "Clients") {
                    Text("No network selected")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            rebuildPresentation(resetSelection: true)
        }
        .onChange(of: appState.selectedNetworkID) { _ in
            rebuildPresentation(resetSelection: true)
        }
        .onChange(of: presentationToken) { _ in
            rebuildPresentation()
        }
    }

    private var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search name, IP, MAC, manufacturer, or type", text: $searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
            )

            Picker("Scope", selection: $scope) {
                ForEach(ClientScope.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            filterChip(title: "Online", enabled: onlineOnly) { onlineOnly.toggle() }
            filterChip(title: "Paused", enabled: pausedOnly) { pausedOnly.toggle() }
            filterChip(title: "Blacklisted", enabled: blacklistedOnly) { blacklistedOnly.toggle() }
        }
    }

    private func content(for network: EeroNetwork) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SectionCard(title: "Client Inventory") {
                inventorySummaryRow

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !primaryClients.isEmpty {
                            sectionHeader("Primary LAN · \(presentation.primaryOnlineCount)/\(primaryClients.count) online")
                            ForEach(primaryClients) { client in
                                clientListRow(client)
                            }
                        }

                        if guestSectionVisible {
                            sectionHeader(guestHeader(for: network))
                            if guestClients.isEmpty {
                                Text("No guest clients match the current filters.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(guestClients) { client in
                                    clientListRow(client)
                                }
                            }
                        }

                        if filteredClients.isEmpty {
                            Text("No clients match the current filters.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: listPanelMinWidth, idealWidth: 430, maxWidth: listPanelMaxWidth)
            .frame(maxHeight: .infinity, alignment: .top)

            SectionCard(title: "Client Inspector") {
                ScrollView {
                    if let selectedClient {
                        clientDetailView(network: network, client: selectedClient)
                    } else {
                        Text("Select a client from the inventory to inspect details and actions.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 440, maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var inventorySummaryRow: some View {
        HStack(spacing: 8) {
            StatusChip(
                icon: "cable.connector",
                text: "Primary \(presentation.primaryOnlineCount)/\(primaryClients.count)",
                tone: .neutral
            )

            if guestSectionVisible {
                StatusChip(
                    icon: "wifi",
                    text: "Guest \(presentation.guestOnlineCount)/\(guestClients.count)",
                    tone: .accent
                )
            }

            StatusChip(
                icon: "person.3.fill",
                text: "Total \(presentation.totalOnlineCount)/\(filteredClients.count)",
                tone: .success
            )
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func guestHeader(for network: EeroNetwork) -> String {
        let label = network.guestNetworkName.map { "Guest LAN (\($0))" } ?? "Guest LAN"
        return "\(label) · \(presentation.guestOnlineCount)/\(guestClients.count) online"
    }

    private func clientListRow(_ client: EeroClient) -> some View {
        Button {
            selectedClientID = client.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: client))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text([client.ip, client.mac, client.manufacturer, sourceLocationText(for: client)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(client.connected ? "Online" : "Offline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(client.connected ? .green : .secondary)

                    if client.paused {
                        Text("Paused")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedClientID == client.id ? Color.blue.opacity(0.2) : Color.primary.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    private func clientDetailView(network: EeroNetwork, client: EeroClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.name)
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 8) {
                        Text(client.connected ? "Online" : "Offline")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(client.connected ? .green : .secondary)
                        if client.paused {
                            Text("Paused")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                Button(client.paused ? "Resume Client" : "Pause Client") {
                    appState.setClientPaused(network: network, client: client, paused: !client.paused)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            KeyValueRow(label: "Segment", value: client.isGuest ? "Guest LAN" : "Primary LAN")
            KeyValueRow(label: "IP Address", value: client.ip ?? "Unknown")
            KeyValueRow(label: "MAC Address", value: client.mac ?? "Unknown")
            KeyValueRow(label: "Manufacturer", value: client.manufacturer ?? "Unknown")
            KeyValueRow(label: "Device Type", value: client.deviceType ?? "Unknown")
            KeyValueRow(label: "Connection", value: client.connectionType ?? "Unknown")
            KeyValueRow(label: "Connected To eero", value: sourceLocationText(for: client) ?? "Unknown")
            KeyValueRow(label: "Signal", value: signalText(for: client))
            KeyValueRow(label: "Channel", value: client.channel.map(String.init) ?? "Unknown")
            KeyValueRow(label: "Frequency", value: frequencyText(for: client))
            KeyValueRow(label: "Channel Width", value: channelWidthText(for: client))
            KeyValueRow(label: "RX/TX Rate", value: rateText(for: client))
            KeyValueRow(label: "Live Usage", value: usageText(for: client))
            KeyValueRow(label: "Private Address", value: boolLabel(client.isPrivate))
            KeyValueRow(label: "Last Active", value: client.lastActive ?? "Unknown")

            HStack(spacing: 8) {
                if client.isGuest {
                    StatusChip(icon: "wifi", text: "Guest", tone: .accent)
                } else {
                    StatusChip(icon: "cable.connector", text: "Primary", tone: .neutral)
                }

                if client.blacklisted == true {
                    StatusChip(icon: "hand.raised.fill", text: "Blacklisted", tone: .danger)
                }

                if client.paused {
                    StatusChip(icon: "pause.fill", text: "Paused", tone: .warning)
                }
            }
        }
    }

    private func filterChip(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(enabled ? Color.blue.opacity(0.25) : Color.primary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }

    private func searchableText(for client: EeroClient) -> String {
        [
            client.name,
            client.mac,
            client.ip,
            client.manufacturer,
            client.deviceType,
            client.sourceLocation
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func signalText(for client: EeroClient) -> String {
        if let signal = client.signal, !signal.isEmpty {
            return signal
        }
        if let average = client.signalAverage, !average.isEmpty {
            return average
        }
        return "Unknown"
    }

    private func frequencyText(for client: EeroClient) -> String {
        let value = client.interfaceFrequency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let unit = client.interfaceFrequencyUnit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let joined = [value, unit].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? "Unknown" : joined
    }

    private func channelWidthText(for client: EeroClient) -> String {
        let joined = [client.rxChannelWidth, client.txChannelWidth]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return joined.isEmpty ? "Unknown" : joined
    }

    private func boolLabel(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Yes" : "No"
    }

    private func sourceLocationText(for client: EeroClient) -> String? {
        guard let source = client.sourceLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            return nil
        }
        return source
    }

    private func rateText(for client: EeroClient) -> String {
        let rx = client.rxRateMbps.map { String(format: "%.1f Mbps", $0) } ?? "Unknown"
        let tx = client.txRateMbps.map { String(format: "%.1f Mbps", $0) } ?? "Unknown"
        return "↓\(rx) ↑\(tx)"
    }

    private func usageText(for client: EeroClient) -> String {
        let down = client.usageDownMbps.map { String(format: "%.1f Mbps", $0) } ?? "Unknown"
        let up = client.usageUpMbps.map { String(format: "%.1f Mbps", $0) } ?? "Unknown"
        return "↓\(down) ↑\(up)"
    }

    private func iconName(for client: EeroClient) -> String {
        if client.connectionType?.lowercased().contains("wireless") == true || client.wireless == true {
            return "wifi"
        }
        if client.connectionType?.lowercased().contains("ethernet") == true || client.wireless == false {
            return "cable.connector"
        }
        return "desktopcomputer"
    }

    private func rebuildPresentation(resetSelection: Bool = false) {
        guard let selectedNetwork else {
            presentation = .empty
            selectedClientID = nil
            return
        }

        let scopedClients: [EeroClient]
        switch scope {
        case .all:
            scopedClients = selectedNetwork.clients
        case .primary:
            scopedClients = selectedNetwork.clients.filter { !$0.isGuest }
        case .guest:
            scopedClients = selectedNetwork.clients.filter(\.isGuest)
        }

        let filtered = scopedClients.filter { client in
            if onlineOnly, !client.connected {
                return false
            }
            if pausedOnly, !client.paused {
                return false
            }
            if blacklistedOnly, client.blacklisted != true {
                return false
            }

            guard !normalizedSearchQuery.isEmpty else { return true }
            return searchableText(for: client).contains(normalizedSearchQuery)
        }

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.connected != rhs.connected {
                return lhs.connected && !rhs.connected
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let primary = sorted.filter { !$0.isGuest }
        let guest = sorted.filter(\.isGuest)
        presentation = ClientPresentationSnapshot(
            filtered: sorted,
            primary: primary,
            guest: guest,
            primaryOnlineCount: primary.filter(\.connected).count,
            guestOnlineCount: guest.filter(\.connected).count,
            totalOnlineCount: sorted.filter(\.connected).count
        )

        syncSelection(using: sorted.map(\.id), resetSelection: resetSelection)
    }

    private func syncSelection(using candidateIDs: [String], resetSelection: Bool = false) {
        if resetSelection {
            selectedClientID = candidateIDs.first
            return
        }

        guard let selectedClientID else {
            self.selectedClientID = candidateIDs.first
            return
        }

        if !candidateIDs.contains(selectedClientID) {
            self.selectedClientID = candidateIDs.first
        }
    }
}
