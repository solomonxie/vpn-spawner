import SwiftUI

/// Guideline 5.4 data declaration: shown before first use (must be accepted) and from Settings.
struct DataUseView: View {
    /// Bump when the declaration changes materially, so it is shown and accepted again.
    static let version = 1
    static let acceptedKey = "vpn.dataUse.acceptedVersion"

    static var isAccepted: Bool {
        UserDefaults.standard.integer(forKey: acceptedKey) >= version
    }

    /// Nil when shown from Settings (read-only).
    var onAccept: (() -> Void)?

    var body: some View {
        List {
            Section {
                Text("VPN Spawner creates a temporary VPN server in **your own** AWS or Tencent Cloud account and connects this iPhone to it. We run no server and no VPN service, and we collect nothing.")
            }

            Section("What the app uses") {
                item("key", "Your cloud key",
                     "The key you enter. The secret is kept in the iOS Keychain, the key ID in the app's settings on this iPhone. It is sent only to your cloud provider, to create, check and delete your server.")
                item("server.rack", "Your server's details",
                     "Its IP address, region, connection passwords and start/end times are kept on this iPhone for the session and the activity log.")
                item("network", "Your public IP address",
                     "Looked up through public IP-check services and added to your server's firewall, so only you can connect. The optional privacy check uses the same services.")
            }

            Section("Where your traffic goes") {
                item("arrow.triangle.swap", "Only through your server",
                     "While connected, your traffic goes through the server in your cloud account, never through us. We keep no traffic or connection logs. The server and everything on it is deleted when the session ends.")
            }

            Section("What we don't do") {
                item("hand.raised", "No collection, no sharing",
                     "No account, no analytics, no ads, no tracking. We do not sell, use or disclose any of your data. Your cloud provider bills you directly.")
            }

            Section {
                Link("Privacy Policy", destination: ProjectLinks.privacyPolicy)
            }

            if let onAccept {
                Section {
                    Button {
                        UserDefaults.standard.set(Self.version, forKey: Self.acceptedKey)
                        onAccept()
                    } label: {
                        Text("Agree and Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("You can read this again in Settings → Data use.")
                }
            }
        }
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }
}
