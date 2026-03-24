import Foundation

class ConnectionStore {
    static let shared = ConnectionStore()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("iamtunnel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    // ── Load ─────────────────────────────────────────────────
    func load() -> [Tunnel] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let tunnels = try? JSONDecoder().decode([Tunnel].self, from: data)
        // Always reset status to stopped on load — tunnels can't be
        // connected across app launches
        return (tunnels ?? []).map {
            var t = $0; t.status = .stopped; return t
        }
    }

    // ── Save ─────────────────────────────────────────────────
    func save(_ tunnels: [Tunnel]) {
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
