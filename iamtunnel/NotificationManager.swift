import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("✅ Notifications granted")
            } else {
                print("❌ Notifications denied: \(String(describing: error))")
            }
        }
    }

    func notifyConnected(tunnel: Tunnel) {
        guard UserDefaults.standard.object(forKey: "notifyOnConnect") as? Bool ?? true else { return }
        send(
            title: "Tunnel connected",
            body: "\(tunnel.name) → \(tunnel.localAddress)",
            identifier: "connected-\(tunnel.id)"
        )
    }

    func notifyDisconnected(tunnel: Tunnel, unexpected: Bool = false) {
        guard UserDefaults.standard.object(forKey: "notifyOnDisconnect") as? Bool ?? true else { return }
        send(
            title: unexpected ? "Tunnel disconnected" : "Tunnel stopped",
            body: unexpected
                ? "\(tunnel.name) dropped unexpectedly"
                : "\(tunnel.name) stopped",
            identifier: "disconnected-\(tunnel.id)"
        )
    }

    private func send(title: String, body: String, identifier: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                print("⚠️ Notifications not authorized")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}
