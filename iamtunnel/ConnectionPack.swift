import AppKit
import Foundation

// A shareable list of tunnels, so a team can hand new members one file instead
// of everyone typing bastion ids and database hosts by hand. It holds no secrets:
// credentials stay in each person's AWS profile.
//
// {
//   "format": "iamtunnel-connections/1",
//   "name": "Acme staging",
//   "connections": [
//     { "name": "Orders DB", "profile": "default", "region": "ap-south-1",
//       "ssmTarget": "i-0123456789abcdef0", "remoteHost": "orders.xyz.rds.amazonaws.com",
//       "remotePort": 3306, "localPort": 3306, "env": "staging" }
//   ]
// }
//
// A plain array of connections (like iamtunnel's own connections.json) also imports.
struct ConnectionPack: Codable {
    static let formatID = "iamtunnel-connections/1"

    var format: String?
    var name: String?
    var connections: [Entry]

    struct Entry: Codable {
        var name: String
        var profile: String?
        var region: String
        var ssmTarget: String
        var remoteHost: String
        var remotePort: Int
        var localPort: Int
        var env: String?

        var problem: String? {
            if name.trimmingCharacters(in: .whitespaces).isEmpty { return "no name" }
            if ssmTarget.isEmpty || remoteHost.isEmpty || region.isEmpty { return "missing target, host or region" }
            if !(1...65535).contains(remotePort) || !(1...65535).contains(localPort) { return "invalid port" }
            return nil
        }

        var tunnelEnv: TunnelEnv { env.flatMap { TunnelEnv(rawValue: $0.lowercased()) } ?? .dev }

        func makeTunnel() -> Tunnel {
            Tunnel(name: name.trimmingCharacters(in: .whitespaces),
                   profile: (profile?.isEmpty == false) ? profile! : "default",
                   region: region, ssmTarget: ssmTarget, remoteHost: remoteHost,
                   remotePort: remotePort, localPort: localPort, env: tunnelEnv)
        }

        init(_ t: Tunnel) {
            name = t.name; profile = t.profile; region = t.region; ssmTarget = t.ssmTarget
            remoteHost = t.remoteHost; remotePort = t.remotePort; localPort = t.localPort
            env = t.env.rawValue
        }
    }

    static func decode(_ data: Data) -> ConnectionPack? {
        let decoder = JSONDecoder()
        if let pack = try? decoder.decode(ConnectionPack.self, from: data) { return pack }
        if let list = try? decoder.decode([Entry].self, from: data) {
            return ConnectionPack(format: nil, name: nil, connections: list)
        }
        return nil
    }
}

// Import always shows what will be added and waits for a click, including when
// started by an iamtunnel://import link: a link must not add tunnels silently.
@MainActor
enum ConnectionImporter {
    private static let maxFileBytes = 1_000_000
    private static let maxEntries = 100

    static func importFile(at url: URL) {
        guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes,
              let pack = ConnectionPack.decode(data), !pack.connections.isEmpty,
              pack.connections.count <= maxEntries else {
            showInfo("Couldn't import \(url.lastPathComponent)",
                     "The file isn't an iamtunnel connections file, or it's empty.")
            return
        }

        let existing = ConnectionStore.shared.load()
        var toAdd: [Tunnel] = []
        var skipped: [String] = []
        for entry in pack.connections {
            if let problem = entry.problem {
                skipped.append("\(entry.name.isEmpty ? "(unnamed)" : entry.name): \(problem)")
                continue
            }
            let tunnel = entry.makeTunnel()
            let all = existing + toAdd
            if all.contains(where: { $0.name.lowercased() == tunnel.name.lowercased() }) {
                skipped.append("\(tunnel.name): already saved")
            } else if let clash = all.first(where: { $0.localPort == tunnel.localPort }) {
                skipped.append("\(tunnel.name): localhost:\(tunnel.localPort) is used by \(clash.name)")
            } else {
                toAdd.append(tunnel)
            }
        }

        let source = pack.name ?? url.lastPathComponent
        guard !toAdd.isEmpty else {
            showInfo("Nothing to add from \(source)", skipped.map { "• \($0)" }.joined(separator: "\n"))
            return
        }

        guard ImportPreview.confirm(source: source, fileName: url.lastPathComponent,
                                    toAdd: toAdd, skipped: skipped) else { return }

        ConnectionStore.shared.save(existing + toAdd)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
        debugLog("📥 Imported \(toAdd.count) tunnels from \(source)")
    }

    static func chooseAndImport() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an iamtunnel connections file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(at: url)
    }

    static func chooseAndExport() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "iamtunnel-connections.json"
        panel.message = "Exports names, targets, hosts and ports. No credentials are included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pack = ConnectionPack(format: ConnectionPack.formatID, name: nil,
                                  connections: ConnectionStore.shared.load().map(ConnectionPack.Entry.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(pack) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func showInfo(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

extension Notification.Name {
    static let connectionsChanged = Notification.Name("connectionsChanged")
}
