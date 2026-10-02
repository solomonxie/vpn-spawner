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
                ControlHub(
                    manager: manager,
                    nativeVPN: nativeVPN,
                    session: session,
                    canConnect: !session.isDemo && hasIKEv2,
                    toast: $toast,
                    confirmStop: $confirmStop
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                connectFooter
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }

            Section {
                testRow
                NavigationLink {
                    PrivacyCheckView(nodeIP: ip, region: session.region)
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

        }
        .listStyle(.insetGrouped)
        .toast($toast)
        .sheet(item: $qr) { item in
            QRCodeView(content: item.content, title: item.title)
        }
        .confirmationDialog("Stop this server?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                Task { await manager.terminateSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The VPN disconnects and the server at \(ip) is deleted.")
        }
    }

    // MARK: Connect

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
            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Label(isTesting ? "Testing…" : "Test VPN", systemImage: "checkmark.shield")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
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
            let (seen, place) = try await exitAddress()
            let where_ = place.map { " · \($0)" } ?? ""
            test = seen == ip
                ? (true, "Working. The internet sees \(seen)\(where_).")
                : (false, "Not through the server. The internet sees \(seen)\(where_). Connect, then test again.")
        } catch {
            test = (false, "Couldn't check: \(error.localizedDescription)")
        }
    }

    /// Races many IP echo services (China-reachable ones first for mainland nodes); first answer wins.
    private func exitAddress() async throws -> (String, String?) {
        let answer = try await IPEcho.lookup(preferChina: IPEcho.mainlandRegions.contains(session.region))
        return (answer.ip, answer.place)
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
struct QRItem: Identifiable {
    let content: String
    let title: String
    var id: String { content }
}
