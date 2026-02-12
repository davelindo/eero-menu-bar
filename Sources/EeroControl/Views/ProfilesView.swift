import SwiftUI

private struct ProfileFilterDescriptor: Identifiable {
    let id: String
    let label: String
    let value: Bool?
}

struct ProfilesView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedProfileID: String?
    @State private var blockedAppsDraft: [String: String] = [:]

    private let listPanelMinWidth: CGFloat = 320
    private let listPanelMaxWidth: CGFloat = 420

    private var selectedNetwork: EeroNetwork? {
        appState.selectedNetwork
    }

    private var profiles: [EeroProfile] {
        guard let selectedNetwork else { return [] }
        return selectedNetwork.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
                StatusChip(icon: "pause.fill", text: "\(pausedProfileCount) paused", tone: pausedProfileCount > 0 ? .warning : .success)
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
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedProfile?.id == profile.id ? Color.blue.opacity(0.2) : Color.primary.opacity(0.03))
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
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Text("Content Filters")
                .font(.headline)

            ForEach(filterDescriptors(for: profile)) { descriptor in
                Toggle(
                    descriptor.label,
                    isOn: Binding(
                        get: { descriptor.value ?? false },
                        set: { appState.setProfileFilter(network: network, profile: profile, key: descriptor.id, enabled: $0) }
                    )
                )
            }

            Divider()

            Text("Blocked Apps")
                .font(.headline)
            TextField("Comma-separated app names", text: blockedAppsBinding(for: profile))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Save Blocked Apps") {
                    appState.setProfileBlockedApps(
                        network: network,
                        profile: profile,
                        apps: parseBlockedApps(from: blockedAppsBinding(for: profile).wrappedValue)
                    )
                }
                .buttonStyle(.borderedProminent)

                Button("Reset Draft") {
                    blockedAppsDraft[profile.id] = profile.blockedApplications.joined(separator: ", ")
                }
                .buttonStyle(.bordered)
            }

            if !profile.blockedApplications.isEmpty {
                KeyValueRow(
                    label: "Current Blocked Apps",
                    value: profile.blockedApplications.joined(separator: ", ")
                )
            }
        }
    }

    private func filterDescriptors(for profile: EeroProfile) -> [ProfileFilterDescriptor] {
        [
            ProfileFilterDescriptor(id: "block_pornographic_content", label: "Adult Content", value: profile.filters.blockAdult),
            ProfileFilterDescriptor(id: "block_gaming_content", label: "Gaming", value: profile.filters.blockGaming),
            ProfileFilterDescriptor(id: "block_messaging_content", label: "Messaging", value: profile.filters.blockMessaging),
            ProfileFilterDescriptor(id: "block_shopping_content", label: "Shopping", value: profile.filters.blockShopping),
            ProfileFilterDescriptor(id: "block_social_content", label: "Social", value: profile.filters.blockSocial),
            ProfileFilterDescriptor(id: "block_streaming_content", label: "Streaming", value: profile.filters.blockStreaming),
            ProfileFilterDescriptor(id: "block_violent_content", label: "Violence", value: profile.filters.blockViolent)
        ]
    }

    private func blockedAppsBinding(for profile: EeroProfile) -> Binding<String> {
        Binding(
            get: {
                blockedAppsDraft[profile.id] ?? profile.blockedApplications.joined(separator: ", ")
            },
            set: {
                blockedAppsDraft[profile.id] = $0
            }
        )
    }

    private func parseBlockedApps(from value: String) -> [String] {
        value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func syncSelection(resetSelection: Bool = false) {
        let profileIDs = profiles.map(\.id)

        if resetSelection {
            selectedProfileID = profileIDs.first
            return
        }

        guard let selectedProfileID else {
            self.selectedProfileID = profileIDs.first
            return
        }

        if !profileIDs.contains(selectedProfileID) {
            self.selectedProfileID = profileIDs.first
        }
    }
}
