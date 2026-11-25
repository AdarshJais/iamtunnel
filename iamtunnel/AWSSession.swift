import Foundation
import Security

// ── Temporary STS credentials from an MFA challenge ──────────
struct MFASession: Codable {
    let profile: String
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiration: Date

    // Treat a session as dead slightly early so a tunnel never starts
    // with credentials that expire mid-handshake.
    static let safetyMargin: TimeInterval = 120
    // Show the session as "expiring soon" (orange + notification) this early.
    static let warnBefore: TimeInterval = 15 * 60
    var isExpiringSoon: Bool { isValid && remaining <= MFASession.warnBefore }

    var isValid: Bool { expiration.timeIntervalSinceNow > MFASession.safetyMargin }
    var remaining: TimeInterval { max(0, expiration.timeIntervalSinceNow) }

    var remainingLabel: String {
        guard isValid else { return "expired" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m left" : "\(minutes)m left"
    }

    var expiresAtLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: expiration)
    }
}

enum MFAError: LocalizedError {
    case noDevice(String)
    case badSerial(String)
    case invalidCode
    case cliFailure(String)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .noDevice(let profile):
            return "Couldn't find your MFA device ARN for \"\(profile)\". Enter it manually — see AWS Console → Security credentials."
        case .badSerial(let serial):
            return "AWS rejected the device \(serial). Check the ARN and try again."
        case .invalidCode:
            return "That code was rejected. Wait for the next code in your authenticator app and try again."
        case .cliFailure(let message):
            return message
        case .parseFailure:
            return "Could not read the credentials returned by AWS STS."
        }
    }
}

// Owns MFA session lifecycle: device discovery, sts get-session-token,
// and caching the temporary credentials in the Keychain.
final class AWSSession: ObservableObject {
    static let shared = AWSSession()

    // Bumped whenever a session is created or cleared so views refresh.
    @Published private(set) var revision: Int = 0

    private var cache: [String: MFASession] = [:]
    private let queue = DispatchQueue(label: "com.iamtunnel.awssession", attributes: .concurrent)

    private init() {
        cache = Keychain.loadAllSessions()
    }

    // ── Session lookup ──────────────────────────────────────
    func validSession(for profile: String) -> MFASession? {
        let key = profile.isEmpty ? "default" : profile
        guard let session = queue.sync(execute: { cache[key] }) else { return nil }
        guard session.isValid else {
            clearSession(for: key)
            return nil
        }
        return session
    }

    func session(for profile: String) -> MFASession? {
        queue.sync { cache[profile.isEmpty ? "default" : profile] }
    }

    var activeProfiles: [String] {
        queue.sync { cache.keys.sorted() }.filter { validSession(for: $0) != nil }
    }

    func clearSession(for profile: String) {
        let key = profile.isEmpty ? "default" : profile
        queue.sync(flags: .barrier) { cache[key] = nil }
        Keychain.deleteSession(profile: key)
        bumpRevision()
    }

    func clearAllSessions() {
        let keys = queue.sync { Array(cache.keys) }
        queue.sync(flags: .barrier) { cache.removeAll() }
        keys.forEach { Keychain.deleteSession(profile: $0) }
        bumpRevision()
    }

    // Drops sessions that have aged out; returns the affected profiles
    // so the caller can notify and refresh UI.
    @discardableResult
    func pruneExpired() -> [String] {
        let expired = queue.sync { cache.values.filter { !$0.isValid }.map { $0.profile } }
        expired.forEach { clearSession(for: $0) }
        return expired
    }

    private func store(_ session: MFASession) {
        queue.sync(flags: .barrier) { cache[session.profile] = session }
        Keychain.saveSession(session)
        bumpRevision()
    }

    private func bumpRevision() {
        DispatchQueue.main.async { self.revision += 1 }
    }

    // ── MFA device serial (ARN) ─────────────────────────────
    // Cached per profile so we don't hit IAM on every prompt.
    func cachedSerial(for profile: String) -> String? {
        UserDefaults.standard.string(forKey: serialKey(profile))
    }

    func setSerial(_ serial: String, for profile: String) {
        UserDefaults.standard.set(serial, forKey: serialKey(profile))
    }

    private func serialKey(_ profile: String) -> String {
        "mfaSerial.\(profile.isEmpty ? "default" : profile)"
    }

    // aws iam list-mfa-devices --query 'MFADevices[0].SerialNumber' --output text
    // Called without --user-name so IAM infers the caller.
    @discardableResult
    func discoverSerial(for profile: String, force: Bool = false) async -> String? {
        if !force, let cached = cachedSerial(for: profile), !cached.isEmpty { return cached }

        let result = await AWSCLI.shared.run([
            "iam", "list-mfa-devices",
            "--query", "MFADevices[0].SerialNumber",
            "--output", "text"
        ], profile: profile, useSession: false)

        let serial = result.output
        if result.succeeded, serial.hasPrefix("arn:"), !serial.contains("None") {
            setSerial(serial, for: profile)
            return serial
        }

        debugLog("⚠️ MFA device lookup failed for \(profile): \(result.stderr)")

        // Bootstrap case: on accounts that gate every call on
        // aws:MultiFactorAuthPresent, iam:ListMFADevices is itself denied until
        // a session exists. Derive the device ARN from the caller identity —
        // arn:aws:iam::<acct>:user/<name> → arn:aws:iam::<acct>:mfa/<name>.
        if let derived = await deriveSerialFromCallerIdentity(for: profile) {
            setSerial(derived, for: profile)
            return derived
        }

        return nil
    }

    private func deriveSerialFromCallerIdentity(for profile: String) async -> String? {
        let result = await AWSCLI.shared.run([
            "sts", "get-caller-identity",
            "--query", "Arn",
            "--output", "text"
        ], profile: profile, useSession: false)

        let arn = result.output
        guard result.succeeded, arn.contains(":user/") else { return nil }
        return arn.replacingOccurrences(of: ":user/", with: ":mfa/")
    }

    // ── Request temporary credentials ───────────────────────
    // aws sts get-session-token --serial-number <arn> --token-code <otp>
    // `serialOverride` lets the user type the device ARN when IAM lookup is
    // denied and the ARN can't be derived from the caller identity.
    func authenticate(profile: String,
                      tokenCode: String,
                      durationHours: Int,
                      serialOverride: String? = nil) async -> Result<MFASession, MFAError> {

        let key = profile.isEmpty ? "default" : profile

        let resolvedSerial: String?
        if let override = serialOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.hasPrefix("arn:") {
            setSerial(override, for: profile)
            resolvedSerial = override
        } else {
            resolvedSerial = await discoverSerial(for: profile)
        }

        guard let serial = resolvedSerial else {
            return .failure(.noDevice(key))
        }

        let duration = max(900, min(129_600, durationHours * 3600))

        let result = await AWSCLI.shared.run([
            "sts", "get-session-token",
            "--serial-number", serial,
            "--token-code", tokenCode,
            "--duration-seconds", String(duration),
            "--output", "json"
        ], profile: profile, useSession: false)

        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // A wrong serial number is reported the same way as a bad code, so
            // clear the cached ARN and let the user correct it.
            if message.contains("MultiFactorAuthentication failed with invalid MFA one time pass code")
                || message.contains("invalid MFA one time pass code") {
                return .failure(.invalidCode)
            }
            if message.contains("MultiFactorAuthentication failed")
                || message.contains("ValidationError") {
                UserDefaults.standard.removeObject(forKey: serialKey(profile))
                return .failure(.badSerial(serial))
            }
            return .failure(.cliFailure(message.isEmpty ? "aws sts get-session-token failed." : message))
        }

        guard let session = parseSessionToken(result.stdout, profile: key) else {
            return .failure(.parseFailure)
        }

        store(session)
        debugLog("🔐 MFA session for \(key) valid until \(session.expiration)")
        return .success(session)
    }

    // ── Verify the session actually works ───────────────────
    // aws sts get-caller-identity → returns the caller ARN
    func verifyCallerIdentity(profile: String) async -> String? {
        let result = await AWSCLI.shared.run([
            "sts", "get-caller-identity",
            "--query", "Arn",
            "--output", "text"
        ], profile: profile)
        return result.succeeded && result.output.hasPrefix("arn:") ? result.output : nil
    }

    // ── Parse STS JSON ──────────────────────────────────────
    private func parseSessionToken(_ json: String, profile: String) -> MFASession? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creds = root["Credentials"] as? [String: Any],
              let accessKey = creds["AccessKeyId"] as? String,
              let secret = creds["SecretAccessKey"] as? String,
              let token = creds["SessionToken"] as? String
        else { return nil }

        let expiration: Date
        if let raw = creds["Expiration"] as? String {
            expiration = Self.parseISO8601(raw) ?? Date().addingTimeInterval(3600)
        } else if let epoch = creds["Expiration"] as? Double {
            expiration = Date(timeIntervalSince1970: epoch)
        } else {
            expiration = Date().addingTimeInterval(3600)
        }

        return MFASession(profile: profile,
                          accessKeyId: accessKey,
                          secretAccessKey: secret,
                          sessionToken: token,
                          expiration: expiration)
    }

    static func parseISO8601(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// ── Minimal Keychain wrapper for session credentials ─────────
// Temporary credentials never touch UserDefaults or ~/.aws/credentials.
private enum Keychain {
    static let service = "com.iamtunnel.mfa-session"

    static func saveSession(_ session: MFASession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: session.profile
        ]
        SecItemDelete(query as CFDictionary)

        // No kSecAttrAccessible — the macOS file-based keychain rejects it with
        // errSecParam, which would silently stop sessions from persisting.
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            debugLog("⚠️ Keychain save failed for \(session.profile): \(status)")
        }
    }

    static func deleteSession(profile: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadAllSessions() -> [String: MFASession] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let entries = item as? [[String: Any]] else { return [:] }

        var sessions: [String: MFASession] = [:]
        for entry in entries {
            guard let data = entry[kSecValueData as String] as? Data,
                  let session = try? JSONDecoder().decode(MFASession.self, from: data)
            else { continue }
            if session.isValid {
                sessions[session.profile] = session
            } else {
                deleteSession(profile: session.profile)
            }
        }
        return sessions
    }
}
