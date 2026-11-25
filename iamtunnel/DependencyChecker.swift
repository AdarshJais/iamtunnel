import Foundation

struct DependencyStatus {
    var awsCLI: Bool = false
    var awsCLIVersion: String = ""
    var awsCredentials: Bool = false
    var awsCredentialsDetail: String = ""
    var sessionManagerPlugin: Bool = false

    // MFA is a policy requirement, not an install step — tracked separately
    // so a missing session shows an "Authenticate" action, not a "Fix →" link.
    var mfaRequired: Bool = false
    var mfaSessionActive: Bool = false
    var mfaDetail: String = ""

    var toolingReady: Bool {
        awsCLI && awsCredentials && sessionManagerPlugin
    }

    var mfaReady: Bool { !mfaRequired || mfaSessionActive }

    var allGood: Bool { toolingReady && mfaReady }
}

class DependencyChecker {
    static let shared = DependencyChecker()

    // Shells out to `aws --version`, so never call this on the main thread.
    func checkAsync() async -> DependencyStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.check())
            }
        }
    }

    func check() -> DependencyStatus {
        print("🔍 DependencyChecker.check() called")
        var status = DependencyStatus()

        // ── 1. AWS CLI ───────────────────────────────────────
        // Check common install paths directly instead of relying on PATH
        let awsPaths = [
            "/usr/local/bin/aws",
            "/opt/homebrew/bin/aws",
            "/usr/bin/aws",
            "/opt/local/bin/aws"
        ]
        if let awsPath = awsPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let awsResult = run(awsPath, args: ["--version"])
            print("🔍 AWS CLI check: \(awsResult)")
            if awsResult.contains("aws-cli") {
                status.awsCLI = true
                status.awsCLIVersion = awsResult.components(separatedBy: " ").first ?? ""
            }
        } else {
            print("🔍 AWS CLI not found in any known path")
        }

        // ── 2. AWS credentials — check file/env/config ──────
        let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/credentials")
        let credentialsExist = FileManager.default.fileExists(atPath: credentialsFile.path)

        let envCredentials = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil &&
                             ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] != nil

        let configFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")
        let configContent = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let hasSSOorProcess = configContent.contains("sso_start_url") ||
                              configContent.contains("credential_process") ||
                              configContent.contains("role_arn")

        status.awsCredentials = credentialsExist || envCredentials || hasSSOorProcess
        status.awsCredentialsDetail = status.awsCredentials ? "Configured" : "Run `aws configure`"

        // ── 3. Session Manager Plugin ────────────────────────
        let pluginPaths = [
            "/usr/local/sessionmanagerplugin/bin/session-manager-plugin",
            "/usr/local/bin/session-manager-plugin",
            "/opt/homebrew/bin/session-manager-plugin"
        ]
        status.sessionManagerPlugin = pluginPaths.contains {
            FileManager.default.fileExists(atPath: $0)
        }
        print("🔍 Session Manager Plugin: \(status.sessionManagerPlugin)")

        // ── 4. MFA session ───────────────────────────────────
        status.mfaRequired = SettingsManager.shared.requireMFA
        if status.mfaRequired {
            let profiles = Set(ConnectionStore.shared.load().map { $0.profile.isEmpty ? "default" : $0.profile })
            // Read-only check — pruning expired sessions here would bump the
            // session revision and re-trigger this very check.
            let active = profiles.filter { AWSSession.shared.session(for: $0)?.isValid == true }

            status.mfaSessionActive = !profiles.isEmpty && active.count == profiles.count
            if profiles.isEmpty {
                status.mfaSessionActive = true
                status.mfaDetail = "No connections yet"
            } else if status.mfaSessionActive {
                status.mfaDetail = "Session active"
            } else {
                let pending = profiles.subtracting(active).sorted().joined(separator: ", ")
                status.mfaDetail = "MFA needed: \(pending)"
            }
            print("🔍 MFA session: \(status.mfaDetail)")
        }

        return status
    }

    private func run(_ command: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        try? process.run()
        process.waitUntilExit()

        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
