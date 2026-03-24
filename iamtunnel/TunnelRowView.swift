import SwiftUI

struct TunnelRowView: View {
    let tunnel: Tunnel
    var onToggle: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
       
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {

            // ── Icon + status dot ────────────────────────────────
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(tunnel.env == .production
                                ? Color(red: 1.0, green: 0.23, blue: 0.19).opacity(0.6)
                                : Color.primary.opacity(0.45))
                    )
                Circle()
                    .fill(tunnel.status.color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 1, y: 1)
            }

            // ── Name + address ───────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(tunnel.localAddress)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // ── Pill on hover ────────────────────────────────────
            if isHovered && tunnel.status != .starting {
                Text(tunnel.status == .connected ? "Stop" : "Connect")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { onToggle() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button("Edit…") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        ForEach(Tunnel.samples) { t in
            TunnelRowView(tunnel: t)
        }
    }
    .frame(width: 320)
}
