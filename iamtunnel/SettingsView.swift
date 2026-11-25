import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // ── Security ─────────────────────────────────
                    SectionLabel("Security")

                    SettingsRow(
                        icon: "lock.shield",
                        title: "Require MFA session",
                        subtitle: "Ask for an authenticator code, then use temporary session credentials",
                        isOn: $settings.requireMFA
                    )
                    Divider().padding(.leading, 52)

                    if settings.requireMFA {
                        MFASessionPanel()
                        Divider().padding(.leading, 52)

                        SettingsRow(
                            icon: "bell.badge",
                            title: "Notify on session change",
                            subtitle: "Alert when an MFA session starts or expires",
                            isOn: $settings.notifyOnMFASession
                        )
                        Divider().padding(.leading, 52)
                    }

                    // ── Connections ──────────────────────────────
                    SectionLabel("Connections")

                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share tunnels")
                                .font(.system(size: 13))
                            Text("Import a team's connections file, or export yours. No credentials included.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Import…") { ConnectionImporter.chooseAndImport() }
                        Button("Export…") { ConnectionImporter.chooseAndExport() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 52)

                    HStack(spacing: 12) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Setup check")
                                .font(.system(size: 13))
                            Text("Checks AWS CLI, keys, MFA device, clock and tunnels, with a fix for each")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Run…") { (NSApp.delegate as? AppDelegate)?.openSetup() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 52)

                    // ── General ──────────────────────────────────
                    SectionLabel("General")

                    SettingsRow(
                        icon: "power",
                        title: "Launch at login",
                        subtitle: "Start iamtunnel when you log in",
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
                    Divider().padding(.leading, 52)

                    SettingsRow(
                        icon: "clock",
                        title: "Show MFA time left",
                        subtitle: "Session time next to the menu bar icon; orange under 20 min, red under 10",
                        isOn: $settings.showSessionTime
                    )
                }
            }

            // ── Version ──────────────────────────────────────────
            Divider()
            Text("iamtunnel v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 10)
        }
        .frame(width: 400, height: 440)
    }
}

// ── MFA session status + actions ─────────────────────────────
struct MFASessionPanel: View {
    @ObservedObject private var session = AWSSession.shared
    @State private var profile: String = AWSConfigReader.shared.profileNames.first ?? "default"
    @State private var identity: String? = nil
    @State private var checking = false

    private let profiles = AWSConfigReader.shared.profileNames

    private var current: MFASession? {
        // `revision` is observed so this recomputes after auth/expiry.
        _ = session.revision
        return session.validSession(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Session")
                        .font(.system(size: 13))
                    if let active = current {
                        Text("Valid until \(active.expiresAtLabel) · \(active.remainingLabel)")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    } else {
                        Text("No active session for this profile")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu(profile) {
                    ForEach(profiles, id: \.self) { p in
                        Button(p) {
                            profile = p
                            identity = nil
                        }
                    }
                }
                .frame(width: 110)
            }

            HStack(spacing: 10) {
                Button(current == nil ? "Authenticate…" : "Refresh session…") {
                    Task { await MFACoordinator.shared.ensureSessionRefresh(for: profile) }
                }
                .font(.system(size: 12))

                Button("Verify") {
                    checking = true
                    identity = nil
                    Task {
                        let arn = await AWSSession.shared.verifyCallerIdentity(profile: profile)
                        await MainActor.run {
                            identity = arn ?? "Not authenticated"
                            checking = false
                        }
                    }
                }
                .font(.system(size: 12))
                .disabled(checking || current == nil)

                if current != nil {
                    Button("Sign out") {
                        AWSSession.shared.clearSession(for: profile)
                        identity = nil
                    }
                    .font(.system(size: 12))
                }

                Spacer()
            }
            .padding(.leading, 40)

            if checking {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text("Checking caller identity…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 40)
            } else if let identity {
                Text(identity)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// ── Section header ───────────────────────────────────────────
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
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
                    .fixedSize(horizontal: false, vertical: true)
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
