import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var throughputStore: ThroughputStore

    private var selectedNetwork: EeroNetwork? {
        appState.selectedNetwork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eero Control")
                .font(.headline)

            Text(appState.cloudAndLanStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(localThroughputStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let network = selectedNetwork {
                Text(network.displayName)
                    .bold()
                Text("Connected: \(network.connectedClientsCount)")
                    .font(.caption)

                Button(network.guestNetworkEnabled ? "Disable Guest" : "Enable Guest") {
                    appState.setGuestNetwork(network: network, enabled: !network.guestNetworkEnabled)
                }
                .buttonStyle(.bordered)
            } else {
                Text("No network loaded")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Refresh") {
                    appState.refreshNow()
                }
                Button("Open App") {
                    openAppWindow()
                }
            }

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func openAppWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    private var localThroughputStatusText: String {
        if let realtime = selectedNetwork?.realtime {
            let down = String(format: "%.1f", realtime.downloadMbps)
            let up = String(format: "%.1f", realtime.uploadMbps)
            return "Network telemetry: ↓\(down) Mbps ↑\(up) Mbps"
        }
        guard let throughput = throughputStore.snapshot else {
            return "Local interface: unavailable"
        }
        return "Local interface: ↓\(throughput.downDisplay) ↑\(throughput.upDisplay) (\(throughput.interfaceName))"
    }
}
