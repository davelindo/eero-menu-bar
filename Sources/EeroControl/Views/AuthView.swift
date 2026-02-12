import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var appState: AppState

    private var authError: String? {
        appState.lastErrorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to eero")
                .font(.title2)
                .bold()

            switch appState.authState {
            case .restoring, .authenticated:
                EmptyView()

            case .unauthenticated:
                loginSection

            case .waitingForVerification(let login):
                verificationSection(login: login)
            }

            if let error = authError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone or Email")
            TextField("you@example.com or +15551234567", text: $appState.loginInput)
                .textFieldStyle(.roundedBorder)

            Button("Request Verification Code") {
                appState.requestLogin()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func verificationSection(login: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification code sent to \(login)")
                .foregroundStyle(.secondary)

            TextField("Enter code", text: $appState.verificationCode)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Verify") {
                    appState.verifyLoginCode()
                }
                .buttonStyle(.borderedProminent)

                Button("Start Over") {
                    appState.restartAuthentication()
                }
            }
        }
    }
}
