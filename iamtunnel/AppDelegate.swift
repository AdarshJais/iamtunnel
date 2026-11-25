import Cocoa
import Combine
import SwiftUI

// Debug logging — only prints in Debug builds
func debugLog(_ message: String) {
    #if DEBUG
    print(message)
    #endif
}

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var settingsWindow: NSWindow?
    var setupWindow: NSWindow?
    private var sessionTimer: Timer?
    // Sessions already warned about, keyed by profile + expiry, so each
    // session gets one "expiring soon" notice.
    private var warnedSessions: Set<String> = []
    private var autoPromptedSessions: Set<String> = []
    private var lastActiveCount = 0
    private var lastRendered = ""
    private var clockTimer: Timer?
    private var sessionChanges: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        // Request notification permission
        NotificationManager.shared.requestPermission()

        // Set app icon explicitly for notifications
        if let image = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = image
        }

        // 1. Create the menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(activeCount: 0)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
        }

        // 2. Create the popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 360)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: TunnelListView())

        // 3. Observe active tunnel count changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateActiveCount(_:)),
            name: .tunnelStatusChanged,
            object: nil
        )

        // 4. Watch MFA session expiry (STS tokens are short-lived)
        startSessionExpiryWatch()

        // 5. First run: open the setup check until it has passed once.
        if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openSetup() }
        }
    }

    // ── MFA session expiry watcher ───────────────────────────
    private func startSessionExpiryWatch() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            guard SettingsManager.shared.requireMFA else { return }
            for profile in AWSSession.shared.activeProfiles {
                guard let session = AWSSession.shared.validSession(for: profile),
                      session.remaining <= MFASession.warnBefore else { continue }
                let key = "\(profile)-\(session.expiration.timeIntervalSince1970)"
                if self.warnedSessions.insert(key).inserted {
                    NotificationManager.shared.notifyMFAExpiringSoon(session: session)
                }
                // 10 min left and tunnels in use: open the renew prompt once,
                // without taking keyboard focus.
                if session.isUrgent, TunnelManager.shared.hasConnectedTunnel(profile: profile),
                   self.autoPromptedSessions.insert(key).inserted {
                    Task { @MainActor in MFACoordinator.shared.renewSession(for: profile, quiet: true) }
                }
            }
            for profile in AWSSession.shared.pruneExpired() {
                debugLog("🔐 MFA session expired for \(profile)")
                if TunnelManager.shared.hasConnectedTunnel(profile: profile) {
                    Task { @MainActor in MFACoordinator.shared.promptExpired(profile: profile, quiet: true) }
                } else {
                    NotificationManager.shared.notifyMFAExpired(profile: profile)
                }
            }
            self.updateStatusIcon(activeCount: self.lastActiveCount)
        }
        NotificationCenter.default.addObserver(
            forName: .menuBarSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastRendered = ""
            self.updateStatusIcon(activeCount: self.lastActiveCount)
        }
        // Live countdown in the menu bar (redraws only when the text changes).
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateStatusIcon(activeCount: self.lastActiveCount)
        }
        // Renewed or cleared: put the normal icon back straight away.
        sessionChanges = AWSSession.shared.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusIcon(activeCount: self.lastActiveCount)
            }
    }

    // iamtunnel://connect?name=… / ?port=…, iamtunnel://disconnect?…
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { URLCommandHandler.shared.handle($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTimer?.invalidate()
        TunnelManager.shared.disconnectAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // ── Update menu bar icon ─────────────────────────────────
    // The MFA session that ends first (the one a tunnel would lose first).
    private var soonestSession: MFASession? {
        guard SettingsManager.shared.requireMFA else { return nil }
        return AWSSession.shared.activeProfiles
            .compactMap { AWSSession.shared.validSession(for: $0) }
            .min { $0.expiration < $1.expiration }
    }

    // Menu bar: icon, then "⣿ 2 · 11h" (connections · MFA time left). In the
    // last 20 minutes the icon becomes a lock and the text turns orange (red under 10).
    func updateStatusIcon(activeCount: Int) {
        guard let button = statusItem?.button else { return }
        lastActiveCount = activeCount
        let settings = SettingsManager.shared

        let session = soonestSession
        let expiring = session?.isExpiringSoon == true
        let urgent = session?.isUrgent == true
        var parts: [String] = []
        if settings.showActiveCount && activeCount > 0 { parts.append("⣿ \(activeCount)") }
        if let session, settings.showSessionTime || expiring { parts.append(session.countdownLabel) }

        let title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        let tint: NSColor? = urgent ? .systemRed : (expiring ? .systemOrange : nil)
        // Called every second: only touch the button when something visible changed.
        let rendered = "\(title)|\(urgent)|\(expiring)"
        guard rendered != lastRendered else { return }
        lastRendered = rendered

        let symbol = expiring ? "lock.trianglebadge.exclamationmark" : "point.3.connected.trianglepath.dotted"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "iamtunnel")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.contentTintColor = tint

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        if let tint { attributes[.foregroundColor] = tint }
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)

        if let session {
            button.toolTip = "MFA session (\(session.profile)) valid until \(session.expiresAtLabel)"
                + (expiring ? ". Click, then Renew." : "")
        } else {
            button.toolTip = "iamtunnel"
        }
    }

    @objc func updateActiveCount(_ notification: Foundation.Notification) {
        let count = notification.userInfo?["activeCount"] as? Int ?? 0
        updateStatusIcon(activeCount: count)
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.contentViewController = NSHostingController(rootView: TunnelListView())
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    // ── Open settings window ─────────────────────────────────
    func openSetup() {
        if setupWindow == nil {
            let view = SetupAssistantView { [weak self] in self?.setupWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "iamtunnel setup"
            window.styleMask = NSWindow.StyleMask([.titled, .closable])
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        } else {
            // Re-run the checks each time it is reopened.
            setupWindow?.contentViewController = NSHostingController(
                rootView: SetupAssistantView { [weak self] in self?.setupWindow?.close() })
        }
        popover?.performClose(nil)
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = NSWindow.StyleMask([.titled, .closable])
            window.setContentSize(NSSize(width: 400, height: 440))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SSM Tunnel Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",       action: #selector(UndoManager.undo),        keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",       action: #selector(UndoManager.redo),        keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),           keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),          keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),     keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        return main
    }
}

// Notification name for tunnel status changes
extension Notification.Name {
    static let tunnelStatusChanged = Notification.Name("tunnelStatusChanged")
    static let tunnelStatusChangedByLink = Notification.Name("tunnelStatusChangedByLink")
}
