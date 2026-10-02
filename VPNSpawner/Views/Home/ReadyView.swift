import SwiftUI

/// Node is up: countdown, one big Connect, then ways to connect from other apps.
struct ReadyView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject private var nativeVPN = NativeVPNController.shared
    let session: SessionRecord

    @State private var toast: String?
    @State private var qr: QRItem?
    @State private var confirmStop = false
    @State private var test: (ok: Bool, text: String)?
    @State private var isTesting = false

    private var hasIKEv2: Bool { session.protocols?.contains(.ikev2) ?? true }
    private var ip: String { session.publicIP ?? "—" }

    var body: some View {
        List {
            Section {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            if !session.isDemo && hasIKEv2 {
                Section { connectRow } footer: { connectFooter }
            }

            Section {
                testRow
                NavigationLink {
                    PrivacyCheckView(nodeIP: ip)
                } label: {
                    Label("Full privacy check", systemImage: "eye.trianglebadge.exclamationmark")
                }
            } footer: {
                Text("Checks IPv6 and DNS leaks, Location Services and time zone, with browser tests.")
            }

            ConnectionsSection(session: session, toast: $toast, qr: $qr)

            Section("Access") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Allowed IPs")
                    Spacer()
                    Text((session.allowedIPs ?? []).joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if !session.isDemo {
                    Button {
                        Task { await manager.allowCurrentIP() }
                    } label: {
                        Label("Allow this device's current IP", systemImage: "plus.circle")
                    }
                    .disabled(manager.isOperating)
                }
            }

            Section {
                DisclosureGroup("Details") {
                    detail("Instance", session.instanceId ?? "—")
                    detail("Region", IdleView.regionName(session.region))
                    detail("Cost so far", String(format: "¥%.3f", session.currentCostEstimate))
                    detail("Rate", String(format: "about ¥%.2f/hr", session.estimatedCostPerHour))
                }
                if let psk = session.ikev2PSK, hasIKEv2, !session.isDemo {
                    DisclosureGroup("Manual IKEv2 (other devices)") {
                        copyRow("Server / Remote ID", ip)
                        copyRow("Local ID", "vpn-client")
                        copyRow("Pre-shared key", psk)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    Text("Stop & Clean Up")
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Disconnects, deletes the server and its firewall, then verifies nothing is left billing.")
            }
        }
        .listStyle(.insetGrouped)
        .toast($toast)
        .sheet(item: $qr) { item in
            QRCodeView(content: item.content, title: item.title)
        }
        .confirmationDialog("Stop this server?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop & Clean Up", role: .destructive) {
                Task { await manager.terminateSession() }
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("The VPN disconnects and the server at \(ip) is deleted.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                StatusPill(text: "Ready", color: .green)
                if session.isDemo { DemoBadge() }
            }
            CountdownRing(session: session)
            Button {
                UIPasteboard.general.string = ip
                Haptics.success()
                toast = "Copied IP"
            } label: {
                Text("\(IdleView.regionName(session.region)) · \(ip)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies the server IP")

            Menu {
                Button("+10 minutes") { Task { await manager.extendSession(minutes: 10) } }
                Button("+30 minutes") { Task { await manager.extendSession(minutes: 30) } }
                Button("+60 minutes") { Task { await manager.extendSession(minutes: 60) } }
            } label: {
                Label("Extend", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Connect

    private var isConnectedHere: Bool { nativeVPN.isActive && nativeVPN.isInstalled(for: ip) }

    private var connectRow: some View {
        Button {
            Task {
                if isConnectedHere {
                    nativeVPN.disconnect()
                } else if let psk = session.ikev2PSK {
                    await nativeVPN.connect(server: ip, psk: psk, name: "VPN Spawner \(IdleView.regionName(session.region))")
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "power")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(isConnectedHere ? Color.green : Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(isConnectedHere ? "Disconnect" : "Connect")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(nativeVPN.isInstalled(for: ip) ? nativeVPN.statusText : "IKEv2 · built into iOS")
                        .font(.subheadline)
                        .foregroundStyle(isConnectedHere ? .green : .secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var connectFooter: some View {
        if let error = nativeVPN.lastError {
            Text(error).foregroundStyle(.red)
        } else if !nativeVPN.isInstalled(for: ip) {
            Text("The first time, iOS asks to add a VPN configuration.")
        }
    }

    // MARK: Test

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    Label(isTesting ? "Testing…" : "Test VPN", systemImage: "checkmark.shield")
                }
                .disabled(isTesting)
                Spacer()
                Link(destination: PublicIPService.browserCheckURL) {
                    Label("Open IP check", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Open IP check in Safari")
            }
            if let test {
                Label(test.text, systemImage: test.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(test.ok ? .green : .orange)
            }
        }
    }

    /// Traffic goes through the node iff the internet sees the node's IP as ours.
    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let seen = try await PublicIPService.current()
            test = seen == ip
                ? (true, "Working. The internet sees \(seen).")
                : (false, "Not through the node. The internet sees \(seen).")
        } catch {
            test = (false, "Couldn't check: \(error.localizedDescription)")
        }
    }

    // MARK: Rows

    private func detail(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(.callout.monospaced())
        }
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.success()
            toast = "Copied \(title.lowercased())"
        } label: {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(value).font(.callout.monospaced()).lineLimit(1)
                    Image(systemName: "doc.on.doc").font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Thin ring that empties as the session's time runs out.
struct CountdownRing: View {
    let session: SessionRecord

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let low = session.remainingTime < 120
            ZStack {
                Circle()
                    .stroke(.fill.tertiary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: 1 - session.progress)
                    .stroke(low ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: session.progress)
                VStack(spacing: 2) {
                    Text(session.formattedRemainingTime)
                        .font(.system(size: 40, weight: .light, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.formattedRemainingTime) left")
        }
    }
}

struct QRItem: Identifiable {
    let content: String
    let title: String
    var id: String { content }
}
