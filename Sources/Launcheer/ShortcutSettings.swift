import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutSettings: Equatable {
    var isEnabled: Bool
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = ShortcutSettings(
        isEnabled: true,
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey)
    )

    static func load() -> ShortcutSettings {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.isEnabled) == nil {
            defaultShortcut.save()
            return defaultShortcut
        }
        return ShortcutSettings(
            isEnabled: defaults.bool(forKey: Keys.isEnabled),
            keyCode: UInt32(defaults.integer(forKey: Keys.keyCode)),
            modifiers: UInt32(defaults.integer(forKey: Keys.modifiers))
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Keys.isEnabled)
        defaults.set(Int(keyCode), forKey: Keys.keyCode)
        defaults.set(Int(modifiers), forKey: Keys.modifiers)
    }

    var displayText: String {
        ShortcutFormatter.displayText(keyCode: keyCode, modifiers: modifiers)
    }

    private enum Keys {
        static let isEnabled = "shortcut.isEnabled"
        static let keyCode = "shortcut.keyCode"
        static let modifiers = "shortcut.modifiers"
    }
}

struct DisplaySettings: Equatable {
    var showOnlyOnMainScreen: Bool

    static let defaultSettings = DisplaySettings(showOnlyOnMainScreen: true)

    static func load() -> DisplaySettings {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.showOnlyOnMainScreen) == nil {
            defaultSettings.save()
            return defaultSettings
        }
        return DisplaySettings(
            showOnlyOnMainScreen: defaults.bool(forKey: Keys.showOnlyOnMainScreen)
        )
    }

    func save() {
        UserDefaults.standard.set(showOnlyOnMainScreen, forKey: Keys.showOnlyOnMainScreen)
    }

    private enum Keys {
        static let showOnlyOnMainScreen = "display.showOnlyOnMainScreen"
    }
}

enum ShortcutFormatter {
    static func displayText(keyCode: UInt32, modifiers: UInt32) -> String {
        let modifierText = [
            (UInt32(cmdKey), "⌘"),
            (UInt32(optionKey), "⌥"),
            (UInt32(controlKey), "⌃"),
            (UInt32(shiftKey), "⇧")
        ]
            .filter { modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()

        return modifierText + keyName(for: keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return L10n.tr("key.space")
        case kVK_Return: return L10n.tr("key.return")
        case kVK_Tab: return L10n.tr("key.tab")
        case kVK_Escape: return L10n.tr("key.escape")
        case kVK_Delete: return L10n.tr("key.delete")
        case kVK_ForwardDelete: return L10n.tr("key.delete")
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return L10n.tr("key.generic", keyCode)
        }
    }
}
