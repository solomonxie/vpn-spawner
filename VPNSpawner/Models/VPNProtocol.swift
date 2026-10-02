import Foundation

/// Protocols a node can serve; raw values match controller/bootstrap.sh's PROTOCOLS list.
enum VPNProtocol: String, Codable, CaseIterable, Identifiable, Hashable {
    case ikev2
    case shadowsocks
    case ssObfs = "ss_obfs"
    case ss2022
    case vlessReality = "vless_reality"
    case vmessWS = "vmess_ws"
    case trojan
    case hysteria2
    case wireguard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ikev2: return "IKEv2"
        case .shadowsocks: return "Shadowsocks"
        case .ssObfs: return "Shadowsocks + obfs"
        case .ss2022: return "Shadowsocks 2022"
        case .vlessReality: return "VLESS Reality"
        case .vmessWS: return "VMess WebSocket"
        case .trojan: return "Trojan"
        case .hysteria2: return "Hysteria2"
        case .wireguard: return "WireGuard"
        }
    }

    var summary: String {
        switch self {
        case .ikev2: return "Built into iOS. One tap, no other app."
        case .shadowsocks: return "Simple and fast."
        case .ssObfs: return "Shadowsocks with an HTTP framing plugin."
        case .ss2022: return "Modern Shadowsocks, replay-resistant."
        case .vlessReality: return "VLESS over TLS 1.3 (Reality handshake)."
        case .vmessWS: return "Widest client support."
        case .trojan: return "Proxy protocol over TLS."
        case .hysteria2: return "QUIC. Fast on lossy networks."
        case .wireguard: return "Fast, simple. Needs the WireGuard app."
        }
    }

    var symbol: String {
        switch self {
        case .ikev2: return "lock.shield"
        case .shadowsocks, .ss2022: return "bolt.horizontal"
        case .ssObfs: return "square.stack.3d.up"
        case .vlessReality: return "lock.rectangle"
        case .vmessWS: return "globe"
        case .trojan: return "lock"
        case .hysteria2: return "hare"
        case .wireguard: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// IKEv2 connects in-app; the rest are imported into a client app (Shadowrocket / WireGuard).
    var isNative: Bool { self == .ikev2 }

    static let defaults: Set<VPNProtocol> = [.ikev2, .shadowsocks]
}

/// One way to connect to a ready node, as reported by the node's /client.json.
struct NodeEndpoint: Codable, Hashable, Identifiable {
    var proto: VPNProtocol
    /// Import link (ss://, vless://, vmess://, trojan://, hysteria2://) or a WireGuard config.
    var uri: String
    var port: Int
    var note: String?

    var id: String { proto.rawValue }
}

/// What the next launch uses; persisted so the home screen remembers choices.
struct LaunchPreferences: Codable, Equatable {
    var protocols: Set<VPNProtocol> = VPNProtocol.defaults
    var durationMinutes: Int = 10
    var region: String = CloudCredentialConfig.defaultRegion
    /// Optional so preferences saved before AWS support still decode.
    var vendor: CloudVendor?

    var effectiveVendor: CloudVendor { vendor ?? .tencent }

    static let durations = [10, 30, 60, 120]
    private static let key = "vpn.launch.preferences"

    static func load() -> LaunchPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(LaunchPreferences.self, from: data) else {
            return LaunchPreferences()
        }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
