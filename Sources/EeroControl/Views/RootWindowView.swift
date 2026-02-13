import AppKit
import SwiftUI

extension View {
  @ViewBuilder
  func liquidGlass<ShapeType: Shape>(
    in shape: ShapeType,
    tint: Color = .clear,
    interactive: Bool = false
  ) -> some View {
#if swift(>=6.0)
    if #available(macOS 26, *) {
      if interactive {
        self.glassEffect(.regular.tint(tint).interactive(), in: shape)
      } else {
        self.glassEffect(.regular.tint(tint), in: shape)
      }
    } else {
      self
    }
#else
    self
#endif
  }

  @ViewBuilder
  func glassEffectContainer() -> some View {
#if swift(>=6.0)
    if #available(macOS 26, *) {
      GlassEffectContainer {
        self
      }
    } else {
      self
    }
#else
    self
#endif
  }
}

private enum AppSection: String, CaseIterable, Identifiable {
  case dashboard
  case clients
  case profiles
  case network
  case offline
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dashboard: return "Dashboard"
    case .clients: return "Clients"
    case .profiles: return "Profiles"
    case .network: return "Network"
    case .offline: return "Offline"
    case .settings: return "Settings"
    }
  }
}

struct RootWindowView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedSection: AppSection = .dashboard

  private let pickerWidth: CGFloat = 220

  private var selectedNetworkBinding: Binding<String> {
    Binding(
      get: { appState.selectedNetworkID ?? appState.accountSnapshot?.networks.first?.id ?? "" },
      set: { appState.selectedNetworkID = $0 }
    )
  }

  private var selectedNetworkText: String {
    appState.selectedNetwork?.displayName ?? "No networks loaded"
  }

  private var lanStatusTone: AppTone {
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

  private var cloudStatusTone: AppTone {
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

  private var snapshotAgeText: String? {
    guard let freshness = appState.cachedFreshness else { return nil }
    let age = freshness.age
    if age < 60 {
      return "\(Int(age))s ago"
    }
    if age < 3_600 {
      return "\(Int(age / 60))m \(Int(age) % 60)s ago"
    }
    return "\(Int(age / 3_600))h \(Int(age.truncatingRemainder(dividingBy: 3_600) / 60))m ago"
  }

  private var throughputChipText: String? {
    guard let realtime = appState.selectedNetwork?.realtime else { return nil }
    return
      "↓\(compactRateString(megabitsPerSecond: realtime.downloadMbps)) ↑\(compactRateString(megabitsPerSecond: realtime.uploadMbps))"
  }

  private var mainContent: some View {
    Group {
      switch appState.authState {
      case .restoring:
        restoringView
      case .unauthenticated, .waitingForVerification:
        AuthView()
      case .authenticated:
        authenticatedContent
      }
    }
  }

  private var appBackground: some View {
    Color(nsColor: NSColor.windowBackgroundColor)
      .opacity(0.88)
      .ignoresSafeArea()
  }

  var body: some View {
    mainContent
      .glassEffectContainer()
    .padding(14)
    .background(WindowGlassHost())
    .background(appBackground)
  }

  private var restoringView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Restoring session...")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var authenticatedContent: some View {
    VStack(spacing: 12) {
      sectionSelector
      contextBar

      if let error = appState.lastErrorMessage, !error.isEmpty {
        StatusBanner(text: error, tone: .warning)
      }

      sectionContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
  }

  private var sectionSelector: some View {
    HStack(spacing: 0) {
      ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, section in
        Button {
          selectedSection = section
        } label: {
          Text(section.title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(selectedSection == section ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
              if selectedSection == section {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08))
                  .padding(.horizontal, 2)
                  .padding(.vertical, 2)
              }
            }
        }
        .buttonStyle(.plain)

        if index < AppSection.allCases.count - 1 {
          Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 18)
        }
      }
    }
    .padding(3)
    .frame(maxWidth: 620)
    .liquidGlass(in: Capsule(style: .continuous))
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch selectedSection {
    case .dashboard:
      DashboardView()
    case .clients:
      ClientsView()
    case .profiles:
      ProfilesView()
    case .network:
      NetworkView()
    case .offline:
      OfflineView()
    case .settings:
      AppSettingsView()
    }
  }

  private var contextBar: some View {
    HStack(spacing: 6) {
      networkPicker

      HStack(spacing: 6) {
        compactContextChip(
          icon: "network", text: appState.offlineSnapshot.localHealthLabel, tone: lanStatusTone)
        compactContextChip(
          icon: "icloud",
          text: appState.cloudState == .reachable
            ? "Cloud OK" : "Cloud \(appState.cloudState.rawValue.capitalized)",
          tone: cloudStatusTone
        )

        if let throughputChipText {
          compactContextChip(
            icon: "arrow.down.and.line.horizontal.and.arrow.up",
            text: throughputChipText,
            tone: .accent
          )
        }
      }

      Spacer(minLength: 4)

      HStack(spacing: 8) {
        if let snapshotAgeText {
          Text(snapshotAgeText)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Button("Refresh") {
          appState.refreshNow()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule(), tint: .blue.opacity(0.18), interactive: true)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .liquidGlass(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func compactContextChip(icon: String, text: String, tone: AppTone) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption2)
      Text(text)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 1)
    .foregroundStyle(tone.foregroundColor)
    .liquidGlass(in: Capsule(), tint: tone.backgroundColor.opacity(0.6))
    .fixedSize(horizontal: true, vertical: false)
  }

  private var networkPicker: some View {
    HStack(spacing: 8) {
      Text("Network")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      Group {
        if let snapshot = appState.accountSnapshot, !snapshot.networks.isEmpty {
          Picker("Network", selection: selectedNetworkBinding) {
            ForEach(snapshot.networks) { network in
              Text(network.displayName).tag(network.id)
            }
          }
          .pickerStyle(.menu)
          .controlSize(.small)
        } else {
          Text(selectedNetworkText)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: pickerWidth, alignment: .leading)
    }
  }

  private func compactRateString(megabitsPerSecond: Double) -> String {
    compactRateString(bitsPerSecond: max(0, megabitsPerSecond) * 1_000_000)
  }

  private func compactRateString(bitsPerSecond: Double) -> String {
    let value: Double
    let suffix: String

    if bitsPerSecond >= 1_000_000_000 {
      value = bitsPerSecond / 1_000_000_000
      suffix = "G"
    } else if bitsPerSecond >= 1_000_000 {
      value = bitsPerSecond / 1_000_000
      suffix = "M"
    } else if bitsPerSecond >= 1_000 {
      value = bitsPerSecond / 1_000
      suffix = "K"
    } else {
      value = bitsPerSecond
      suffix = "b"
    }

    let formatted: String
    if value >= 100 {
      formatted = String(format: "%.0f", value)
    } else if value >= 10 {
      formatted = String(format: "%.1f", value)
    } else {
      formatted = String(format: "%.2f", value)
    }
    return "\(formatted)\(suffix)"
  }
}

private struct WindowGlassHost: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.wantsLayer = true
    updateWindowStyle(for: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    updateWindowStyle(for: nsView)
  }

  private func updateWindowStyle(for nsView: NSView) {
    guard let window = nsView.window else { return }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.isOpaque = false
    window.contentView?.superview?.wantsLayer = true
    window.contentView?.superview?.layer?.isOpaque = false
    let appBackgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
    window.contentView?.superview?.layer?.backgroundColor = appBackgroundColor
    window.contentView?.layer?.backgroundColor = appBackgroundColor
    window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isHidden = false
    window.standardWindowButton(.closeButton)?.isHidden = false

    if let contentView = window.contentView,
      contentView.subviews.first(where: { $0 is WindowGlassEffectView }) == nil
    {
      let effect = WindowGlassEffectView()
      effect.translatesAutoresizingMaskIntoConstraints = false
      effect.configureForWindowGlass()
      contentView.addSubview(effect, positioned: .below, relativeTo: contentView.subviews.first)
      NSLayoutConstraint.activate([
        effect.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        effect.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        effect.topAnchor.constraint(equalTo: contentView.topAnchor),
        effect.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      ])
      contentView.layoutSubtreeIfNeeded()
    } else if let contentView = window.contentView {
      contentView
        .subviews
        .compactMap { $0 as? WindowGlassEffectView }
        .forEach { $0.configureForWindowGlass() }
    }
  }
}

extension NSVisualEffectView {
  fileprivate func configureForWindowGlass() {
    material = .underWindowBackground
    blendingMode = .behindWindow
    state = .active
  }
}

private final class WindowGlassEffectView: NSVisualEffectView {}

enum AppTone: Equatable {
  case neutral
  case accent
  case success
  case warning
  case danger

  var foregroundColor: Color {
    switch self {
    case .neutral:
      return .secondary
    case .accent:
      return .blue
    case .success:
      return .green
    case .warning:
      return .orange
    case .danger:
      return .red
    }
  }

  var backgroundColor: Color {
    switch self {
    case .neutral:
      return Color.primary.opacity(0.06)
    case .accent:
      return Color.blue.opacity(0.16)
    case .success:
      return Color.green.opacity(0.16)
    case .warning:
      return Color.orange.opacity(0.16)
    case .danger:
      return Color.red.opacity(0.16)
    }
  }
}

struct StatusChip: View {
  let icon: String
  let text: String
  let tone: AppTone

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption)
      Text(text)
        .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .foregroundStyle(tone.foregroundColor)
    .liquidGlass(in: Capsule(), tint: tone.backgroundColor.opacity(0.7))
  }
}

struct SectionCard<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
      content
    }
    .padding(12)
    .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

struct KeyValueRow: View {
  let label: String
  let value: String
  var valueTone: AppTone = .neutral

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(valueTone.foregroundColor)
    }
    .font(.callout)
  }
}

struct StatusBanner: View {
  let text: String
  let tone: AppTone

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
        .foregroundStyle(tone.foregroundColor)
      Text(text)
        .font(.callout)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .liquidGlass(
      in: RoundedRectangle(cornerRadius: 10, style: .continuous),
      tint: tone.backgroundColor.opacity(0.7))
  }
}
