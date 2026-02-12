import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var foregroundIntervalBinding: Binding<Double> {
        Binding(
            get: { appState.settings.foregroundPollInterval },
            set: { appState.settings.foregroundPollInterval = $0 }
        )
    }

    private var backgroundIntervalBinding: Binding<Double> {
        Binding(
            get: { appState.settings.backgroundPollInterval },
            set: { appState.settings.backgroundPollInterval = $0 }
        )
    }

    private var gatewayBinding: Binding<String> {
        Binding(
            get: { appState.settings.gatewayAddress },
            set: { appState.settings.gatewayAddress = $0 }
        )
    }

    private var defaultLoginBinding: Binding<String> {
        Binding(
            get: { appState.settings.defaultLogin },
            set: { appState.settings.defaultLogin = $0 }
        )
    }

    private var moderateConfirmationBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.askConfirmationForModerateRisk },
            set: { appState.settings.askConfirmationForModerateRisk = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pollingCard
                offlineCard
                authCard
                safetyCard
            }
            .padding(.top, 2)
        }
    }

    private var pollingCard: some View {
        SectionCard(title: "Polling") {
            Text("Tune refresh cadence for active and background modes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Foreground Interval (s)") {
                TextField(
                    "seconds",
                    value: foregroundIntervalBinding,
                    format: .number.precision(.fractionLength(0...1))
                )
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Background Interval (s)") {
                TextField(
                    "seconds",
                    value: backgroundIntervalBinding,
                    format: .number.precision(.fractionLength(0...1))
                )
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var offlineCard: some View {
        SectionCard(title: "Offline") {
            Text("LAN probes target this gateway when cloud access is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Gateway Address", text: gatewayBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var authCard: some View {
        SectionCard(title: "Authentication") {
            TextField("Default Login (email/phone)", text: defaultLoginBinding)
                .textFieldStyle(.roundedBorder)

            Button("Logout") {
                appState.logout()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var safetyCard: some View {
        SectionCard(title: "Safety") {
            Toggle("Confirm moderate-risk actions", isOn: moderateConfirmationBinding)

            Text("High-risk actions always require confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
