//
//  SettingsManager.swift
//  SSMTunnelManager
//
//  Created by Lsn-Adarsh on 24/03/26.
//

import Foundation
import ServiceManagement

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var launchAtLogin: Bool = false {
        didSet { applyLaunchAtLogin() }
    }

    @Published var notifyOnConnect: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnConnect, forKey: "notifyOnConnect") }
    }

    @Published var notifyOnDisconnect: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnDisconnect, forKey: "notifyOnDisconnect") }
    }

    @Published var showActiveCount: Bool = true {
        didSet {
            UserDefaults.standard.set(showActiveCount, forKey: "showActiveCount")
            NotificationCenter.default.post(name: .menuBarSettingsChanged, object: nil)
        }
    }

    // MFA session time left next to the menu bar icon ("11h", orange "12m" near expiry).
    @Published var showSessionTime: Bool = true {
        didSet {
            UserDefaults.standard.set(showSessionTime, forKey: "showSessionTime")
            NotificationCenter.default.post(name: .menuBarSettingsChanged, object: nil)
        }
    }

    // Org policy: IAM requires an MFA-authenticated session for CLI actions.
    // On by default — turn it off only for accounts without the MFA condition.
    @Published var requireMFA: Bool = true {
        didSet { UserDefaults.standard.set(requireMFA, forKey: "requireMFA") }
    }

    // Duration passed to `sts get-session-token --duration-seconds`.
    @Published var mfaDurationHours: Int = 12 {
        didSet { UserDefaults.standard.set(mfaDurationHours, forKey: "mfaDurationHours") }
    }

    @Published var notifyOnMFASession: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnMFASession, forKey: "notifyOnMFASession") }
    }

    init() {
        // Load saved preferences
        notifyOnConnect    = UserDefaults.standard.object(forKey: "notifyOnConnect")    as? Bool ?? true
        notifyOnDisconnect = UserDefaults.standard.object(forKey: "notifyOnDisconnect") as? Bool ?? true
        showActiveCount    = UserDefaults.standard.object(forKey: "showActiveCount")    as? Bool ?? true
        showSessionTime    = UserDefaults.standard.object(forKey: "showSessionTime")    as? Bool ?? true
        requireMFA         = UserDefaults.standard.object(forKey: "requireMFA")         as? Bool ?? true
        notifyOnMFASession = UserDefaults.standard.object(forKey: "notifyOnMFASession") as? Bool ?? true
        mfaDurationHours   = UserDefaults.standard.object(forKey: "mfaDurationHours")   as? Int  ?? 12

        // Check current launch at login state
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("❌ Launch at login error: \(error)")
            }
        }
    }
}

extension Notification.Name {
    static let menuBarSettingsChanged = Notification.Name("menuBarSettingsChanged")
}
