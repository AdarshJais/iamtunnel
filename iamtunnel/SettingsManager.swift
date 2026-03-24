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
        didSet { UserDefaults.standard.set(showActiveCount, forKey: "showActiveCount") }
    }

    init() {
        // Load saved preferences
        notifyOnConnect    = UserDefaults.standard.object(forKey: "notifyOnConnect")    as? Bool ?? true
        notifyOnDisconnect = UserDefaults.standard.object(forKey: "notifyOnDisconnect") as? Bool ?? true
        showActiveCount    = UserDefaults.standard.object(forKey: "showActiveCount")    as? Bool ?? true

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
