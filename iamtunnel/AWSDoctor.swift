import AppKit
import Foundation

// A plain-English cause for an AWS failure, with one fix the user can click.
struct Diagnosis: Equatable {
    enum Fix: Equatable {
        case removeSessionToken(profile: String)
        case openAccessKeys
        case openMFADevices
        case openDateTime
        case runInTerminal(String)
        case none
    }

    let title: String
    let detail: String
    let fix: Fix
    // For people who want to debug: the raw AWS message, or what was checked.
    var technical: String? = nil

    func with(technical value: String?) -> Diagnosis {
        var copy = self
        if copy.technical == nil, let value, !value.isEmpty { copy.technical = value }
        return copy
    }

    var fixLabel: String? {
        switch fix {
        case .removeSessionToken: return "Remove it"
        case .openAccessKeys:     return "Open AWS keys page"
        case .openMFADevices:     return "Open AWS MFA page"
        case .openDateTime:       return "Open Date & Time"
        case .runInTerminal:      return "Open Terminal"
        case .none:               return nil
        }
    }
}

// Finds the usual reasons AWS calls fail on a laptop and how to fix them.
// Reads ~/.aws files only to look for keys and leftover session tokens; it never
// shows or logs secret values.
enum AWSDoctor {
    static let securityCredentialsURL = URL(string: "https://console.aws.amazon.com/iam/home#/security_credentials")!
    static let maxClockSkew: TimeInterval = 30

    // ── Instant checks (files only) ───────────────────────────
    static func preflight(profile: String) -> Diagnosis? {
        let name = normalized(profile)
        let creds = section(name, in: credentialsURL, configStyle: false)
        let config = section(name, in: configURL, configStyle: true)

        if creds?["aws_session_token"] != nil || creds?["aws_security_token"] != nil {
            return Diagnosis(
                title: "Your \(name) profile has a leftover temporary token",
                detail: "~/.aws/credentials has an aws_session_token line under [\(name)], usually from an old MFA script. AWS then rejects your permanent key. iamtunnel can remove that line (it keeps a backup of the file).",
                fix: .removeSessionToken(profile: name),
                technical: "\(credentialsURL.path) → [\(name)] contains aws_session_token. The AWS CLI signs with the permanent key plus this stale token, so STS answers InvalidClientTokenId.")
        }

        let configProvidesCredentials = config.map { section in
            section.keys.contains { key in
                ["credential_process", "role_arn", "source_profile", "sso_start_url", "sso_session",
                 "aws_access_key_id"].contains(key)
            }
        } ?? false
        if creds?["aws_access_key_id"] == nil, !configProvidesCredentials {
            return missingKeys(name).with(technical:
                "No aws_access_key_id under [\(name)] in \(credentialsURL.path), and no credential_process, role or SSO settings for it in \(configURL.path).")
        }
        return nil
    }

    // ── Real check: are the permanent keys accepted? ──────────
    // Returns the caller ARN, or why it failed.
    static func checkKeys(profile: String) async -> (arn: String?, diagnosis: Diagnosis?) {
        if let early = preflight(profile: profile) { return (nil, early) }
        let result = await AWSCLI.shared.run(
            ["sts", "get-caller-identity", "--query", "Arn", "--output", "text"],
            profile: profile, useSession: false)
        if result.succeeded, result.output.hasPrefix("arn:") { return (result.output, nil) }
        return (nil, await diagnose(profile: profile, stderr: result.stderr)
                ?? Diagnosis(title: "AWS didn't accept your keys",
                             detail: "See the AWS error below.",
                             fix: .openAccessKeys,
                             technical: rawError(result.stderr)))
    }

    // ── Explain an error message from the AWS CLI ─────────────
    static func diagnose(profile: String, stderr: String) async -> Diagnosis? {
        await explain(profile: profile, stderr: stderr)?.with(technical: rawError(stderr))
    }

    private static func explain(profile: String, stderr: String) async -> Diagnosis? {
        let name = normalized(profile)
        if let early = preflight(profile: name) { return early }
        let text = stderr

        if text.contains("InvalidClientTokenId") {
            return Diagnosis(
                title: "AWS doesn't recognise your access key",
                detail: "The access key in the \(name) profile is deactivated, deleted or mistyped. Create a new key on the AWS keys page, then run aws configure with it.",
                fix: .openAccessKeys)
        }
        if text.contains("SignatureDoesNotMatch") {
            return Diagnosis(
                title: "Your secret key doesn't match the access key",
                detail: "The secret access key in the \(name) profile is wrong. Run aws configure and paste both keys again.",
                fix: .runInTerminal(configureCommand(name)))
        }
        if text.contains("Unable to locate credentials") || text.contains("could not be found") {
            return missingKeys(name)
        }
        if text.contains("invalid MFA one time pass code") {
            if let skew = await clockSkew(), abs(skew) > maxClockSkew {
                let minutes = max(1, Int((abs(skew) / 60).rounded()))
                return Diagnosis(
                    title: "Your Mac's clock is \(minutes) min \(skew > 0 ? "fast" : "slow")",
                    detail: "MFA codes only work when the clock is within about 30 seconds of the real time. Turn on \"Set time and date automatically\", then use a fresh code.",
                    fix: .openDateTime)
            }
            return nil // a genuinely wrong or reused code: the prompt says so
        }
        if text.contains("AccessDenied"), text.contains("MultiFactorAuthAge")
            || (text.contains("explicit deny") && text.lowercased().contains("multifactor")) {
            return Diagnosis(
                title: "Your company limits how old an MFA login can be",
                detail: "AWS accepted the long session, but a company policy refuses MFA logins older than a set age (often 12 h). Renew now, and pick a shorter session length next time.",
                fix: .none)
        }
        if text.contains("AccessDenied") && text.contains("GetSessionToken") {
            return Diagnosis(
                title: "Your AWS user isn't allowed to start MFA sessions",
                detail: "This is a permission on your IAM user, not something on this Mac. Ask whoever manages AWS access to allow sts:GetSessionToken.",
                fix: .none)
        }
        if text.contains("Could not connect to the endpoint URL") || text.contains("Connect timeout") {
            return Diagnosis(
                title: "Can't reach AWS",
                detail: "Check your internet connection, VPN or proxy, then try again.",
                fix: .none)
        }
        return nil
    }

    // Seconds the Mac's clock is ahead (+) or behind (−) AWS, from the HTTP Date header.
    static func clockSkew() async -> TimeInterval? {
        var request = URLRequest(url: URL(string: "https://sts.amazonaws.com/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let serverDate = formatter.date(from: header) else { return nil }
        return Date().timeIntervalSince(serverDate)
    }

    // ── Apply a fix ───────────────────────────────────────────
    @MainActor
    @discardableResult
    static func apply(_ fix: Diagnosis.Fix) -> Bool {
        switch fix {
        case .removeSessionToken(let profile):
            return removeSessionToken(profile: profile)
        case .openAccessKeys, .openMFADevices:
            NSWorkspace.shared.open(securityCredentialsURL)
        case .openDateTime:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!)
        case .runInTerminal(let command):
            openInTerminal(command)
        case .none:
            return false
        }
        return true
    }

    // Opens Terminal running `command`, so the user sees it and types any input
    // (keys, password) themselves.
    @MainActor
    static func openInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iamtunnel-setup.command")
        let script = "#!/bin/zsh -l\necho '$ \(command)'\n\(command)\necho\necho 'Done. You can close this window and return to iamtunnel.'\n"
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    static func configureCommand(_ profile: String) -> String {
        profile == "default" ? "aws configure" : "aws configure --profile \(profile)"
    }

    // ── Helpers ───────────────────────────────────────────────
    private static func missingKeys(_ name: String) -> Diagnosis {
        Diagnosis(
            title: "No AWS keys for the \(name) profile",
            detail: "Run aws configure and paste the access key and secret from your IAM user and your region. Don't have keys yet? Ask whoever manages AWS access.",
            fix: .runInTerminal(configureCommand(name)))
    }

    private static func normalized(_ profile: String) -> String {
        profile.isEmpty ? "default" : profile
    }

    // The AWS CLI's own message, trimmed (it never contains secret values).
    static func rawError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(1500))
    }

    static var credentialsURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AWS_SHARED_CREDENTIALS_FILE"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/credentials")
    }

    static var configURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
    }

    // Keys (lowercased) of one INI section; nil when the section doesn't exist.
    // In ~/.aws/config, non-default profiles are written [profile name].
    private static func section(_ name: String, in url: URL, configStyle: Bool) -> [String: String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let headers = configStyle && name != "default" ? ["profile \(name)"] : [name]
        var inSection = false
        var found = false
        var values: [String: String] = [:]
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                inSection = headers.contains(header)
                if inSection { found = true }
                continue
            }
            guard inSection, !line.hasPrefix("#"), !line.hasPrefix(";"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            values[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return found ? values : nil
    }

    // Deletes aws_session_token / aws_security_token lines under [profile] in
    // ~/.aws/credentials, after copying the file to a timestamped backup.
    private static func removeSessionToken(profile: String) -> Bool {
        let url = credentialsURL
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }

        let stamp = { () -> String in
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("credentials.iamtunnel-backup-\(stamp)")
        guard (try? FileManager.default.copyItem(at: url, to: backup)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)

        var inSection = false
        var kept: [String] = []
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) == profile
            } else if inSection, let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "aws_session_token" || key == "aws_security_token" { continue }
            }
            kept.append(raw)
        }
        guard (try? kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        debugLog("🩺 Removed leftover session token from [\(profile)]; backup at \(backup.lastPathComponent)")
        return true
    }
}
