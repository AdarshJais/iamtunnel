import AppKit
import SwiftUI

// Presents the MFA prompt from anywhere (tunnel connect, test, settings)
// and serialises it so two tunnels can't open two windows at once.
//
// Every path out of the prompt — authenticate, cancel, red close button,
// or being replaced by another profile's prompt — must resume the waiting
// continuations, otherwise callers hang forever.
@MainActor
final class MFACoordinator: NSObject, NSWindowDelegate {
    static let shared = MFACoordinator()

    private var window: NSWindow?
    private var presentedProfile: String?
    private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]

    private override init() { super.init() }

    private func normalize(_ profile: String) -> String {
        profile.isEmpty ? "default" : profile
    }

    // Returns true once a valid session exists for the profile.
    @discardableResult
    func ensureSession(for profile: String) async -> Bool {
        let key = normalize(profile)

        if AWSSession.shared.validSession(for: key) != nil { return true }

        // A prompt for this profile is already on screen — join it.
        // `default: []` guarantees the continuation is always parked somewhere
        // that finish() can resume; an optional-chained append would drop it
        // and hang the caller forever.
        if waiters[key] != nil {
            return await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }

        waiters[key] = []
        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            present(profile: key, reason: nil)
        }
    }

    // Force a new prompt even when a session is still valid (Settings → Refresh).
    @discardableResult
    func ensureSessionRefresh(for profile: String) async -> Bool {
        let key = normalize(profile)
        AWSSession.shared.clearSession(for: key)
        return await ensureSession(for: key)
    }

    // Renew before expiry: prompt for a fresh code but keep the current
    // session if the user cancels, so running tunnels aren't affected.
    // `quiet`: shown in front without taking keyboard focus (automatic prompts),
    // so someone typing elsewhere doesn't type into the code box.
    func renewSession(for profile: String, quiet: Bool = false) {
        let key = normalize(profile)
        guard waiters[key] == nil else { return }
        waiters[key] = []
        present(profile: key,
                reason: "Enter a fresh code to extend the \"\(key)\" session before it expires.",
                quiet: quiet)
    }

    // Session died mid-use — re-prompt without blocking a caller.
    func promptExpired(profile: String, quiet: Bool = false) {
        let key = normalize(profile)
        NotificationManager.shared.notifyMFAExpired(profile: key)
        guard waiters[key] == nil else { return }
        waiters[key] = []
        present(profile: key,
                reason: "Your MFA session for \"\(key)\" expired. Enter a fresh code to continue.",
                quiet: quiet)
    }

    // ── Window plumbing ────────────────────────────────────
    private func present(profile: String, reason: String?, quiet: Bool = false) {
        // Replacing a prompt for a different profile must not strand its waiters.
        if let outgoing = presentedProfile, outgoing != profile {
            finish(profile: outgoing, success: false)
        }

        let view = MFAPromptView(profile: profile, reason: reason) { [weak self] _ in
            self?.finish(profile: profile, success: true)
        } onCancel: { [weak self] in
            self?.finish(profile: profile, success: false)
        }

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "AWS MFA"
        window.styleMask = NSWindow.StyleMask([.titled, .closable])
        window.setContentSize(NSSize(width: 380, height: 380))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()

        self.window = window
        self.presentedProfile = profile

        if quiet {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func finish(profile: String, success: Bool) {
        let key = normalize(profile)

        if presentedProfile == key {
            let closing = window
            window = nil
            presentedProfile = nil
            closing?.delegate = nil
            closing?.close()
        }

        let pending = waiters.removeValue(forKey: key) ?? []
        pending.forEach { $0.resume(returning: success) }
    }

    // Red close button — treat as cancel so nobody waits forever.
    func windowWillClose(_ notification: Foundation.Notification) {
        guard let profile = presentedProfile else { return }
        window = nil
        presentedProfile = nil
        let pending = waiters.removeValue(forKey: profile) ?? []
        pending.forEach { $0.resume(returning: false) }
    }
}
