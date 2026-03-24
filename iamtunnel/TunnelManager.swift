import Foundation

class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    private var pids: [UUID: Int32] = [:]

    // ── Connect ──────────────────────────────────────────────
    func connect(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
        guard pids[tunnel.id] == nil else { return }

        onStatusChange(.starting)

        Task {
            // Check if port is already in use and kill it
            if let existingPid = portInUse(tunnel.localPort) {
                print("⚠️ Port \(tunnel.localPort) already in use by PID \(existingPid) — killing it")
                kill(existingPid, SIGKILL)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // Resolve instance ID if Name tag was given
            let target: String
            if tunnel.ssmTarget.hasPrefix("i-") {
                target = tunnel.ssmTarget
            } else {
                guard let resolved = await resolveNameTag(tunnel: tunnel) else {
                    await MainActor.run { onStatusChange(.stopped) }
                    return
                }
                target = resolved
            }

            let params = """
            {"host":["\(tunnel.remoteHost)"],"portNumber":["\(tunnel.remotePort)"],"localPortNumber":["\(tunnel.localPort)"]}
            """

            var args = [
                "aws", "ssm", "start-session",
                "--target", target,
                "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
                "--parameters", params,
                "--region", tunnel.region
            ]
            if !tunnel.profile.isEmpty {
                args += ["--profile", tunnel.profile]
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { [weak self] p in
                print("❌ Process terminated: \(p.processIdentifier)")
                self?.pids.removeValue(forKey: tunnel.id)
                DispatchQueue.main.async { onStatusChange(.stopped) }
            }

            do {
                try process.run()
                let pid = process.processIdentifier
                pids[tunnel.id] = pid
                print("✅ Started SSM tunnel PID: \(pid)")

                // Watch stdout for ready signal
                Task {
                    for try await line in outPipe.fileHandleForReading.bytes.lines {
                        print("SSM OUT: \(line)")
                        if line.contains("Waiting for connections") {
                            await MainActor.run { onStatusChange(.connected) }
                            return
                        }
                    }
                }

                // Fallback: mark connected after 3s if no stdout signal
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if pids[tunnel.id] != nil {
                    await MainActor.run { onStatusChange(.connected) }
                }

            } catch {
                print("❌ Failed to start process: \(error)")
                pids.removeValue(forKey: tunnel.id)
                await MainActor.run { onStatusChange(.stopped) }
            }
        }
    }

    // ── Disconnect ───────────────────────────────────────────
    func disconnect(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
        guard let pid = pids[tunnel.id] else {
            print("⚠️ No PID found for tunnel \(tunnel.name)")
            onStatusChange(.stopped)
            return
        }

        print("🛑 Killing PID \(pid) and group")
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        pids.removeValue(forKey: tunnel.id)
        onStatusChange(.stopped)
    }

    // ── Disconnect all ───────────────────────────────────────
    func disconnectAll() {
        print("🛑 Disconnecting all tunnels: \(pids)")
        for (_, pid) in pids {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        pids.removeAll()

        // Nuclear fallback
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", "ssm start-session"]
        try? task.run()
        task.waitUntilExit()
    }

    // ── Register an existing tunnel found on launch ──────────
    func registerExisting(tunnel: Tunnel, pid: Int32) {
        pids[tunnel.id] = pid
        print("📌 Registered existing tunnel \(tunnel.name) PID \(pid)")
    }

    // ── Check if port is already in use (public) ─────────────
    // Only returns the LISTENING process — ignores clients like DBeaver
    func portInUse(_ port: Int) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "tcp:\(port)", "-s", "TCP:LISTEN", "-t"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Int32(output.split(separator: "\n").first ?? "")
    }

    // ── Resolve EC2 Name tag → instance ID ───────────────────
    private func resolveNameTag(tunnel: Tunnel) async -> String? {
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
        return (id.isEmpty || id == "None") ? nil : id
    }

    // ── Generic process runner ────────────────────────────────
    @discardableResult
    private func run(_ command: String, args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

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
