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
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      Button("Request Verification Code") {
        appState.requestLogin()
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .liquidGlass(in: Capsule(), tint: .blue.opacity(0.25), interactive: true)
    }
  }

  private func verificationSection(login: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Verification code sent to \(login)")
        .foregroundStyle(.secondary)

      TextField("Enter code", text: $appState.verificationCode)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      HStack {
        Button("Verify") {
          appState.verifyLoginCode()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), tint: .green.opacity(0.25), interactive: true)

        Button("Start Over") {
          appState.restartAuthentication()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), tint: .orange.opacity(0.2), interactive: true)
      }
    }
  }
}
