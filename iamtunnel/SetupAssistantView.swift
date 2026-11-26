import AppKit
import SwiftUI

// First-run checklist (also under Settings and the warning banner): checks each
// thing a tunnel needs for real and offers one fix per missing piece.
struct SetupStep: Identifiable {
    enum State {
        case checking
        case ok(String)
        case problem(Diagnosis)
        case todo(detail: String, actionLabel: String, action: @MainActor () -> Void,
                  secondLabel: String? = nil, secondAction: (@MainActor () -> Void)? = nil)
        case waiting(String) // can't check until an earlier step passes
    }

    let id: String
    let title: String
    var state: State
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var steps: [SetupStep] = []
    @Published var isRunning = false

    private var profile: String {
        let used = ConnectionStore.shared.load().first?.profile ?? ""
        return used.isEmpty ? "default" : used
    }

    private var hasBrew: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    var allDone: Bool {
        !steps.isEmpty && steps.allSatisfy { if case .ok = $0.state { return true } else { return false } }
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let ids = [("cli", "AWS CLI"), ("ssm", "Session Manager plugin"), ("keys", "AWS keys"),
                   ("mfa", "MFA device"), ("clock", "Mac clock"), ("tunnels", "Tunnels"), ("session", "MFA session")]
        steps = ids.map { SetupStep(id: $0.0, title: $0.1, state: .checking) }

        let deps = await DependencyChecker.shared.checkAsync()

        set("cli", deps.awsCLI
            ? .ok(deps.awsCLIVersion.isEmpty ? "Installed" : deps.awsCLIVersion)
            : install(formula: "awscli", cask: false, docs: "https://aws.amazon.com/cli/"))

        set("ssm", deps.sessionManagerPlugin
            ? .ok("Installed")
            : install(formula: "session-manager-plugin", cask: true,
                      docs: "https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"))

        var keysOK = false
        if deps.awsCLI {
            let keys = await AWSDoctor.checkKeys(profile: profile)
            if let arn = keys.arn {
                keysOK = true
                set("keys", .ok("Profile \(profile) · \(arn.components(separatedBy: "/").last ?? arn)"))
            } else if let problem = keys.diagnosis {
                set("keys", .problem(problem))
            }
        } else {
            set("keys", .waiting("Needs the AWS CLI first"))
        }

        if keysOK {
            if let serial = await AWSSession.shared.discoverSerial(for: profile) {
                set("mfa", .ok(serial.components(separatedBy: "/").last ?? serial))
            } else {
                set("mfa", .problem(Diagnosis(
                    title: "No MFA device found on your AWS user",
                    detail: "In the AWS console: your name (top right) → Security credentials → Assign MFA device → Authenticator app, then scan the QR code with your phone.",
                    fix: .openMFADevices)))
            }
        } else {
            set("mfa", .waiting("Needs working AWS keys first"))
        }

        if let skew = await AWSDoctor.clockSkew() {
            if abs(skew) <= AWSDoctor.maxClockSkew {
                set("clock", .ok("In sync with AWS"))
            } else {
                let minutes = max(1, Int((abs(skew) / 60).rounded()))
                set("clock", .problem(Diagnosis(
                    title: "Clock is \(minutes) min \(skew > 0 ? "fast" : "slow")",
                    detail: "MFA codes fail when the clock is off by more than about 30 seconds. Turn on \"Set time and date automatically\".",
                    fix: .openDateTime)))
            }
        } else {
            set("clock", .ok("Couldn't check (offline?)"))
        }

        let count = ConnectionStore.shared.load().count
        set("tunnels", count > 0
            ? .ok("\(count) saved")
            : .todo(detail: "None yet. Import your team's connections file, or add one by hand.",
                    actionLabel: "Import…", action: { ConnectionImporter.chooseAndImport() },
                    secondLabel: "New connection…",
                    secondAction: { (NSApp.delegate as? AppDelegate)?.openNewConnection() }))

        if !SettingsManager.shared.requireMFA {
            set("session", .ok("MFA not required (Settings)"))
        } else if let session = AWSSession.shared.validSession(for: profile) {
            set("session", .ok("Active until \(session.expiresAtLabel) · \(session.remainingLabel)"))
        } else if keysOK {
            let p = profile
            set("session", .todo(detail: "Enter a code once to start a session.",
                                 actionLabel: "Authenticate",
                                 action: { Task { await MFACoordinator.shared.ensureSession(for: p) } }))
        } else {
            set("session", .waiting("Needs working AWS keys first"))
        }

        if allDone { UserDefaults.standard.set(true, forKey: "setupCompleted") }
    }

    private func install(formula: String, cask: Bool, docs: String) -> SetupStep.State {
        if hasBrew {
            let command = "brew install \(cask ? "--cask " : "")\(formula)"
            return .todo(detail: "Not installed. Opens Terminal to run `\(command)`.",
                         actionLabel: "Install…", action: { AWSDoctor.openInTerminal(command) })
        }
        return .todo(detail: "Not installed. Homebrew isn't installed either; follow AWS's install guide.",
                     actionLabel: "Install guide", action: { NSWorkspace.shared.open(URL(string: docs)!) })
    }

    private func set(_ id: String, _ state: SetupStep.State) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state }
    }
}

struct SetupAssistantView: View {
    @StateObject private var model = SetupModel()
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup check")
                    .font(.system(size: 15, weight: .semibold))
                Text("Everything a tunnel needs, checked for real. Fix anything orange, then Check again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.steps) { step in
                        SetupStepRow(step: step) { Task { await model.run() } }
                        Divider().padding(.leading, 46)
                    }
                }
            }

            Divider()

            HStack {
                if model.allDone {
                    Label("All set", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Check again") { Task { await model.run() } }
                    .disabled(model.isRunning)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 560)
        .task { await model.run() }
        .onReceive(NotificationCenter.default.publisher(for: .connectionsChanged)) { _ in
            Task { await model.run() }
        }
    }
}

private struct SetupStepRow: View {
    let step: SetupStep
    var recheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.system(size: 13, weight: .medium))
                switch step.state {
                case .checking:
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .ok(let detail):
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                case .waiting(let detail):
                    Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                case .todo(let detail, let label, let action, let secondLabel, let secondAction):
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(label) { action() }.controlSize(.small)
                        if let secondLabel, let secondAction {
                            Button(secondLabel) { secondAction() }.controlSize(.small)
                        }
                    }
                case .problem(let diagnosis):
                    DiagnosisCard(diagnosis: diagnosis) {
                        if case .removeSessionToken = diagnosis.fix { recheck() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .checking: ProgressView().scaleEffect(0.5)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .todo, .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}
