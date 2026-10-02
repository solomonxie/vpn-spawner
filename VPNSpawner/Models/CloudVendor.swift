import Foundation

/// Where nodes run. AWS always goes through its controller Lambda; Tencent can also run from the phone.
enum CloudVendor: String, Codable, CaseIterable, Identifiable {
    case tencent
    case aws

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tencent: return "Tencent Cloud"
        case .aws: return "AWS"
        }
    }

    var regions: [(id: String, name: String)] {
        switch self {
        case .tencent:
            return [
                ("ap-guangzhou", "Guangzhou"), ("ap-shanghai", "Shanghai"), ("ap-beijing", "Beijing"),
                ("ap-hongkong", "Hong Kong"), ("ap-tokyo", "Tokyo"), ("ap-singapore", "Singapore"),
            ]
        case .aws:
            // Regions opted in on the account and covered by the controller's watchdog.
            return [
                ("us-west-2", "Oregon"), ("us-east-1", "N. Virginia"), ("ca-central-1", "Canada"),
                ("eu-central-1", "Frankfurt"), ("ap-northeast-1", "Tokyo"), ("ap-southeast-1", "Singapore"),
            ]
        }
    }

    var defaultRegion: String { regions[0].id }

    var priceHint: String {
        switch self {
        case .tencent: return "About ¥0.05/hr"
        case .aws: return "About $0.015/hr"
        }
    }

    static func regionName(_ id: String) -> String {
        allCases.lazy.compactMap { vendor in vendor.regions.first { $0.id == id }?.name }.first ?? id
    }
}

/// AWS invoke-only key for the controller Lambda (from terraform: ~/.vpn-spawner/aws-vpn-spawner-keys.txt).
struct AWSCredentialConfig: Codable, Equatable {
    var accessKeyId = ""
    var functionName = "vpn-spawner-controller"
    var functionRegion = "ca-central-1"

    private static let configKey = "vpn.aws.config"
    private static let secretAccount = "vpn.aws.secretAccessKey"

    static func load() -> (config: AWSCredentialConfig, secret: String) {
        let secret = KeychainStore.load(forKey: secretAccount) ?? ""
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let config = try? JSONDecoder().decode(AWSCredentialConfig.self, from: data) else {
            return (AWSCredentialConfig(), secret)
        }
        return (config, secret)
    }

    func save(secret: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
        if secret.isEmpty {
            KeychainStore.delete(forKey: Self.secretAccount)
        } else {
            KeychainStore.save(secret, forKey: Self.secretAccount)
        }
    }

    var isComplete: Bool { !accessKeyId.isEmpty && !functionName.isEmpty && !functionRegion.isEmpty }
}
