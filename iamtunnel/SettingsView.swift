import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // ── Rows ─────────────────────────────────────────────
            SettingsRow(
                icon: "power",
                title: "Launch at login",
                subtitle: "Start SSM Tunnel Manager when you log in",
                isOn: $settings.launchAtLogin
            )
            Divider().padding(.leading, 52)

            SettingsRow(
                icon: "bell",
                title: "Notify on connect",
                subtitle: "Show a notification when a tunnel connects",
                isOn: $settings.notifyOnConnect
            )
            Divider().padding(.leading, 52)

            SettingsRow(
                icon: "bell.slash",
                title: "Notify on disconnect",
                subtitle: "Show a notification when a tunnel drops",
                isOn: $settings.notifyOnDisconnect
            )
            Divider().padding(.leading, 52)

            SettingsRow(
                icon: "number",
                title: "Show active count",
                subtitle: "Display active tunnel count in menu bar icon",
                isOn: $settings.showActiveCount
            )

            Spacer()

            // ── Version ──────────────────────────────────────────
            Divider()
            Text("SSM Tunnel Manager v1.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 10)
        }
        .frame(width: 380, height: 300)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#Preview {
    SettingsView()
}
