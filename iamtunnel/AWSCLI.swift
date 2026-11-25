import Foundation

// ── Result of an aws CLI invocation ──────────────────────────
struct AWSCLIResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

    // True when AWS rejected the call because no MFA-authenticated
    // session was presented, or the session token has expired.
    // Deliberately narrow: a broad AccessDenied usually means a missing IAM
    // permission, and treating that as an MFA problem loops the user through
    // codes forever instead of showing the real error.
    var needsMFA: Bool {
        let text = (stdout + stderr)
        let markers = [
            "MultiFactorAuthentication",
            "ExpiredToken",
            "ExpiredTokenException",
            "RequestExpired"
        ]
        if markers.contains(where: { text.contains($0) }) { return true }
        return text.contains("AccessDenied") && text.contains("aws:MultiFactorAuthPresent")
    }
}

// Central place that builds and runs `aws` commands so every call site
// picks up MFA session credentials the same way.
final class AWSCLI {
    static let shared = AWSCLI()

    private let searchPaths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/opt/local/bin"
    ]

    // ── Base environment with a sane PATH ────────────────────
    private func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        // Never inherit a stale session from the launching environment.
        env.removeValue(forKey: "AWS_ACCESS_KEY_ID")
        env.removeValue(forKey: "AWS_SECRET_ACCESS_KEY")
        env.removeValue(forKey: "AWS_SESSION_TOKEN")
        env.removeValue(forKey: "AWS_SECURITY_TOKEN")
        return env
    }

    // Builds arguments + environment for a profile.
    //
    // When an MFA session is cached for the profile we pass the temporary
    // credentials as environment variables and deliberately omit --profile:
    // the AWS CLI prefers a named profile's static keys over env credentials,
    // which would send the request without the MFA session token.
    // `useSession: false` forces the profile's long-term keys — required when
    // calling sts get-session-token, which cannot be signed with a session token.
    func prepare(args: [String], profile: String, useSession: Bool = true) -> (args: [String], env: [String: String]) {
        var env = baseEnvironment()
        var finalArgs = args

        if useSession, let session = AWSSession.shared.validSession(for: profile) {
            env["AWS_ACCESS_KEY_ID"] = session.accessKeyId
            env["AWS_SECRET_ACCESS_KEY"] = session.secretAccessKey
            env["AWS_SESSION_TOKEN"] = session.sessionToken
        } else if !profile.isEmpty {
            finalArgs += ["--profile", profile]
        }

        // Without --profile the region no longer comes from ~/.aws/config, and a
        // Finder-launched app inherits no AWS_DEFAULT_REGION. Set it explicitly
        // unless the caller already passed --region.
        if !finalArgs.contains("--region"), env["AWS_DEFAULT_REGION"] == nil {
            env["AWS_DEFAULT_REGION"] =
                AWSConfigReader.shared.region(for: profile.isEmpty ? "default" : profile) ?? "us-east-1"
        }

        return (finalArgs, env)
    }

    // ── Run and wait ────────────────────────────────────────
    @discardableResult
    func run(_ args: [String], profile: String = "", useSession: Bool = true) async -> AWSCLIResult {
        let prepared = prepare(args: args, profile: profile, useSession: useSession)
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["aws"] + prepared.args
            process.environment = prepared.env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()

                // Drain both pipes concurrently — reading one to EOF before the
                // other deadlocks as soon as the unread pipe's buffer fills.
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: AWSCLIResult(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                ))
            } catch {
                continuation.resume(returning: AWSCLIResult(
                    stdout: "",
                    stderr: "Failed to launch aws: \(error.localizedDescription)",
                    exitCode: -1
                ))
            }
        }
    }

    // ── Long-running process (tunnels) ──────────────────────
    // Caller owns the process lifecycle; we only build it.
    func makeProcess(args: [String], profile: String) -> Process {
        let prepared = prepare(args: args, profile: profile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["aws"] + prepared.args
        process.environment = prepared.env
        return process
    }
}
