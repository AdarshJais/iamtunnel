import Foundation

enum TestResult {
    case idle
    case testing
    case success(String)
    case failure(String)
    case mfaRequired(String)
}

class ConnectionTester {
    static let shared = ConnectionTester()

    // Resolves instance ID from Name tag if needed, then checks SSM
    func test(tunnel: Tunnel) async -> TestResult {

        // Step 0 — MFA session must exist before any signed call
        if SettingsManager.shared.requireMFA,
           AWSSession.shared.validSession(for: tunnel.profile) == nil {
            return .mfaRequired("MFA session needed for profile \"\(tunnel.profile)\"")
        }

        // Step 1 — resolve SSM target
        let instanceId: String
        if tunnel.ssmTarget.hasPrefix("i-") {
            instanceId = tunnel.ssmTarget
        } else {
            switch await resolveNameTag(tunnel: tunnel) {
            case .success(let id): instanceId = id
            case .failure(let msg): return .failure(msg)
            case .mfaRequired(let msg): return .mfaRequired(msg)
            default: return .failure("Unknown error")
            }
        }

        // Step 2 — check SSM connectivity
        return await checkSSM(instanceId: instanceId, tunnel: tunnel)
    }

    // ── Verify the MFA session itself ────────────────────────
    // Mirrors `aws sts get-caller-identity` from the runbook.
    func testIdentity(profile: String) async -> TestResult {
        guard let arn = await AWSSession.shared.verifyCallerIdentity(profile: profile) else {
            return .mfaRequired("No valid session for \"\(profile)\" — authenticate with MFA")
        }
        return .success("Authenticated as \(arn)")
    }

    // ── Resolve EC2 Name tag → instance ID ───────────────────
    private func resolveNameTag(tunnel: Tunnel) async -> TestResult {
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
            return .mfaRequired("MFA session expired — authenticate again")
        }

        let id = result.output
        if id.isEmpty || id == "None" {
            return .failure("No instance found with Name tag '\(tunnel.ssmTarget)'")
        }
        return .success(id)
    }

    // ── Quick SSM reachability check ─────────────────────────
    private func checkSSM(instanceId: String, tunnel: Tunnel) async -> TestResult {
        let args = [
            "ssm", "describe-instance-information",
            "--filters", "Key=InstanceIds,Values=\(instanceId)",
            "--query", "InstanceInformationList[0].PingStatus",
            "--output", "text",
            "--region", tunnel.region
        ]

        let result = await AWSCLI.shared.run(args, profile: tunnel.profile)

        if result.needsMFA {
            AWSSession.shared.clearSession(for: tunnel.profile)
            return .mfaRequired("MFA session expired — authenticate again")
        }

        let status = result.output

        if status == "Online" {
            return .success("Instance is online and reachable via SSM")
        } else if status == "None" || status.isEmpty {
            return .failure("Instance not found in SSM — check IAM permissions or SSM agent")
        } else {
            return .failure("Instance SSM status: \(status)")
        }
    }
}
