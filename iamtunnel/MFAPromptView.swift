import SwiftUI

struct MFAPromptView: View {
    let profile: String
    var reason: String? = nil
    var onAuthenticated: (MFASession) -> Void
    var onCancel: () -> Void = {}

    @State private var code = ""
    @State private var serial: String? = nil
    @State private var manualSerial = ""
    @State private var needsManualSerial = false
    @State private var isWorking = false
    @State private var errorMessage: String? = nil
    @State private var durationHours: Int = SettingsManager.shared.mfaDurationHours

    private var isValidCode: Bool {
        code.count == 6 && code.allSatisfy { $0.isNumber }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────
            VStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                Text("MFA required")
                    .font(.system(size: 15, weight: .semibold))
                Text(reason ?? "Enter the 6-digit code from your authenticator app to start an AWS session.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            // ── Body ─────────────────────────────────────────────
            VStack(spacing: 12) {

                // Profile + device
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Profile")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(profile)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if needsManualSerial {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Device ARN")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("arn:aws:iam::123456789012:mfa/my-device", text: $manualSerial)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                                .disabled(isWorking)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text("Device")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(serial ?? "looking up MFA device…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(serial == nil ? .tertiary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // OTP field
                TextField("000000", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .onChange(of: code) { value in
                        // Keep digits only, max 6
                        let digits = value.filter { $0.isNumber }
                        if digits != value || digits.count > 6 {
                            code = String(digits.prefix(6))
                        }
                        errorMessage = nil
                    }
                    .onSubmit { authenticate() }
                    .disabled(isWorking)

                // Session length
                HStack(spacing: 8) {
                    Text("Session length")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $durationHours) {
                        Text("1h").tag(1)
                        Text("4h").tag(4)
                        Text("8h").tag(8)
                        Text("12h").tag(12)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(isWorking)
                }

                // Status / error
                if isWorking {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Requesting session token…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 12)

            Divider()

            // ── Footer ───────────────────────────────────────────
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .disabled(isWorking)

                Spacer()

                Button(action: authenticate) {
                    Text("Authenticate")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(isValidCode && !isWorking
                                    ? Color.accentColor
                                    : Color.accentColor.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!isValidCode || isWorking)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 380, height: needsManualSerial ? 380 : 340)
        .task {
            serial = await AWSSession.shared.discoverSerial(for: profile)
            if serial == nil {
                needsManualSerial = true
                manualSerial = AWSSession.shared.cachedSerial(for: profile) ?? ""
                errorMessage = MFAError.noDevice(profile).errorDescription
            }
        }
    }

    private func authenticate() {
        guard isValidCode, !isWorking else { return }
        isWorking = true
        errorMessage = nil

        let override = needsManualSerial ? manualSerial : nil

        Task {
            let result = await AWSSession.shared.authenticate(
                profile: profile,
                tokenCode: code,
                durationHours: durationHours,
                serialOverride: override
            )
            await MainActor.run {
                isWorking = false
                switch result {
                case .success(let session):
                    SettingsManager.shared.mfaDurationHours = durationHours
                    NotificationManager.shared.notifyMFASession(session: session)
                    onAuthenticated(session)
                case .failure(let error):
                    code = ""
                    errorMessage = error.errorDescription
                    // Let the user correct the ARN when AWS rejects the device.
                    if case .noDevice = error { needsManualSerial = true }
                    if case .badSerial = error {
                        needsManualSerial = true
                        if manualSerial.isEmpty { manualSerial = serial ?? "" }
                    }
                }
            }
        }
    }
}

#Preview {
    MFAPromptView(profile: "default", onAuthenticated: { _ in })
}
