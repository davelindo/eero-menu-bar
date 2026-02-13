import AppKit
import SwiftUI

struct StatusPopoverView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var throughputStore: ThroughputStore

  private var selectedNetwork: EeroNetwork? {
    appState.selectedNetwork
  }

  var body: some View {
    let content = VStack(alignment: .leading, spacing: 12) {
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
          .buttonStyle(.plain)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .liquidGlass(in: Capsule(), tint: .blue.opacity(0.2), interactive: true)
        } else {
          Text("No network loaded")
            .foregroundStyle(.secondary)
        }

        Divider()

        HStack {
          Button("Refresh") {
            appState.refreshNow()
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .liquidGlass(
            in: Capsule(), tint: AppTone.neutral.backgroundColor.opacity(0.2), interactive: true)

          Button("Open App") {
            openAppWindow()
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .liquidGlass(in: Capsule(), tint: .blue.opacity(0.2), interactive: true)
        }

        if let error = appState.lastErrorMessage {
          Text(error)
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
    .padding(14)
    .frame(width: 320)
    .background(Color.clear)

    if #available(macOS 26, *) {
      GlassEffectContainer {
        content
      }
    } else {
      content
    }
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
    return
      "Local interface: ↓\(throughput.downDisplay) ↑\(throughput.upDisplay) (\(throughput.interfaceName))"
  }
}
