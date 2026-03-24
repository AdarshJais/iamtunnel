import SwiftUI

struct NewConnectionView: View {
    var editing: Tunnel? = nil
    var onSave: (Tunnel) -> Void
    var onCancel: () -> Void = {}

    @State private var name       = ""
    @State private var profile    = "default"
    @State private var region     = "us-east-1"
    @State private var ssmTarget  = ""
    @State private var remoteHost = ""
    @State private var remotePort = ""
    @State private var localPort  = ""
    @State private var env        = TunnelEnv.dev
    @State private var testResult = TestResult.idle

    private let awsProfiles = AWSConfigReader.shared.profileNames

    init(editing: Tunnel? = nil, onSave: @escaping (Tunnel) -> Void, onCancel: @escaping () -> Void = {}) {
        self.editing = editing
        self.onSave = onSave
        self.onCancel = onCancel
        if let t = editing {
            _name       = State(initialValue: t.name)
            _profile    = State(initialValue: t.profile)
            _region     = State(initialValue: t.region)
            _ssmTarget  = State(initialValue: t.ssmTarget)
            _remoteHost = State(initialValue: t.remoteHost)
            _remotePort = State(initialValue: String(t.remotePort))
            _localPort  = State(initialValue: String(t.localPort))
            _env        = State(initialValue: t.env)
        }
    }

    private var isDuplicate: Bool {
        // When editing, exclude the current tunnel from duplicate check
        tunnels.contains { t in
            t.id != (editing?.id ?? UUID()) &&
            (t.name.lowercased() == name.lowercased() || t.localPort == Int(localPort) ?? -1)
        }
    }

    private var duplicateMessage: String? {
        guard let port = Int(localPort) else { return nil }
        if let t = tunnels.first(where: { $0.id != (editing?.id ?? UUID()) && $0.localPort == port }) {
            return "Port \(port) already used by \"\(t.name)\""
        }
        if let t = tunnels.first(where: { $0.id != (editing?.id ?? UUID()) && $0.name.lowercased() == name.lowercased() }) {
            return "Name \"\(t.name)\" already exists"
        }
        return nil
    }

    private var isValid: Bool {
        !name.isEmpty && !ssmTarget.isEmpty &&
        !remoteHost.isEmpty && !remotePort.isEmpty && !localPort.isEmpty &&
        !isDuplicate
    }

    private let tunnels: [Tunnel] = ConnectionStore.shared.load()

    var body: some View {
        VStack(spacing: 0) {

            // ── Form ─────────────────────────────────────────────
            VStack(spacing: 12) {

                HStack(spacing: 10) {
                    FormField(label: "Name", placeholder: "Production Postgres") {
                        TextField("", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Env")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $env) {
                            Text("prod").tag(TunnelEnv.production)
                            Text("stage").tag(TunnelEnv.staging)
                            Text("dev").tag(TunnelEnv.dev)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("AWS profile")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Menu(profile) {
                            ForEach(awsProfiles, id: \.self) { p in
                                Button(p) {
                                    profile = p
                                    if let r = AWSConfigReader.shared.region(for: p) {
                                        region = r
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    }
                    FormField(label: "Region", placeholder: "us-east-1") {
                        TextField("", text: $region)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                }

                FormField(label: "SSM target", placeholder: "i-0abc123def456 or my-bastion") {
                    TextField("", text: $ssmTarget)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }

                HStack(spacing: 10) {
                    FormField(label: "Remote host", placeholder: "mydb.cluster.internal") {
                        TextField("", text: $remoteHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .onChange(of: remoteHost) { host in
                                if let detected = extractRegion(from: host), region == "us-east-1" || region.isEmpty {
                                    region = detected
                                }
                            }
                    }
                    FormField(label: "Remote port", placeholder: "5432") {
                        TextField("", text: $remotePort)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .frame(width: 80)
                }

                FormField(label: "Local port", placeholder: "15432") {
                    TextField("", text: $localPort)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }

                // ── Duplicate warning ────────────────────────────
                if let msg = duplicateMessage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ── Test result message ──────────────────────────
                if case .testing = testResult {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Testing connection…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if case .success(let msg) = testResult {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if case .failure(let msg) = testResult {
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)

            Divider()

            // ── Footer ───────────────────────────────────────────
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Spacer()

                // Test button
                Button(action: runTest) {
                    Text("Test connection")
                        .font(.system(size: 13))
                        .foregroundStyle(isValid ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isValid)

                // Save button
                Button(action: save) {
                    Text(editing == nil ? "Save" : "Update")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(isValid ? Color.accentColor : Color.accentColor.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!isValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
    }

    private func runTest() {
        testResult = .testing
        let tunnel = buildTunnel()
        Task {
            let result = await ConnectionTester.shared.test(tunnel: tunnel)
            await MainActor.run { testResult = result }
        }
    }

    private func save() {
        onSave(buildTunnel())
    }

    // Extracts region from AWS hostnames e.g.
    // xxx.ap-south-1.rds.amazonaws.com → ap-south-1
    // xxx.us-east-1.elb.amazonaws.com  → us-east-1
    private func extractRegion(from host: String) -> String? {
        let parts = host.split(separator: ".")
        let awsRegions = ["us-east-1","us-east-2","us-west-1","us-west-2",
                          "ap-south-1","ap-southeast-1","ap-southeast-2",
                          "ap-northeast-1","ap-northeast-2","ap-northeast-3",
                          "eu-west-1","eu-west-2","eu-west-3","eu-central-1",
                          "eu-north-1","sa-east-1","ca-central-1","me-south-1"]
        return parts.map(String.init).first { awsRegions.contains($0) }
    }

    private func buildTunnel() -> Tunnel {
        Tunnel(
            id: editing?.id ?? UUID(),
            name: name, profile: profile, region: region,
            ssmTarget: ssmTarget, remoteHost: remoteHost,
            remotePort: Int(remotePort) ?? 0,
            localPort: Int(localPort) ?? 0,
            env: env, status: editing?.status ?? .stopped
        )
    }
}

// ── Reusable form field ──────────────────────────────────────
struct FormField<Content: View>: View {
    let label: String
    let placeholder: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NewConnectionView(onSave: { _ in })
}
