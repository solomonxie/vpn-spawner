import SwiftUI

/// Top of the ready screen: location chip, the countdown ring as a big power control,
/// status + time left, then Extend and Stop side by side.
struct ControlHub: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var nativeVPN: NativeVPNController
    let session: SessionRecord
    let canConnect: Bool
    @Binding var toast: String?
    @Binding var confirmStop: Bool

    private var ip: String { session.publicIP ?? "—" }
    private var isMine: Bool { nativeVPN.isInstalled(for: ip) }
    private var connected: Bool { isMine && nativeVPN.status == .connected }
    private var busy: Bool { isMine && [.connecting, .disconnecting, .reasserting].contains(nativeVPN.status) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 22) {
                locationChip
                ring
                status
                actions
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: Pieces

    private var locationChip: some View {
        Button {
            UIPasteboard.general.string = ip
            Haptics.success()
            toast = "Copied IP"
        } label: {
            HStack(spacing: 6) {
                Text(CloudVendor.flag(session.region))
                Text(CloudVendor.regionName(session.region)).fontWeight(.semibold)
                Text(ip).monospacedDigit().foregroundStyle(.secondary)
                if session.isDemo { DemoBadge() }
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(CloudVendor.regionName(session.region)), \(ip)")
        .accessibilityHint("Copies the server IP")
    }

    private var ringColor: Color {
        if session.remainingTime < 120 { return .orange }
        return connected ? .green : .accentColor
    }

    private var ring: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.001, 1 - session.progress))
                    .stroke(
                        AngularGradient(colors: [ringColor.opacity(0.6), ringColor], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: session.progress)
                Circle()
                    .fill(connected ? AnyShapeStyle(ringColor.opacity(0.16)) : AnyShapeStyle(.fill.tertiary))
                    .padding(34)
                if busy {
                    ProgressView().controlSize(.large)
                } else if canConnect {
                    Image(systemName: "power")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(connected ? ringColor : .primary)
                } else {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 46, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 228, height: 228)
            .shadow(color: connected ? ringColor.opacity(0.45) : .clear, radius: 22)
            .contentShape(Circle())
            .animation(.snappy, value: connected)
        }
        .buttonStyle(.plain)
        .disabled(!canConnect || busy)
        .accessibilityLabel(connected ? "Disconnect" : "Connect")
        .accessibilityValue("\(session.formattedRemainingTime) left")
    }

    private var statusTitle: String {
        guard canConnect else { return "Server ready" }
        switch (isMine, nativeVPN.status) {
        case (true, .connected): return "Connected"
        case (true, .connecting), (true, .reasserting): return "Connecting…"
        case (true, .disconnecting): return "Disconnecting…"
        default: return "Tap to connect"
        }
    }

    private var status: some View {
        VStack(spacing: 4) {
            Text(statusTitle)
                .font(.headline)
                .foregroundStyle(connected ? Color.green : Color.secondary)
            Text(session.formattedRemainingTime)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("left before the server deletes itself")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    Button("+10 minutes") { Task { await manager.extendSession(minutes: 10) } }
                    Button("+30 minutes") { Task { await manager.extendSession(minutes: 30) } }
                    Button("+60 minutes") { Task { await manager.extendSession(minutes: 60) } }
                } label: {
                    pill("Extend", systemImage: "plus", tint: .accentColor)
                }
                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    pill("Stop", systemImage: "stop.fill", tint: .red)
                }
                .disabled(manager.isOperating)
            }
            Text("Stop destroys the server and its firewall")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func pill(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    private func toggle() {
        Haptics.success()
        Task {
            if connected || busy {
                nativeVPN.disconnect()
            } else if let psk = session.ikev2PSK {
                await nativeVPN.connect(server: ip, psk: psk, name: "VPN Spawner \(CloudVendor.regionName(session.region))")
            }
        }
    }
}
