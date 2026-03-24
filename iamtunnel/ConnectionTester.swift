import Foundation

enum TestResult {
    case idle
    case testing
    case success(String)
    case failure(String)
}

class ConnectionTester {
    static let shared = ConnectionTester()

    // Resolves instance ID from Name tag if needed, then checks SSM
    func test(tunnel: Tunnel) async -> TestResult {

        // Step 1 — resolve SSM target
        let instanceId: String
        if tunnel.ssmTarget.hasPrefix("i-") {
            instanceId = tunnel.ssmTarget
        } else {
            switch await resolveNameTag(tunnel: tunnel) {
            case .success(let id): instanceId = id
            case .failure(let msg): return .failure(msg)
            default: return .failure("Unknown error")
            }
        }

        // Step 2 — check SSM connectivity
        return await checkSSM(instanceId: instanceId, tunnel: tunnel)
    }

    // ── Resolve EC2 Name tag → instance ID ───────────────────
    private func resolveNameTag(tunnel: Tunnel) async -> TestResult {
        var args = [
            "ec2", "describe-instances",
            "--filters", "Name=tag:Name,Values=\(tunnel.ssmTarget)",
            "--query", "Reservations[0].Instances[0].InstanceId",
            "--output", "text",
            "--region", tunnel.region
        ]
        if !tunnel.profile.isEmpty { args += ["--profile", tunnel.profile] }

        let result = await run("aws", args: args)
        let id = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if id.isEmpty || id == "None" {
            return .failure("No instance found with Name tag '\(tunnel.ssmTarget)'")
        }
        return .success(id)
    }

    // ── Quick SSM reachability check ─────────────────────────
    private func checkSSM(instanceId: String, tunnel: Tunnel) async -> TestResult {
        var args = [
            "ssm", "describe-instance-information",
            "--filters", "Key=InstanceIds,Values=\(instanceId)",
            "--query", "InstanceInformationList[0].PingStatus",
            "--output", "text",
            "--region", tunnel.region
        ]
        if !tunnel.profile.isEmpty { args += ["--profile", tunnel.profile] }

        let result = await run("aws", args: args)
        let status = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if status == "Online" {
            return .success("Instance is online and reachable via SSM")
        } else if status == "None" || status.isEmpty {
            return .failure("Instance not found in SSM — check IAM permissions or SSM agent")
        } else {
            return .failure("Instance SSM status: \(status)")
        }
    }

    // ── Generic process runner ────────────────────────────────
    @discardableResult
    private func run(_ command: String, args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args

            // Inherit PATH so aws is found
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
            process.environment = env

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
