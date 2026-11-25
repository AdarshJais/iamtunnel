import AppKit
import SwiftUI

// Confirm sheet for importing a connections file: one tidy row per tunnel
// (full host on hover), anything skipped below, and an explicit Add button.
struct ImportPreviewView: View {
    let source: String
    let fileName: String
    let toAdd: [Tunnel]
    let skipped: [String]
    var onAdd: () -> Void
    var onCancel: () -> Void

    private var profiles: String {
        Array(Set(toAdd.map(\.profile))).sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ───────────────────────────────────────
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \(toAdd.count) tunnel\(toAdd.count == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .semibold))
                    Text(source == fileName ? fileName : "\(source) · \(fileName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            // ── Tunnels ──────────────────────────────────────
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(toAdd) { t in
                        ImportRow(tunnel: t)
                        if t.id != toAdd.last?.id { Divider().padding(.leading, 20) }
                    }
                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Skipped")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(skipped, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.03))
                    }
                }
            }
            .frame(maxHeight: 280)

            Divider()

            // ── Footer ───────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 11))
                Text("No credentials are imported. These tunnels use your AWS profile \(profiles).")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add \(toAdd.count) tunnel\(toAdd.count == 1 ? "" : "s")", action: onAdd)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
    }
}

private struct ImportRow: View {
    let tunnel: Tunnel

    // "orders-db.abc123.ap-south-1.rds.amazonaws.com" → "orders-db"
    private var shortHost: String {
        tunnel.remoteHost.split(separator: ".").first.map(String.init) ?? tunnel.remoteHost
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tunnel.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(tunnel.env.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tunnel.env.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(tunnel.env.color.opacity(0.14))
                        .clipShape(Capsule())
                }
                Text("\(shortHost) : \(String(tunnel.remotePort))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(tunnel.remoteHost):\(tunnel.remotePort) via \(tunnel.ssmTarget) (\(tunnel.region))")
            }
            Spacer()
            Text(tunnel.localAddress)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}

// Shows the sheet as a modal window and returns true when Add is clicked.
@MainActor
enum ImportPreview {
    static func confirm(source: String, fileName: String, toAdd: [Tunnel], skipped: [String]) -> Bool {
        var added = false
        let view = ImportPreviewView(source: source, fileName: fileName, toAdd: toAdd, skipped: skipped) {
            added = true
            NSApp.stopModal()
        } onCancel: {
            NSApp.stopModal()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Import tunnels"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return added
    }
}
