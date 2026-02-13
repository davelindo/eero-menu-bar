import SwiftUI

private struct ProfileFilterDescriptor: Identifiable {
  let id: String
  let label: String
  let value: Bool?
}

struct ProfilesView: View {
  @EnvironmentObject private var appState: AppState

  @State private var selectedProfileID: String?
  @State private var blockedAppsDraft: [String: Set<String>] = [:]

  private let listPanelMinWidth: CGFloat = 320
  private let listPanelMaxWidth: CGFloat = 420

  private var selectedNetwork: EeroNetwork? {
    appState.selectedNetwork
  }

  private var profiles: [EeroProfile] {
    guard let selectedNetwork else { return [] }
    return selectedNetwork.profiles.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private var selectedProfile: EeroProfile? {
    guard let selectedProfileID else { return profiles.first }
    return profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
  }

  private var pausedProfileCount: Int {
    profiles.filter(\.paused).count
  }

  var body: some View {
    if let selectedNetwork {
      if profiles.isEmpty {
        SectionCard(title: "Profiles") {
          Text("No profiles found for this network.")
            .foregroundStyle(.secondary)
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          profileListCard
            .frame(minWidth: listPanelMinWidth, idealWidth: 360, maxWidth: listPanelMaxWidth)
            .frame(maxHeight: .infinity, alignment: .top)

          profileEditorCard(network: selectedNetwork)
            .frame(minWidth: 480, maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
          syncSelection()
        }
        .onChange(of: appState.selectedNetworkID) { _ in
          syncSelection(resetSelection: true)
        }
        .onChange(of: profiles.map(\.id)) { _ in
          syncSelection()
        }
      }
    } else {
      SectionCard(title: "Profiles") {
        Text("No network selected")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var profileListCard: some View {
    SectionCard(title: "Profiles") {
      HStack(spacing: 8) {
        StatusChip(icon: "person.2.fill", text: "\(profiles.count) total", tone: .neutral)
        StatusChip(
          icon: "pause.fill", text: "\(pausedProfileCount) paused",
          tone: pausedProfileCount > 0 ? .warning : .success)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(profiles) { profile in
            profileRow(profile)
          }
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  private func profileRow(_ profile: EeroProfile) -> some View {
    Button {
      selectedProfileID = profile.id
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.name)
            .font(.callout.weight(.semibold))
          Text(profile.paused ? "Paused" : "Active")
            .font(.caption)
            .foregroundStyle(profile.paused ? .orange : .secondary)
        }

        Spacer()

        if !profile.blockedApplications.isEmpty {
          Text("\(profile.blockedApplications.count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .liquidGlass(
        in: RoundedRectangle(cornerRadius: 8, style: .continuous),
        tint: selectedProfile?.id == profile.id ? Color.blue.opacity(0.35) : .clear
      )
    }
    .buttonStyle(.plain)
  }

  private func profileEditorCard(network: EeroNetwork) -> some View {
    SectionCard(title: "Profile Policies") {
      ScrollView {
        if let profile = selectedProfile {
          profileEditorContent(network: network, profile: profile)
        } else {
          Text("Select a profile to edit controls.")
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  private func profileEditorContent(network: EeroNetwork, profile: EeroProfile) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(profile.name)
            .font(.title3.weight(.semibold))
          Text(profile.paused ? "Profile paused" : "Profile active")
            .font(.caption.weight(.semibold))
            .foregroundStyle(profile.paused ? .orange : .green)
        }

        Spacer()

        Button(profile.paused ? "Resume Profile" : "Pause Profile") {
          appState.setProfilePaused(network: network, profile: profile, paused: !profile.paused)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(
          in: Capsule(),
          tint: profile.paused ? .orange.opacity(0.24) : .blue.opacity(0.2),
          interactive: true
        )
      }

      Divider()

      Text("Content Filters")
        .font(.headline)

      ForEach(filterDescriptors(for: profile)) { descriptor in
        Toggle(
          descriptor.label,
          isOn: Binding(
            get: { descriptor.value ?? false },
            set: {
              appState.setProfileFilter(
                network: network, profile: profile, key: descriptor.id, enabled: $0)
            }
          )
        )
      }

      Divider()

      Text("Blocked Apps")
        .font(.headline)
      Text("Toggle app-level blocks, then apply once.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button("Save Blocked Apps") {
          appState.setProfileBlockedApps(
            network: network,
            profile: profile,
            apps: blockedAppsSelection(for: profile).sorted {
              $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
          )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), tint: .blue.opacity(0.22), interactive: true)

        Button("Reset") {
          blockedAppsDraft[profile.id] = blockedAppSeed(for: profile)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(
          in: Capsule(), tint: AppTone.neutral.backgroundColor.opacity(0.22), interactive: true)

        Spacer(minLength: 0)
      }

      let options = blockedAppOptions(for: profile)
      if options.isEmpty {
        Text("No app catalog returned for this profile yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(options) { app in
              Toggle(isOn: blockedAppBinding(for: profile, appID: app.id)) {
                HStack(spacing: 8) {
                  Text(app.displayName)
                    .lineLimit(1)
                  if !app.categoryIDs.isEmpty {
                    Text(app.categoryIDs.prefix(2).joined(separator: ", "))
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
              }
              .toggleStyle(.checkbox)
            }
          }
          .padding(.vertical, 2)
        }
        .frame(minHeight: 120, maxHeight: 240)
      }

      let selectedApps = blockedAppsSelection(for: profile)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      if !selectedApps.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Selected")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading,
            spacing: 6
          ) {
            ForEach(selectedApps, id: \.self) { appID in
              Text(appLabel(for: appID, in: profile))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .liquidGlass(in: Capsule(), tint: .blue.opacity(0.22))
            }
          }
        }
      }
    }
    .onAppear {
      ensureBlockedAppsDraft(for: profile)
    }
    .onChange(of: profile.id) { _ in
      ensureBlockedAppsDraft(for: profile)
    }
  }

  private func filterDescriptors(for profile: EeroProfile) -> [ProfileFilterDescriptor] {
    [
      ProfileFilterDescriptor(
        id: "block_pornographic_content", label: "Adult Content", value: profile.filters.blockAdult),
      ProfileFilterDescriptor(
        id: "block_gaming_content", label: "Gaming", value: profile.filters.blockGaming),
      ProfileFilterDescriptor(
        id: "block_messaging_content", label: "Messaging", value: profile.filters.blockMessaging),
      ProfileFilterDescriptor(
        id: "block_shopping_content", label: "Shopping", value: profile.filters.blockShopping),
      ProfileFilterDescriptor(
        id: "block_social_content", label: "Social", value: profile.filters.blockSocial),
      ProfileFilterDescriptor(
        id: "block_streaming_content", label: "Streaming", value: profile.filters.blockStreaming),
      ProfileFilterDescriptor(
        id: "block_violent_content", label: "Violence", value: profile.filters.blockViolent),
    ]
  }

  private func blockedAppSeed(for profile: EeroProfile) -> Set<String> {
    var seed = Set(
      profile.blockedApplications
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    for option in (profile.availableApplications ?? []) where option.isBlocked {
      let trimmed = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        seed.insert(trimmed)
      }
    }
    return seed
  }

  private func ensureBlockedAppsDraft(for profile: EeroProfile) {
    if blockedAppsDraft[profile.id] == nil {
      blockedAppsDraft[profile.id] = blockedAppSeed(for: profile)
    }
  }

  private func blockedAppsSelection(for profile: EeroProfile) -> Set<String> {
    if let draft = blockedAppsDraft[profile.id] {
      return draft
    }
    return blockedAppSeed(for: profile)
  }

  private func blockedAppBinding(for profile: EeroProfile, appID: String) -> Binding<Bool> {
    Binding(
      get: { blockedAppsSelection(for: profile).contains(appID) },
      set: { enabled in
        var updated = blockedAppsSelection(for: profile)
        if enabled {
          updated.insert(appID)
        } else {
          updated.remove(appID)
        }
        blockedAppsDraft[profile.id] = updated
      }
    )
  }

  private func blockedAppOptions(for profile: EeroProfile) -> [EeroBlockedApplication] {
    (profile.availableApplications ?? []).sorted { lhs, rhs in
      if lhs.isBlocked != rhs.isBlocked {
        return lhs.isBlocked && !rhs.isBlocked
      }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  private func appLabel(for appID: String, in profile: EeroProfile) -> String {
    if let option = (profile.availableApplications ?? []).first(where: { $0.id == appID }) {
      return option.displayName
    }
    return appID
  }

  private func syncSelection(resetSelection: Bool = false) {
    let profileIDs = profiles.map(\.id)

    if resetSelection {
      selectedProfileID = profileIDs.first
      if let profile = selectedProfile {
        ensureBlockedAppsDraft(for: profile)
      }
      return
    }

    guard let selectedProfileID else {
      self.selectedProfileID = profileIDs.first
      if let profile = selectedProfile {
        ensureBlockedAppsDraft(for: profile)
      }
      return
    }

    if !profileIDs.contains(selectedProfileID) {
      self.selectedProfileID = profileIDs.first
    }

    if let profile = selectedProfile {
      ensureBlockedAppsDraft(for: profile)
    }
  }
}
