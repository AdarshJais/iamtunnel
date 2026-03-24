import SwiftUI

struct TunnelListView: View {
    @State private var tunnels: [Tunnel] = ConnectionStore.shared.load()
    @State private var connectionWindow: NSWindow?
    @State private var editWindow: NSWindow?
    @State private var depStatus: DependencyStatus = DependencyStatus()

    // ── Dynamic height calculation ───────────────────────────
    private let rowHeight: CGFloat = 52
    private let baseHeight: CGFloat = 130  // header + footer + labels
    private let maxHeight: CGFloat = 480
    private let emptyHeight: CGFloat = 250

    private var popoverHeight: CGFloat {
        if tunnels.isEmpty { return emptyHeight }
        let depHeight: CGFloat = depStatus.allGood ? 0 : 44
        return min(baseHeight + depHeight + CGFloat(tunnels.count) * rowHeight, maxHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 4)

            // ── Dependency warning ───────────────────────────
            if !depStatus.allGood {
                DependencyWarningView(status: depStatus)
                Divider()
            }

            // ── New connection ───────────────────────────────
            NewConnectionRow { openNewConnectionWindow() }

            Divider()

            // ── Tunnels label ────────────────────────────────
            Text("Tunnels")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)

            // ── Empty state ──────────────────────────────────
            if tunnels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No connections yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Click + to add one")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            } else {
                ForEach(tunnels.indices, id: \.self) { i in
                    TunnelRowView(tunnel: tunnels[i]) {
                        toggleTunnel(at: i)
                    } onEdit: {
                        openEditWindow(for: tunnels[i])
                    } onDelete: {
                        tunnels.remove(at: i)
                        ConnectionStore.shared.save(tunnels)
                        updatePopoverSize()
                    }
                }
            }

            Spacer()
            Divider()

            // ── Footer ───────────────────────────────────────
            HStack {
                Button("Settings...") {
                    (NSApp.delegate as? AppDelegate)?.openSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                Spacer()
                Button("Quit") {
                    TunnelManager.shared.disconnectAll()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                Text("⌘Q")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            debugLog("👀 TunnelListView appeared")
            depStatus = DependencyChecker.shared.check()
            updatePopoverSize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                detectExistingTunnels()
                postActiveCount()
            }
        }
        .onChange(of: tunnels.count) { _ in
            updatePopoverSize()
        }
    }

    // ── Resize popover to fit content ────────────────────────
    private func updatePopoverSize() {
        let delegate = NSApp.delegate as? AppDelegate
        delegate?.popover?.contentSize = NSSize(width: 320, height: popoverHeight)
    }

    // ── Detect tunnels already running on launch ─────────────
    private func detectExistingTunnels() {
        for i in tunnels.indices {
            if let pid = TunnelManager.shared.portInUse(tunnels[i].localPort) {
                debugLog("🔍 Found existing process on port \(tunnels[i].localPort) PID \(pid)")
                tunnels[i].status = .connected
                TunnelManager.shared.registerExisting(tunnel: tunnels[i], pid: pid)
            }
        }
    }

    // ── Open new connection window ───────────────────────────
    private func openNewConnectionWindow() {
        if connectionWindow == nil {
            let view = NewConnectionView { newTunnel in
                tunnels.append(newTunnel)
                ConnectionStore.shared.save(tunnels)
                connectionWindow?.close()
                connectionWindow = nil
            } onCancel: {
                connectionWindow?.close()
                connectionWindow = nil
            }
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "New Connection"
            window.styleMask = NSWindow.StyleMask([.titled, .closable])
            window.setContentSize(NSSize(width: 400, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            connectionWindow = window
        }
        connectionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── Open edit connection window ──────────────────────────
    private func openEditWindow(for tunnel: Tunnel) {
        editWindow?.close()
        editWindow = nil

        let view = NewConnectionView(editing: tunnel) { updated in
            if let i = tunnels.firstIndex(where: { $0.id == updated.id }) {
                tunnels[i] = updated
                ConnectionStore.shared.save(tunnels)
            }
            editWindow?.close()
            editWindow = nil
        } onCancel: {
            editWindow?.close()
            editWindow = nil
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Edit Connection"
        window.styleMask = NSWindow.StyleMask([.titled, .closable])
        window.setContentSize(NSSize(width: 400, height: 420))
        window.isReleasedWhenClosed = false
        window.center()
        editWindow = window
        editWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── Toggle tunnel connect/disconnect ─────────────────────
    private func toggleTunnel(at index: Int) {
        let tunnel = tunnels[index]
        switch tunnel.status {
        case .stopped:
            TunnelManager.shared.connect(tunnel: tunnel) { newStatus in
                tunnels[index].status = newStatus
                if newStatus == .connected {
                    NotificationManager.shared.notifyConnected(tunnel: tunnel)
                }
                postActiveCount()
            }
        case .connected:
            TunnelManager.shared.disconnect(tunnel: tunnel) { newStatus in
                tunnels[index].status = newStatus
                NotificationManager.shared.notifyDisconnected(tunnel: tunnel)
                postActiveCount()
            }
        case .starting:
            break
        }
    }

    // ── Post active tunnel count to menu bar icon ────────────
    private func postActiveCount() {
        let count = tunnels.filter { $0.status == .connected }.count
        NotificationCenter.default.post(
            name: .tunnelStatusChanged,
            object: nil,
            userInfo: ["activeCount": count]
        )
    }
}

// ── New connection row ───────────────────────────────────────
struct NewConnectionRow: View {
    var action: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07))
                .clipShape(Circle())
            Text("New connection")
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onTapGesture { action() }
    }
}

#Preview {
    TunnelListView()
}
