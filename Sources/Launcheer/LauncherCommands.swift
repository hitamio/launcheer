import Foundation

extension Notification.Name {
    static let hideLauncher = Notification.Name("Launcheer.hideLauncher")
    static let toggleLauncher = Notification.Name("Launcheer.toggleLauncher")
    static let showSettings = Notification.Name("Launcheer.showSettings")
    static let shortcutSettingsChanged = Notification.Name("Launcheer.shortcutSettingsChanged")
    static let displaySettingsChanged = Notification.Name("Launcheer.displaySettingsChanged")
    static let languageSettingsChanged = Notification.Name("Launcheer.languageSettingsChanged")
}

enum LauncherCommands {
    static func hide() {
        NotificationCenter.default.post(name: .hideLauncher, object: nil)
    }

    static func toggle() {
        NotificationCenter.default.post(name: .toggleLauncher, object: nil)
    }

    static func showSettings() {
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    static func shortcutSettingsChanged() {
        NotificationCenter.default.post(name: .shortcutSettingsChanged, object: nil)
    }

    static func displaySettingsChanged() {
        NotificationCenter.default.post(name: .displaySettingsChanged, object: nil)
    }

    static func languageSettingsChanged() {
        NotificationCenter.default.post(name: .languageSettingsChanged, object: nil)
    }
}
