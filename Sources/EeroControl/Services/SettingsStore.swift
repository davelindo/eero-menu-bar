import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var foregroundPollInterval: Double
    var backgroundPollInterval: Double
    var gatewayAddress: String
    var defaultLogin: String
    var askConfirmationForModerateRisk: Bool

    static let `default` = AppSettings(
        foregroundPollInterval: 8,
        backgroundPollInterval: 90,
        gatewayAddress: "192.168.4.1",
        defaultLogin: "",
        askConfirmationForModerateRisk: false
    )

    func normalized() -> AppSettings {
        AppSettings(
            foregroundPollInterval: max(3, foregroundPollInterval),
            backgroundPollInterval: max(15, backgroundPollInterval),
            gatewayAddress: gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "192.168.4.1"
                : gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultLogin: defaultLogin.trimmingCharacters(in: .whitespacesAndNewlines),
            askConfirmationForModerateRisk: askConfirmationForModerateRisk
        )
    }
}

final class SettingsStore: ObservableObject {
    private enum Keys {
        static let foregroundPollInterval = "settings.foregroundPollInterval"
        static let backgroundPollInterval = "settings.backgroundPollInterval"
        static let gatewayAddress = "settings.gatewayAddress"
        static let defaultLogin = "settings.defaultLogin"
        static let askConfirmationForModerateRisk = "settings.askConfirmationForModerateRisk"
    }

    private let defaults: UserDefaults

    @Published var settings: AppSettings {
        didSet {
            let normalized = settings.normalized()
            if normalized != settings {
                settings = normalized
                return
            }
            defaults.set(settings.foregroundPollInterval, forKey: Keys.foregroundPollInterval)
            defaults.set(settings.backgroundPollInterval, forKey: Keys.backgroundPollInterval)
            defaults.set(settings.gatewayAddress, forKey: Keys.gatewayAddress)
            defaults.set(settings.defaultLogin, forKey: Keys.defaultLogin)
            defaults.set(settings.askConfirmationForModerateRisk, forKey: Keys.askConfirmationForModerateRisk)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = AppSettings(
            foregroundPollInterval: defaults.object(forKey: Keys.foregroundPollInterval) as? Double ?? AppSettings.default.foregroundPollInterval,
            backgroundPollInterval: defaults.object(forKey: Keys.backgroundPollInterval) as? Double ?? AppSettings.default.backgroundPollInterval,
            gatewayAddress: defaults.string(forKey: Keys.gatewayAddress) ?? AppSettings.default.gatewayAddress,
            defaultLogin: defaults.string(forKey: Keys.defaultLogin) ?? AppSettings.default.defaultLogin,
            askConfirmationForModerateRisk: defaults.object(forKey: Keys.askConfirmationForModerateRisk) as? Bool ?? AppSettings.default.askConfirmationForModerateRisk
        ).normalized()
    }
}
