import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case es
    case boCN = "bo-CN"

    var id: String {
        rawValue
    }

    var localizationCode: String? {
        self == .system ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            L10n.tr("language.system")
        case .zhHans:
            "简体中文"
        case .zhHant:
            "繁體中文"
        case .en:
            "English"
        case .ja:
            "日本語"
        case .ko:
            "한국어"
        case .es:
            "Español"
        case .boCN:
            "བོད་ཡིག (རྒྱ་ནག)"
        }
    }

    static func load() -> AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Keys.language)
    }

    private enum Keys {
        static let language = "language.selected"
    }
}

enum L10n {
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = localizedString(forKey: key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    private static func localizedString(forKey key: String) -> String {
        guard let code = AppLanguage.load().localizationCode,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
