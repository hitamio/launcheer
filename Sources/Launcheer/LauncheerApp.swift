import AppKit
import CryptoKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = AppLibrary()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var hostingController: NSViewController?
    private var animatedContentView: NSView?
    private var hotKeyManager: GlobalHotKeyManager?
    private var applicationDirectoryMonitor: ApplicationDirectoryMonitor?
    private var applicationReloadTask: Task<Void, Never>?
    private var isAnimatingVisibility = false
    private var didCompleteInitialShow = false
    private var suppressReopenToggleUntil: CFTimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Launcheer didFinishLaunching")
        DebugLog.write("didFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideLauncher),
            name: .hideLauncher,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleLauncherFromNotification),
            name: .toggleLauncher,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsWindow),
            name: .showSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutSettingsChanged),
            name: .shortcutSettingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaySettingsChanged),
            name: .displaySettingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageSettingsChanged),
            name: .languageSettingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        hotKeyManager = GlobalHotKeyManager()
        applicationDirectoryMonitor = ApplicationDirectoryMonitor(urls: ApplicationScanner.applicationRoots()) { [weak self] in
            Task { @MainActor in
                self?.scheduleApplicationReload(reason: "application directory changed")
            }
        }
        applicationDirectoryMonitor?.start()
        showLauncher()
        Task {
            await library.reload()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSLog("Launcheer didBecomeActive")
        DebugLog.write("didBecomeActive")
        suppressReopenToggleUntil = max(suppressReopenToggleUntil, CACurrentMediaTime() + 0.35)
        guard !isAnimatingVisibility else { return }
        if !isLauncherVisible {
            showLauncher()
        }
    }

    func applicationDidUnhide(_ notification: Notification) {
        NSLog("Launcheer didUnhide")
        DebugLog.write("didUnhide")
        guard !isAnimatingVisibility else { return }
        showLauncher()
    }

    func applicationDidResignActive(_ notification: Notification) {
        NSLog("Launcheer didResignActive")
        DebugLog.write("didResignActive")
        NSApp.presentationOptions = []
        if isLauncherVisible, !isAnimatingVisibility {
            hideLauncher()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSLog("Launcheer shouldHandleReopen hasVisibleWindows=\(flag)")
        DebugLog.write("shouldHandleReopen hasVisibleWindows=\(flag)")
        if CACurrentMediaTime() < suppressReopenToggleUntil {
            return false
        }
        toggleLauncher()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationReloadTask?.cancel()
        applicationDirectoryMonitor?.stop()
    }

    @objc private func hideLauncher() {
        NSLog("Launcheer hideLauncher")
        DebugLog.write("hideLauncher")
        guard let window, !isAnimatingVisibility else { return }
        isAnimatingVisibility = true
        window.ignoresMouseEvents = true
        NSApp.presentationOptions = []

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                window?.orderOut(nil)
                window?.contentView = nil
                if self?.window === window {
                    self?.window = nil
                    self?.hostingController = nil
                    self?.animatedContentView = nil
                }
                self?.isAnimatingVisibility = false
                NSApp.deactivate()
            }
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        DebugLog.write("windowDidBecomeKey")
        if !isAnimatingVisibility {
            window?.ignoresMouseEvents = false
            window?.alphaValue = 1
        }
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier == Bundle.main.bundleIdentifier else {
            DebugLog.write("workspaceDidActivateOtherApplication")
            if isLauncherVisible, !isAnimatingVisibility {
                hideLauncher()
            }
            return
        }
        DebugLog.write("workspaceDidActivateApplication")
        suppressReopenToggleUntil = max(suppressReopenToggleUntil, CACurrentMediaTime() + 0.45)
        guard !isAnimatingVisibility, !isLauncherVisible else { return }
        showLauncher()
    }

    private func showLauncher() {
        NSLog("Launcheer showLauncher")
        DebugLog.write("showLauncher")
        let screenFrame = currentScreenFrame()

        if window == nil {
            let rootView = LaunchPadView()
                .environmentObject(library)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            let hostingController = NSHostingController(rootView: rootView)
            let containerView = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
            containerView.wantsLayer = true
            containerView.layer?.backgroundColor = NSColor.clear.cgColor
            containerView.autoresizingMask = [.width, .height]

            let glassView = NSVisualEffectView(frame: containerView.bounds)
            glassView.material = .underWindowBackground
            glassView.blendingMode = .behindWindow
            glassView.state = .active
            glassView.appearance = NSAppearance(named: .vibrantDark)
            glassView.alphaValue = 0.50
            glassView.autoresizingMask = [.width, .height]
            containerView.addSubview(glassView)

            let dimView = NSView(frame: containerView.bounds)
            dimView.wantsLayer = true
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
            dimView.autoresizingMask = [.width, .height]
            containerView.addSubview(dimView)

            let animatedContentView = NSView(frame: containerView.bounds)
            animatedContentView.wantsLayer = true
            animatedContentView.layer?.backgroundColor = NSColor.clear.cgColor
            animatedContentView.autoresizingMask = [.width, .height]
            containerView.addSubview(animatedContentView)

            hostingController.view.frame = animatedContentView.bounds
            hostingController.view.autoresizingMask = [.width, .height]
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
            animatedContentView.addSubview(hostingController.view)

            let launcherWindow = LauncherWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            launcherWindow.contentView = containerView
            launcherWindow.title = L10n.tr("app.name")
            launcherWindow.alphaValue = 0
            launcherWindow.isOpaque = false
            launcherWindow.backgroundColor = .clear
            launcherWindow.hasShadow = false
            launcherWindow.isReleasedWhenClosed = false
            launcherWindow.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            launcherWindow.level = .normal
            self.hostingController = hostingController
            self.animatedContentView = animatedContentView
            window = launcherWindow
        }

        restoreLauncher(frame: screenFrame)
    }

    private func toggleLauncher() {
        guard !isAnimatingVisibility else { return }
        guard didCompleteInitialShow else {
            showLauncher()
            return
        }

        if isLauncherVisible {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    @objc private func toggleLauncherFromNotification() {
        toggleLauncher()
    }

    @objc private func shortcutSettingsChanged() {
        hotKeyManager?.applyCurrentSettings()
    }

    @objc private func displaySettingsChanged() {
        guard isLauncherVisible, !isAnimatingVisibility else { return }
        restoreLauncher(frame: currentScreenFrame())
    }

    @objc private func languageSettingsChanged() {
        installMainMenu()
        window?.title = L10n.tr("app.name")
        settingsWindow?.title = L10n.tr("settings.windowTitle")
    }

    private func scheduleApplicationReload(reason: String) {
        DebugLog.write("scheduleApplicationReload reason=\(reason)")
        applicationReloadTask?.cancel()
        applicationReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.library.reload(showLoading: false)
        }
    }

    @objc private func showSettingsFromMenu() {
        showSettingsWindow()
    }

    @objc private func showAboutFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: aboutPanelOptions())
    }

    @objc private func hideFromMenu() {
        hideLauncher()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsPanel())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.tr("settings.windowTitle")
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: L10n.tr("app.name"))
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: L10n.tr("menu.about"),
            action: #selector(showAboutFromMenu),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: L10n.tr("menu.settings"),
            action: #selector(showSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: L10n.tr("menu.showHide"),
            action: #selector(toggleLauncherFromNotification),
            keyEquivalent: ""
        )
        toggleItem.target = self
        appMenu.addItem(toggleItem)

        let hideItem = NSMenuItem(
            title: L10n.tr("menu.hide"),
            action: #selector(hideFromMenu),
            keyEquivalent: "h"
        )
        hideItem.keyEquivalentModifierMask = [.command]
        hideItem.target = self
        appMenu.addItem(hideItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.tr("menu.quit"),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    private func aboutPanelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let github = "https://github.com/freddon/launcheer"
        let fingerprint = executableFingerprint()

        let credits = NSMutableAttributedString(
            string: L10n.tr("about.credits", github, fingerprint)
        )
        let fullRange = NSRange(location: 0, length: credits.length)
        credits.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ],
            range: fullRange
        )
        if let githubRange = credits.string.range(of: github) {
            credits.addAttributes(
                [
                    .link: github,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: NSRange(githubRange, in: credits.string)
            )
        }

        return [
            .applicationName: L10n.tr("app.name"),
            .applicationVersion: L10n.tr("about.version", version),
            .version: L10n.tr("about.build", build),
            .credits: credits
        ]
    }

    private func executableFingerprint() -> String {
        guard let executableURL = Bundle.main.executableURL,
              let data = try? Data(contentsOf: executableURL)
        else {
            return L10n.tr("about.fingerprintUnavailable")
        }

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(24)).uppercased()
    }

    private func restoreLauncher(frame screenFrame: CGRect) {
        guard let window else { return }
        NSLog("Launcheer restoreLauncher frame=\(NSStringFromRect(screenFrame))")
        DebugLog.write("restoreLauncher frame=\(screenFrame)")
        let shouldAnimateEntrance = !window.isVisible || window.alphaValue < 0.98
        window.setFrame(screenFrame, display: true, animate: false)
        window.contentView?.frame = CGRect(origin: .zero, size: screenFrame.size)
        if shouldAnimateEntrance {
            prepareEntrance(for: window)
        } else {
            resetEntranceState(for: window)
            window.ignoresMouseEvents = false
        }
        applyLaunchPadPresentation()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        if shouldAnimateEntrance {
            scheduleEntranceAnimation(for: window)
        }
    }

    private func prepareEntrance(for window: NSWindow) {
        isAnimatingVisibility = true
        window.ignoresMouseEvents = false
        window.alphaValue = 0

        hostingController?.view.layoutSubtreeIfNeeded()
        guard let layer = entranceLayer else {
            isAnimatingVisibility = false
            window.ignoresMouseEvents = false
            return
        }
        centerEntranceAnchor(for: layer)
        applyEntrancePerspective(to: layer)
        layer.removeAnimation(forKey: "launcheerEntrance")
        layer.opacity = 1
        layer.transform = entranceTransform
    }

    private func scheduleEntranceAnimation(for window: NSWindow) {
        window.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, self.window === window, self.isAnimatingVisibility else { return }
                window.alphaValue = 1
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                self.animateEntrance(for: window)
            }
        }
    }

    private func animateEntrance(for window: NSWindow) {
        let duration: TimeInterval = 0.22

        hostingController?.view.layoutSubtreeIfNeeded()
        guard let layer = entranceLayer else {
            isAnimatingVisibility = false
            window.ignoresMouseEvents = false
            return
        }
        centerEntranceAnchor(for: layer)
        applyEntrancePerspective(to: layer)

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = layer.transform
        transform.toValue = CATransform3DIdentity

        let group = CAAnimationGroup()
        group.animations = [transform]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.84, 0.18, 1.0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak window] in
            Task { @MainActor in
                guard let window else { return }
                self?.resetEntranceState(for: window)
                self?.isAnimatingVisibility = false
                self?.didCompleteInitialShow = true
                window.ignoresMouseEvents = false
            }
        }
        layer.add(group, forKey: "launcheerEntrance")
        CATransaction.commit()
    }

    private func resetEntranceState(for window: NSWindow) {
        window.alphaValue = 1
        entranceLayer?.removeAnimation(forKey: "launcheerEntrance")
        entranceLayer?.opacity = 1
        entranceLayer?.transform = CATransform3DIdentity
        entranceLayer?.superlayer?.sublayerTransform = CATransform3DIdentity
    }

    private func centerEntranceAnchor(for layer: CALayer) {
        let frame = layer.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.commit()
    }

    private func applyEntrancePerspective(to layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.superlayer?.sublayerTransform = entrancePerspective
        CATransaction.commit()
    }

    private var entranceLayer: CALayer? {
        animatedContentView?.layer
    }

    private var entrancePerspective: CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 1200.0
        return transform
    }

    private var entranceTransform: CATransform3D {
        CATransform3DMakeTranslation(0, 0, -620)
    }

    private func applyLaunchPadPresentation() {
        NSApp.presentationOptions = []
    }

    private var isLauncherVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.alphaValue > 0.05
    }

    private func currentScreenFrame() -> CGRect {
        if DisplaySettings.load().showOnlyOnMainScreen {
            return NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero
        }

        let mouseLocation = NSEvent.mouseLocation
        let currentScreen = NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
        return (currentScreen ?? NSScreen.main)?.frame ?? .zero
    }
}

private final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

@main
enum LauncheerMain {
    @MainActor
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
