import Foundation

/// Per-session security group: ingress only from allowed IPs, egress open.
enum FirewallClient {
    private static let host = "vpc.tencentcloudapi.com"
    private static let service = "vpc"
    private static let version = "2017-03-12"

    private static func call(
        _ action: String,
        region: String,
        payload: [String: Any],
        credential: CloudSigner.Credential
    ) async throws -> Data {
        try await CloudAPIClient.request(
            host: host,
            service: service,
            action: action,
            version: version,
            region: region,
            payload: payload,
            credential: credential
        )
    }

    private static func ingressRule(_ ip: String) -> [String: Any] {
        ["Protocol": "ALL", "Port": "ALL", "CidrBlock": "\(ip)/32", "Action": "ACCEPT",
         "PolicyDescription": "vpn-spawner allow"]
    }

    static func create(
        sessionTag: String,
        allowIPs: [String],
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> String {
        let data = try await call("CreateSecurityGroup", region: region, payload: [
            "GroupName": "vpn-\(sessionTag)",
            "GroupDescription": "VPNSpawner per-session allowlist",
            "Tags": [
                ["Key": "ManagedBy", "Value": "VPNSpawner"],
                ["Key": "SessionId", "Value": sessionTag],
            ],
        ], credential: credential)

        struct CreateResp: Decodable {
            struct Body: Decodable {
                struct Group: Decodable { let SecurityGroupId: String }
                let SecurityGroup: Group
            }
            let Response: Body
        }
        let sgId = try JSONDecoder().decode(CreateResp.self, from: data).Response.SecurityGroup.SecurityGroupId

        _ = try await call("CreateSecurityGroupPolicies", region: region, payload: [
            "SecurityGroupId": sgId,
            "SecurityGroupPolicySet": [
                "Egress": [["Protocol": "ALL", "Port": "ALL", "CidrBlock": "0.0.0.0/0", "Action": "ACCEPT"]],
            ],
        ], credential: credential)

        for ip in allowIPs {
            _ = try await allow(ip: ip, securityGroupId: sgId, region: region, credential: credential)
        }
        return sgId
    }

    static func allowedIPs(
        securityGroupId: String,
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> [String] {
        let data = try await call("DescribeSecurityGroupPolicies", region: region, payload: [
            "SecurityGroupId": securityGroupId,
        ], credential: credential)

        struct PoliciesResp: Decodable {
            struct Body: Decodable {
                struct PolicySet: Decodable {
                    struct Policy: Decodable {
                        let CidrBlock: String?
                        let Action: String
                    }
                    let Ingress: [Policy]?
                }
                let SecurityGroupPolicySet: PolicySet
            }
            let Response: Body
        }
        let ingress = try JSONDecoder().decode(PoliciesResp.self, from: data).Response.SecurityGroupPolicySet.Ingress ?? []
        return ingress
            .filter { $0.Action == "ACCEPT" }
            .compactMap { $0.CidrBlock?.replacingOccurrences(of: "/32", with: "") }
            .filter { !$0.isEmpty }
    }

    /// Idempotent; returns the full allowlist.
    static func allow(
        ip: String,
        securityGroupId: String,
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> [String] {
        let current = try await allowedIPs(securityGroupId: securityGroupId, region: region, credential: credential)
        guard !current.contains(ip) else { return current }
        _ = try await call("CreateSecurityGroupPolicies", region: region, payload: [
            "SecurityGroupId": securityGroupId,
            "SecurityGroupPolicySet": ["Ingress": [ingressRule(ip)]],
        ], credential: credential)
        return current + [ip]
    }

    /// Retries while the terminating instance still holds the group.
    static func delete(
        securityGroupId: String,
        region: String,
        credential: CloudSigner.Credential,
        attempts: Int = 24
    ) async -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                _ = try await call("DeleteSecurityGroup", region: region, payload: [
                    "SecurityGroupId": securityGroupId,
                ], credential: credential)
                return true
            } catch CloudAPIError.api(let code, _) where code.contains("NotFound") {
                return true
            } catch {
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
        return false
    }
}

enum PublicIPService {
    /// Mixes global and China-reachable services: ipify is often unreachable through a China exit.
    private static let sources = [
        "https://api.ipify.org",
        "https://ip.3322.net",
        "https://myip.ipip.net",
        "https://checkip.amazonaws.com",
    ]
    static let browserCheckURL = URL(string: "https://myip.ipip.net")!

    static func current() async throws -> String {
        for urlString in sources {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let body = String(data: data, encoding: .utf8),
               let ip = firstIPv4(in: body) {
                return ip
            }
        }
        throw CloudAPIError.badResponse("Could not detect current public IP")
    }

    private static func firstIPv4(in text: String) -> String? {
        guard let range = text.range(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}

/// The node's own /health (reachable because the phone's IP is allowlisted).
enum NodeHealth {
    struct Status: Decodable {
        let ready: Bool?
        let protocols: [String: Bool]?
        let shadowsocks: Bool?
        let ikev2: Bool?
        let ipsec_backend: Bool?
        let stage: String?
        let error: String?
        let unavailable: [String: String]?

        /// Nodes report `ready` once every requested protocol is up; older nodes only the three flags.
        var isReady: Bool { ready ?? (shadowsocks == true && ikev2 == true && ipsec_backend == true) }
    }

    /// Connection details for every enabled protocol (node's /client.json).
    static func endpoints(ip: String) async -> [NodeEndpoint]? {
        guard let url = URL(string: "http://\(ip):8389/client.json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        struct Body: Decodable { let endpoints: [NodeEndpoint] }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Body.self, from: data).endpoints
    }

    static func check(ip: String) async -> Status? {
        guard let url = URL(string: "http://\(ip):8389/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}
