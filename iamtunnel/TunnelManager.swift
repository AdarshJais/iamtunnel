import Foundation

class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    // Reserved before the MFA prompt so a second click can't start a duplicate
    // process on the same local port.
    private static let reservedPID: Int32 = -1

    private var pids: [UUID: Int32] = [:]
    // pids is touched from the main thread, the cooperative pool and
    // Process.terminationHandler, so every access goes through this queue.
    private let lock = DispatchQueue(label: "com.iamtunnel.pids")

    private func currentPID(for id: UUID) -> Int32? {
        lock.sync { pids[id] }
    }

    private func setPID(_ pid: Int32?, for id: UUID) {
        lock.sync {
            if let pid { pids[id] = pid } else { pids.removeValue(forKey: id) }
        }
    }

    // Clears the entry only if it still holds the PID that just died —
    // a late handler from an old process must not wipe a newer attempt.
    private func clearPID(_ pid: Int32, for id: UUID) -> Bool {
        lock.sync {
            guard pids[id] == pid else { return false }
            pids.removeValue(forKey: id)
            return true
        }
    }

    // Reserves a slot only if the tunnel is idle.
    private func reserve(_ id: UUID) -> Bool {
        lock.sync {
            guard pids[id] == nil else { return false }
            pids[id] = TunnelManager.reservedPID
            return true
        }
    }

    // ── Connect ──────────────────────────────────────────────
    func connect(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
        guard reserve(tunnel.id) else { return }

        onStatusChange(.starting)

        Task {
            // MFA gate — org policy requires an MFA-authenticated session
            // for CLI actions, so get one before spending time on lookups.
            if SettingsManager.shared.requireMFA,
               AWSSession.shared.validSession(for: tunnel.profile) == nil {
                let authenticated = await MFACoordinator.shared.ensureSession(for: tunnel.profile)
                guard authenticated else {
                    setPID(nil, for: tunnel.id)
                    await MainActor.run { onStatusChange(.stopped) }
                    return
                }
            }

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
                    setPID(nil, for: tunnel.id)
                    await MainActor.run { onStatusChange(.stopped) }
                    return
                }
                target = resolved
            }

            let params = """
            {"host":["\(tunnel.remoteHost)"],"portNumber":["\(tunnel.remotePort)"],"localPortNumber":["\(tunnel.localPort)"]}
            """

            let args = [
                "ssm", "start-session",
                "--target", target,
                "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
                "--parameters", params,
                "--region", tunnel.region
            ]

            // AWSCLI injects AWS_SESSION_TOKEN when a session is cached,
            // and falls back to --profile when MFA is not in use.
            let process = AWSCLI.shared.makeProcess(args: args, profile: tunnel.profile)

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { [weak self] p in
                let ended = p.processIdentifier
                print("❌ Process terminated: \(ended)")
                guard self?.clearPID(ended, for: tunnel.id) == true else { return }
                DispatchQueue.main.async { onStatusChange(.stopped) }
            }

            // Set when stderr reports a credential problem, so the 3s fallback
            // below doesn't paint the row green while the MFA prompt is open.
            let authFailed = AuthFailureFlag()

            do {
                try process.run()
                let pid = process.processIdentifier
                setPID(pid, for: tunnel.id)
                print("✅ Started SSM tunnel PID: \(pid)")

                // Watch stdout for ready signal. Keep draining after the signal —
                // an unread pipe eventually fills and blocks the child process.
                Task {
                    var announced = false
                    for try await line in outPipe.fileHandleForReading.bytes.lines {
                        print("SSM OUT: \(line)")
                        if !announced, line.contains("Waiting for connections") {
                            announced = true
                            await MainActor.run { onStatusChange(.connected) }
                        }
                    }
                }

                // Watch stderr — an expired or missing MFA session shows up
                // here, and re-prompting is more useful than a silent stop.
                Task {
                    var prompted = false
                    for try await line in errPipe.fileHandleForReading.bytes.lines {
                        print("SSM ERR: \(line)")
                        let error = AWSCLIResult(stdout: "", stderr: line, exitCode: 1)
                        if !prompted, error.needsMFA {
                            prompted = true
                            await authFailed.set()
                            AWSSession.shared.clearSession(for: tunnel.profile)
                            await MainActor.run { onStatusChange(.stopped) }
                            await MFACoordinator.shared.promptExpired(profile: tunnel.profile)
                        }
                    }
                }

                // Fallback: mark connected after 3s if no stdout signal
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let credentialsRejected = await authFailed.value
                if currentPID(for: tunnel.id) != nil, !credentialsRejected {
                    await MainActor.run { onStatusChange(.connected) }
                }

            } catch {
                print("❌ Failed to start process: \(error)")
                setPID(nil, for: tunnel.id)
                await MainActor.run { onStatusChange(.stopped) }
            }
        }
    }

    // ── Disconnect ───────────────────────────────────────────
    func disconnect(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
        guard let pid = currentPID(for: tunnel.id), pid != TunnelManager.reservedPID else {
            print("⚠️ No PID found for tunnel \(tunnel.name)")
            setPID(nil, for: tunnel.id)
            onStatusChange(.stopped)
            return
        }

        print("🛑 Killing PID \(pid) and group")
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        setPID(nil, for: tunnel.id)
        onStatusChange(.stopped)
    }

    // ── Disconnect all ───────────────────────────────────────
    func disconnectAll() {
        let snapshot = lock.sync { pids }
        print("🛑 Disconnecting all tunnels: \(snapshot)")
        for (_, pid) in snapshot where pid != TunnelManager.reservedPID {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        lock.sync { pids.removeAll() }

        // Nuclear fallback
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", "ssm start-session"]
        try? task.run()
        task.waitUntilExit()
    }

    // ── Register an existing tunnel found on launch ──────────
    func registerExisting(tunnel: Tunnel, pid: Int32) {
        setPID(pid, for: tunnel.id)
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
        let args = [
            "ec2", "describe-instances",
            "--filters", "Name=tag:Name,Values=\(tunnel.ssmTarget)",
            "--query", "Reservations[0].Instances[0].InstanceId",
            "--output", "text",
            "--region", tunnel.region
        ]

        let result = await AWSCLI.shared.run(args, profile: tunnel.profile)

        if result.needsMFA {
            AWSSession.shared.clearSession(for: tunnel.profile)
            guard await MFACoordinator.shared.ensureSession(for: tunnel.profile) else {
                debugLog("🔐 MFA not completed — cannot resolve \(tunnel.ssmTarget)")
                return nil
            }
            let retry = await AWSCLI.shared.run(args, profile: tunnel.profile)
            guard retry.succeeded, let id = Self.instanceId(from: retry.output) else {
                debugLog("❌ describe-instances failed after MFA: \(retry.stderr)")
                return nil
            }
            return id
        }

        guard result.succeeded else {
            debugLog("❌ describe-instances failed: \(result.stderr)")
            return nil
        }

        return Self.instanceId(from: result.output)
    }

    private static func instanceId(from output: String) -> String? {
        let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id.isEmpty || id == "None") ? nil : id
    }
}

// Tiny actor so the stderr watcher and the fallback timer can share a flag
// without a data race.
private actor AuthFailureFlag {
    private(set) var value = false
    func set() { value = true }
}
