import Foundation

// Opens and closes saved tunnels from a link, so scripts and coding agents can
// ask for a tunnel without clicking the menu:
//
//   open -g "iamtunnel://connect?name=Orders%20DB"
//   open -g "iamtunnel://connect?port=3306"
//   open -g "iamtunnel://disconnect?name=Orders%20DB"
//   open "iamtunnel://import?file=/path/to/team-connections.json"   (asks first)
//
// Connect goes through the normal path, so the MFA prompt appears only when the
// session has expired; the caller just waits for the local port to open.
// Production tunnels are refused: a link must not open a production database
// without someone clicking it.
final class URLCommandHandler {
    static let shared = URLCommandHandler()
    private init() {}

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "iamtunnel",
              let command = url.host?.lowercased() else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // iamtunnel://import?file=/absolute/path.json — always asks before adding.
        if command == "import" {
            guard let path = query.first(where: { $0.name == "file" })?.value,
                  path.hasPrefix("/"), path.lowercased().hasSuffix(".json"),
                  FileManager.default.fileExists(atPath: path) else {
                NotificationManager.shared.notifyLinkRejected(
                    reason: "import needs file=/absolute/path/to/connections.json")
                return
            }
            Task { @MainActor in ConnectionImporter.importFile(at: URL(fileURLWithPath: path)) }
            return
        }

        let name = query.first { $0.name == "name" }?.value
        let port = query.first { $0.name == "port" }?.value.flatMap(Int.init)

        guard let tunnel = findTunnel(name: name, port: port) else {
            debugLog("🔗 \(url.absoluteString): no saved tunnel matches")
            NotificationManager.shared.notifyLinkRejected(
                reason: "No saved tunnel named \(name ?? "?") / port \(port.map(String.init) ?? "?")")
            return
        }

        switch command {
        case "connect":
            connect(tunnel)
        case "disconnect":
            TunnelManager.shared.disconnect(tunnel: tunnel) { status in
                Self.broadcast(tunnel: tunnel, status: status)
            }
        default:
            debugLog("🔗 Unknown command \(command)")
        }
    }

    private func connect(_ tunnel: Tunnel) {
        guard tunnel.env != .production else {
            NotificationManager.shared.notifyLinkRejected(
                reason: "\(tunnel.name) is a production tunnel. Open it from the menu.")
            return
        }
        // Already up (this app or another): nothing to do. connect() would
        // otherwise kill whatever owns the port.
        if let pid = TunnelManager.shared.portInUse(tunnel.localPort) {
            TunnelManager.shared.registerExisting(tunnel: tunnel, pid: pid)
            Self.broadcast(tunnel: tunnel, status: .connected)
            return
        }
        TunnelManager.shared.connect(tunnel: tunnel) { status in
            Self.broadcast(tunnel: tunnel, status: status)
            if status == .connected {
                NotificationManager.shared.notifyConnected(tunnel: tunnel)
            }
        }
    }

    private func findTunnel(name: String?, port: Int?) -> Tunnel? {
        let tunnels = ConnectionStore.shared.load()
        if let name {
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = tunnels.first(where: { $0.name.lowercased() == wanted }) { return match }
        }
        if let port { return tunnels.first { $0.localPort == port } }
        return nil
    }

    // Lets the tunnel list update its row and the menu bar count.
    private static func broadcast(tunnel: Tunnel, status: TunnelStatus) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .tunnelStatusChangedByLink,
                object: nil,
                userInfo: ["id": tunnel.id, "status": status.rawValue]
            )
        }
    }
}
