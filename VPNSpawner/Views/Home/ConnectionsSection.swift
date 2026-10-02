import SwiftUI

/// Every non-native way into the node: one row per protocol plus the all-in-one subscription.
struct ConnectionsSection: View {
    let session: SessionRecord
    @Binding var toast: String?
    @Binding var qr: QRItem?

    /// Falls back to the Shadowsocks link until the node reports /client.json.
    private var endpoints: [NodeEndpoint] {
        if let reported = session.endpoints, !reported.isEmpty {
            return reported.filter { !$0.proto.isNative }
        }
        let uri = session.shadowsocks.uriString
        return uri.isEmpty ? [] : [NodeEndpoint(proto: .shadowsocks, uri: uri, port: session.shadowsocks.port)]
    }

    var body: some View {
        if !endpoints.isEmpty {
            Section {
                ForEach(endpoints) { endpoint in
                    row(endpoint)
                }
                subscriptionRow
            } header: {
                Text("Other apps")
            } footer: {
                Text("Tap a row to add it to Shadowrocket. WireGuard: scan its QR in the WireGuard app.")
            }
        }
    }

    private func row(_ endpoint: NodeEndpoint) -> some View {
        let isWireGuard = endpoint.proto == .wireguard
        return HStack(spacing: 12) {
            Image(systemName: endpoint.proto.symbol)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Button {
                if isWireGuard {
                    qr = QRItem(content: endpoint.uri, title: endpoint.proto.displayName)
                } else {
                    openInShadowrocket(endpoint.uri)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.proto.displayName)
                        .foregroundStyle(.primary)
                    Text(endpoint.note ?? "Port \(endpoint.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isWireGuard ? "Shows a QR code" : "Opens Shadowrocket")

            Menu {
                Button {
                    copy(endpoint.uri, "\(endpoint.proto.displayName) link")
                } label: {
                    Label(isWireGuard ? "Copy config" : "Copy link", systemImage: "doc.on.doc")
                }
                Button {
                    qr = QRItem(content: endpoint.uri, title: endpoint.proto.displayName)
                } label: {
                    Label("Show QR code", systemImage: "qrcode")
                }
                if !isWireGuard {
                    Button {
                        openInShadowrocket(endpoint.uri)
                    } label: {
                        Label("Open in Shadowrocket", systemImage: "arrow.up.forward.app")
                    }
                }
                ShareLink(item: endpoint.uri) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("\(endpoint.proto.displayName) options")
        }
    }

    private var subscriptionRow: some View {
        let url = session.subscriptionURLString
        return HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.tint)
                .frame(width: 28)
            Button {
                let encoded = Data(url.utf8).base64EncodedString()
                open(URL(string: "shadowrocket://add/sub://\(encoded)"), fallbackCopy: url, label: "subscription URL")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add all as subscription")
                        .foregroundStyle(.primary)
                    Text(url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                copy(url, "subscription URL")
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy subscription URL")
        }
    }

    private func openInShadowrocket(_ uri: String) {
        open(URL(string: "shadowrocket://add/\(uri)"), fallbackCopy: uri, label: "link")
    }

    /// Opens the app if installed; otherwise copies so it auto-imports when opened later.
    /// (open's result, not canOpenURL, which needs a declared query scheme.)
    private func open(_ url: URL?, fallbackCopy: String, label: String) {
        guard let url else { return copy(fallbackCopy, label) }
        UIApplication.shared.open(url) { opened in
            if !opened {
                Task { @MainActor in copy(fallbackCopy, label) }
            }
        }
    }

    private func copy(_ value: String, _ label: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        toast = "Copied \(label)"
    }
}
