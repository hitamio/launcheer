import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsPanel: View {
    @State private var shortcut = ShortcutSettings.load()
    @State private var displaySettings = DisplaySettings.load()
    @State private var language = AppLanguage.load()
    @State private var isRecording = false
    @State private var localizationRevision = 0

    var body: some View {
        Form {
            Section(L10n.tr("settings.section.language")) {
                Picker(L10n.tr("settings.language.label"), selection: Binding(
                    get: { language },
                    set: { value in
                        language = value
                        persistLanguage()
                    }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(L10n.tr("settings.section.mainInterface")) {
                Toggle(isOn: Binding(
                    get: { displaySettings.showOnlyOnMainScreen },
                    set: { value in
                        displaySettings.showOnlyOnMainScreen = value
                        persistDisplaySettings()
                    }
                )) {
                    Text(L10n.tr("settings.mainScreenOnly"))
                }

                Text(L10n.tr("settings.mainScreenOnly.description"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("settings.section.shortcut")) {
                Toggle(isOn: Binding(
                    get: { shortcut.isEnabled },
                    set: { value in
                        shortcut.isEnabled = value
                        persistShortcut()
                    }
                )) {
                    Text(L10n.tr("settings.shortcut.enable"))
                }

                HStack(spacing: 12) {
                    Text(L10n.tr("settings.shortcut.label"))
                        .frame(width: 72, alignment: .leading)

                    Button {
                        isRecording = true
                    } label: {
                        Text(isRecording ? L10n.tr("settings.shortcut.recording") : shortcut.displayText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(width: 150, height: 28)
                    }
                    .disabled(!shortcut.isEnabled)
                    .background {
                        ShortcutCaptureView(isRecording: $isRecording) { keyCode, modifiers in
                            shortcut.keyCode = keyCode
                            shortcut.modifiers = modifiers
                            shortcut.isEnabled = true
                            persistShortcut()
                        }
                        .frame(width: 1, height: 1)
                        .opacity(0)
                    }

                    Button(L10n.tr("settings.shortcut.restoreDefault")) {
                        shortcut = .defaultShortcut
                        persistShortcut()
                    }
                }

                Text(L10n.tr("settings.shortcut.description"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480, height: 380)
        .id(localizationRevision)
    }

    private func persistShortcut() {
        shortcut.save()
        LauncherCommands.shortcutSettingsChanged()
    }

    private func persistDisplaySettings() {
        displaySettings.save()
        LauncherCommands.displaySettingsChanged()
    }

    private func persistLanguage() {
        language.save()
        localizationRevision += 1
        LauncherCommands.languageSettingsChanged()
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onShortcut: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onShortcut = onShortcut
        view.onCancel = {
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onShortcut = { keyCode, modifiers in
            onShortcut(keyCode, modifiers)
            isRecording = false
        }
        nsView.onCancel = {
            isRecording = false
        }
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onShortcut: (UInt32, UInt32) -> Void = { _, _ in }
    var onCancel: () -> Void = {}

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onCancel()
            return
        }

        let modifiers = ShortcutFormatter.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        onShortcut(UInt32(event.keyCode), modifiers)
    }
}
