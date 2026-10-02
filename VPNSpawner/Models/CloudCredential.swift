import Foundation

enum ExecutionMode: String, CaseIterable, Codable, Identifiable {
    case direct = "Direct CVM"
    case controller = "SCF Controller"

    var id: String { rawValue }
}

struct CloudCredentialConfig: Codable, Equatable {
    var secretId: String
    var region: String
    var executionMode: ExecutionMode
    var controllerFunctionName: String
    var isDemoMode: Bool

    static let defaultRegion = "ap-guangzhou"
    static let defaultFunctionName = "vpn-spawner-controller"

    init(
        secretId: String = "",
        region: String = CloudCredentialConfig.defaultRegion,
        executionMode: ExecutionMode = .controller,
        controllerFunctionName: String = CloudCredentialConfig.defaultFunctionName,
        isDemoMode: Bool = false
    ) {
        self.secretId = secretId
        self.region = region
        self.executionMode = executionMode
        self.controllerFunctionName = controllerFunctionName
        self.isDemoMode = isDemoMode
    }

    static let configKey = "vpn.credential.config"
    static let secretKeyAccount = "vpn.credential.secretKey"

    static func load() -> (config: CloudCredentialConfig, secretKey: String) {
        let secretKey = KeychainStore.load(forKey: secretKeyAccount) ?? ""
        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(CloudCredentialConfig.self, from: data) {
            return (config, secretKey)
        }
        return (CloudCredentialConfig(), secretKey)
    }

    func save(secretKey: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
        if !secretKey.isEmpty {
            KeychainStore.save(secretKey, forKey: Self.secretKeyAccount)
        } else {
            KeychainStore.delete(forKey: Self.secretKeyAccount)
        }
    }
}
