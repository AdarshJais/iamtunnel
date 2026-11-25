import SwiftUI

struct DependencyWarningView: View {
    let status: DependencyStatus
    @State private var expanded = false

    var missingItems: [String] {
        var items: [String] = []
        if !status.awsCLI { items.append("AWS CLI") }
        if !status.awsCredentials { items.append("credentials") }
        if !status.sessionManagerPlugin { items.append("SSM plugin") }
        return items
    }

    // MFA alone is a one-click fix, so it gets its own bar copy.
    private var isMFAOnly: Bool { missingItems.isEmpty && !status.mfaReady }

    var body: some View {
        VStack(spacing: 0) {
            // ── Compact warning bar ──────────────────────────
            HStack(spacing: 7) {
                Image(systemName: isMFAOnly ? "lock.shield" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))

                Text(isMFAOnly
                     ? status.mfaDetail
                     : "Missing: \(missingItems.joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if isMFAOnly {
                    Button("Authenticate") {
                        Task { await MFACoordinator.shared.ensureSession(for: firstPendingProfile()) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                } else {
                    Button(expanded ? "Hide" : "Details") {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))

            // ── Expanded detail rows ─────────────────────────
            if expanded {
                VStack(spacing: 0) {
                    if !status.awsCLI {
                        CompactDepRow(name: "AWS CLI v2", installURL: "https://aws.amazon.com/cli/")
                    }
                    if !status.awsCredentials {
                        CompactDepRow(name: "AWS credentials", installURL: "https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html")
                    }
                    if !status.sessionManagerPlugin {
                        CompactDepRow(name: "Session Manager Plugin", installURL: "https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html")
                    }
                }
                .background(Color.orange.opacity(0.04))
            }
        }
    }

    // First profile still waiting on an MFA session.
    private func firstPendingProfile() -> String {
        let profiles = ConnectionStore.shared.load()
            .map { $0.profile.isEmpty ? "default" : $0.profile }
        return profiles.first { AWSSession.shared.validSession(for: $0) == nil } ?? "default"
    }
}

struct CompactDepRow: View {
    let name: String
    let installURL: String

    var body: some View {
        HStack {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
            Button("Fix →") {
                NSWorkspace.shared.open(URL(string: installURL)!)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(Divider().padding(.leading, 14), alignment: .top)
    }
}

#Preview {
    VStack(spacing: 0) {
        DependencyWarningView(status: DependencyStatus(
            awsCLI: false,
            awsCLIVersion: "",
            awsCredentials: true,
            awsCredentialsDetail: "Configured",
            sessionManagerPlugin: false
        ))
        Divider()
        Text("New connection")
            .padding()
    }
    .frame(width: 320)
}
