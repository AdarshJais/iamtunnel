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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            window.setContentSize(NSSize(width: 380, height: 300))
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
}
