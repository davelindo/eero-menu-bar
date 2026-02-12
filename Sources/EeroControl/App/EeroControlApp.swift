import SwiftUI

@main
struct EeroControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup("Eero Control") {
            RootWindowView()
                .environmentObject(appState)
                .environmentObject(appState.throughputStore)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear {
                    appState.start()
                    appState.setWindowVisible(true)
                }
                .onDisappear {
                    appState.setWindowVisible(false)
                }
                .alert(item: $appState.pendingConfirmation) { pending in
                    Alert(
                        title: Text(pending.title),
                        message: Text(pending.message),
                        primaryButton: .destructive(Text("Confirm")) {
                            appState.confirmPendingAction()
                        },
                        secondaryButton: .cancel {
                            appState.cancelPendingAction()
                        }
                    )
                }
        }

        Settings {
            AppSettingsView()
                .environmentObject(appState)
                .environmentObject(appState.throughputStore)
                .frame(width: 440, height: 320)
        }
    }
}
