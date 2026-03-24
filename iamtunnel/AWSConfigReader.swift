import Foundation

struct AWSProfile {
    let name: String
    let region: String?
}

class AWSConfigReader {
    static let shared = AWSConfigReader()

    // Reads ~/.aws/config and returns all profiles
    func loadProfiles() -> [AWSProfile] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return [AWSProfile(name: "default", region: nil)]
        }

        var profiles: [AWSProfile] = []
        var currentName: String? = nil
        var currentRegion: String? = nil

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match [profile my-profile] or [default]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Save previous profile
                if let name = currentName {
                    profiles.append(AWSProfile(name: name, region: currentRegion))
                }
                // Parse new profile name
                let inner = String(trimmed.dropFirst().dropLast())
                currentName = inner.hasPrefix("profile ") ? String(inner.dropFirst(8)) : inner
                currentRegion = nil

            } else if trimmed.hasPrefix("region") {
                // Match region = us-east-1
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    currentRegion = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Save last profile
        if let name = currentName {
            profiles.append(AWSProfile(name: name, region: currentRegion))
        }

        return profiles.isEmpty ? [AWSProfile(name: "default", region: nil)] : profiles
    }

    var profileNames: [String] { loadProfiles().map { $0.name } }

    func region(for profile: String) -> String? {
        loadProfiles().first { $0.name == profile }?.region
    }
}
