import Cocoa
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
    private var sessionTimer: Timer?
    // Sessions already warned about, keyed by profile + expiry, so each
    // session gets one "expiring soon" notice.
    private var warnedSessions: Set<String> = []

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
            }
            for profile in AWSSession.shared.pruneExpired() {
                debugLog("🔐 MFA session expired for \(profile)")
                NotificationManager.shared.notifyMFAExpired(profile: profile)
            }
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
    func updateStatusIcon(activeCount: Int) {
        guard let button = statusItem?.button else { return }
        if SettingsManager.shared.showActiveCount && activeCount > 0 {
            button.image = nil
            button.title = "⣿ \(activeCount)"
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                   accessibilityDescription: "SSM Tunnel Manager")
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
