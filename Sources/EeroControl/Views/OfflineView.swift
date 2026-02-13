import SwiftUI

struct OfflineView: View {
  @EnvironmentObject private var appState: AppState

  private var queuedActions: [QueuedAction] {
    appState.queuedActions
  }

  private var pendingActionCount: Int {
    queuedActions.filter { $0.status == .pending }.count
  }

  private var failedActionCount: Int {
    queuedActions.filter { $0.status == .failed }.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      localProbeCard
      queueCard
    }
  }

  private var localProbeCard: some View {
    SectionCard(title: "Local Probes") {
      HStack(spacing: 8) {
        StatusChip(
          icon: "network", text: appState.offlineSnapshot.localHealthLabel, tone: toneForLanStatus()
        )
        StatusChip(
          icon: "list.bullet.clipboard", text: "Pending \(pendingActionCount)",
          tone: pendingActionCount > 0 ? .warning : .success)
        if failedActionCount > 0 {
          StatusChip(
            icon: "exclamationmark.triangle.fill", text: "Failed \(failedActionCount)",
            tone: .danger)
        }
      }

      probeRow("Gateway", result: appState.offlineSnapshot.gateway)
      probeRow("Router DNS", result: appState.offlineSnapshot.dns)
      probeRow("NTP (Optional)", result: appState.offlineSnapshot.ntp, optional: true)

      KeyValueRow(
        label: "Route",
        value: appState.offlineSnapshot.route.message,
        valueTone: appState.offlineSnapshot.route.success ? .success : .warning
      )

      Text("NTP is informational only and does not affect LAN health.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var queueCard: some View {
    SectionCard(title: "Queued Actions") {
      if queuedActions.isEmpty {
        Text("No pending actions.")
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(queuedActions) { item in
              queuedActionRow(item)
            }
          }
        }
        .frame(minHeight: 140, maxHeight: 250)
      }

      HStack(spacing: 8) {
        Button("Replay Queue") {
          appState.replayQueuedActions()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), tint: .blue.opacity(0.22), interactive: true)

        Button("Run Probes") {
          appState.refreshNow()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(
          in: Capsule(), tint: AppTone.neutral.backgroundColor.opacity(0.22), interactive: true)
      }
    }
  }

  private func queuedActionRow(_ item: QueuedAction) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(item.action.label)
          .font(.callout.weight(.semibold))
        Spacer()
        Text(item.status.rawValue.capitalized)
          .font(.caption.weight(.semibold))
          .foregroundStyle(toneForQueueStatus(item.status).foregroundColor)
      }

      if let error = item.lastError, !error.isEmpty {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Spacer()
        Button("Remove") {
          appState.removeQueuedAction(id: item.id)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule(), tint: .blue.opacity(0.2), interactive: true)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func probeRow(_ title: String, result: ProbeResult, optional: Bool = false) -> some View {
    let tone: AppTone
    if optional {
      tone = result.success ? .success : .neutral
    } else {
      tone = result.success ? .success : .warning
    }

    return KeyValueRow(
      label: title,
      value: result.message,
      valueTone: tone
    )
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

  private func toneForQueueStatus(_ status: QueuedAction.ReplayStatus) -> AppTone {
    switch status {
    case .pending:
      return .warning
    case .replayed:
      return .success
    case .failed:
      return .danger
    }
  }
}
