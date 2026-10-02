import Foundation
import NetworkExtension
import Security

/// Installs and drives the node's IKEv2 PSK tunnel through the system VPN (Personal VPN entitlement).
/// iOS asks once to "Add VPN Configurations"; no profile or manual fields.
@MainActor
final class NativeVPNController: ObservableObject {
    static let shared = NativeVPNController()

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var installedServer: String?
    @Published var lastError: String?

    private let keychainService = "com.example.vpnspawner.ikev2"
    private var manager: NEVPNManager { NEVPNManager.shared() }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { await load() }
    }

    var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .reasserting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .invalid: return "Not installed"
        @unknown default: return "Unknown"
        }
    }

    var isActive: Bool { [.connected, .connecting, .reasserting].contains(status) }

    func isInstalled(for server: String) -> Bool { installedServer == server }

    private func load() async {
        try? await manager.loadFromPreferences()
        refresh()
    }

    private func refresh() {
        status = manager.connection.status
        installedServer = (manager.protocolConfiguration as? NEVPNProtocolIKEv2)?.serverAddress
    }

    /// Installs (or replaces) the config for this node, then starts the tunnel.
    func connect(server: String, psk: String, name: String) async {
        lastError = nil
        do {
            try await manager.loadFromPreferences()
            if !isInstalled(for: server) || manager.isEnabled == false {
                manager.protocolConfiguration = try makeProtocol(server: server, psk: psk)
                manager.localizedDescription = name
                manager.isEnabled = true
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                // A freshly saved config can't be started until it's reloaded.
                try await manager.loadFromPreferences()
            }
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func disconnect() {
        manager.connection.stopVPNTunnel()
    }

    /// Stops the tunnel and deletes the config so no dead entry stays in Settings → VPN.
    /// Returns once iOS reports the tunnel down, so later API calls don't go into a dying tunnel.
    func remove() async {
        try? await manager.loadFromPreferences()
        guard manager.protocolConfiguration != nil else { return }
        if ![.disconnected, .invalid].contains(manager.connection.status) {
            manager.connection.stopVPNTunnel()
            let deadline = Date().addingTimeInterval(15)
            while ![.disconnected, .invalid].contains(manager.connection.status), Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        try? await manager.removeFromPreferences()
        deleteSecret()
        refresh()
    }

    /// True if any VPN is up, including ones this app can't control (Safari profile, manual config).
    static var anySystemVPNActive: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { key in
            ["tap", "tun", "ppp", "ipsec"].contains { key.hasPrefix($0) }
        }
    }

    private func makeProtocol(server: String, psk: String) throws -> NEVPNProtocolIKEv2 {
        let proto = NEVPNProtocolIKEv2()
        proto.serverAddress = server
        proto.remoteIdentifier = server
        proto.localIdentifier = "vpn-client"
        proto.authenticationMethod = .sharedSecret
        proto.sharedSecretReference = try storeSecret(psk)
        proto.useExtendedAuthentication = false
        proto.disconnectOnSleep = false
        proto.deadPeerDetectionRate = .medium
        for sa in [proto.ikeSecurityAssociationParameters, proto.childSecurityAssociationParameters] {
            sa.encryptionAlgorithm = .algorithmAES256
            sa.integrityAlgorithm = .SHA256
            sa.diffieHellmanGroup = .group14
            sa.lifetimeMinutes = 1440
        }
        return proto
    }

    /// NetworkExtension only accepts the PSK as a persistent Keychain reference.
    private func storeSecret(_ psk: String) throws -> Data {
        deleteSecret()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "psk",
            kSecValueData as String: Data(psk.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnPersistentRef as String: true,
        ]
        var ref: AnyObject?
        let status = SecItemAdd(query as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else {
            throw CloudAPIError.badResponse("Keychain error \(status) storing VPN secret")
        }
        return data
    }

    private func deleteSecret() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "psk",
        ] as CFDictionary)
    }
}
