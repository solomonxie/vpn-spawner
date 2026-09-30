import Foundation

struct ShadowsocksConfig: Codable, Hashable {
    var host: String
    var port: Int
    var password: String
    var method: String
    var tag: String

    init(
        host: String = "",
        port: Int = 8388,
        password: String = ShadowsocksConfig.generatePassword(),
        method: String = "chacha20-ietf-poly1305",
        tag: String = "VPN-Ephemeral"
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.method = method
        self.tag = tag
    }

    var uriString: String {
        guard !host.isEmpty else { return "" }
        let userInfo = "\(method):\(password)@\(host):\(port)"
        let base64 = Data(userInfo.utf8).base64EncodedString()
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? tag
        return "ss://\(base64)#\(encodedTag)"
    }

    var shadowrocketURL: URL? {
        guard !uriString.isEmpty else { return nil }
        return URL(string: "shadowrocket://add/\(uriString)")
    }

    static func generatePassword(length: Int = 16) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }
}
