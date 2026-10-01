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
    static func current() async throws -> String {
        for urlString in ["https://api.ipify.org", "https://checkip.amazonaws.com"] {
            guard let url = URL(string: urlString) else { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                return ip
            }
        }
        throw CloudAPIError.badResponse("Could not detect current public IP")
    }
}
