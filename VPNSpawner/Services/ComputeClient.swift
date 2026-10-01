import Foundation

struct ComputeInstanceInfo {
    let instanceId: String
    let state: String
    let publicIP: String?
}

enum ComputeClient {
    private static let host = "cvm.tencentcloudapi.com"
    private static let service = "cvm"
    private static let version = "2017-03-12"

    static let instanceTypes = ["SA2.MEDIUM2", "S5.MEDIUM2", "SA3.MEDIUM2", "SA5.MEDIUM2", "S6.MEDIUM2"]
    private static let safeValue = try! NSRegularExpression(pattern: "^[A-Za-z0-9+/=_.:-]+$")

    /// Fills controller/bootstrap.sh (bundled), the same script the SCF controller uses.
    static func buildUserDataScript(shadowsocks: ShadowsocksConfig, ikev2PSK: String) throws -> String {
        guard let url = Bundle.main.url(forResource: "bootstrap", withExtension: "sh"),
              var script = try? String(contentsOf: url, encoding: .utf8) else {
            throw CloudAPIError.badResponse("bootstrap.sh missing from app bundle")
        }
        let values = [
            "SS_PORT": String(shadowsocks.port),
            "SS_PASSWORD": shadowsocks.password,
            "SS_METHOD": shadowsocks.method,
            "TAG": shadowsocks.tag,
            "IKEV2_PSK": ikev2PSK,
        ]
        for (key, value) in values {
            let range = NSRange(value.startIndex..., in: value)
            guard safeValue.firstMatch(in: value, range: range) != nil else {
                throw CloudAPIError.badResponse("\(key) has characters unsafe for the bootstrap script")
            }
            script = script.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return script
    }

    /// Cheapest (zone, instance type) currently on sale with hourly billing.
    static func resolvePlacement(region: String, credential: CloudSigner.Credential) async throws -> (zone: String, instanceType: String) {
        let data = try await CloudAPIClient.request(
            host: host,
            service: service,
            action: "DescribeZoneInstanceConfigInfos",
            version: version,
            region: region,
            payload: [
                "Filters": [
                    ["Name": "instance-charge-type", "Values": ["POSTPAID_BY_HOUR"]],
                    ["Name": "instance-type", "Values": instanceTypes],
                ],
            ],
            credential: credential
        )
        struct QuotaResp: Decodable {
            struct Body: Decodable {
                struct Quota: Decodable {
                    struct Price: Decodable { let UnitPrice: Double? }
                    let Zone: String
                    let InstanceType: String
                    let Status: String
                    let Price: Price?
                }
                let InstanceTypeQuotaSet: [Quota]?
            }
            let Response: Body
        }
        let quotas = try JSONDecoder().decode(QuotaResp.self, from: data).Response.InstanceTypeQuotaSet ?? []
        guard let best = quotas
            .filter({ $0.Status == "SELL" })
            .min(by: { ($0.Price?.UnitPrice ?? .infinity) < ($1.Price?.UnitPrice ?? .infinity) }) else {
            throw CloudAPIError.badResponse("None of \(instanceTypes) on sale in \(region)")
        }
        return (best.Zone, best.InstanceType)
    }

    static func resolveImageId(region: String, credential: CloudSigner.Credential) async -> String {
        do {
            let data = try await CloudAPIClient.request(
                host: host,
                service: service,
                action: "DescribeImages",
                version: version,
                region: region,
                payload: [
                    "Filters": [
                        ["Name": "image-type", "Values": ["PUBLIC_IMAGE"]],
                        ["Name": "platform", "Values": ["Ubuntu"]],
                    ],
                    "Limit": 5,
                ],
                credential: credential
            )
            struct ImageResp: Decodable {
                struct Body: Decodable {
                    struct ImageInfo: Decodable {
                        let ImageId: String
                        let OsName: String
                    }
                    let ImageSet: [ImageInfo]?
                }
                let Response: Body
            }
            let decoded = try JSONDecoder().decode(ImageResp.self, from: data)
            if let img = decoded.Response.ImageSet?.first(where: { $0.OsName.contains("22.04") || $0.OsName.contains("20.04") })?.ImageId {
                return img
            }
            if let first = decoded.Response.ImageSet?.first?.ImageId {
                return first
            }
        } catch {
            // fallback
        }
        return "img-pi0ii46r"
    }

    static func launchInstance(
        region: String,
        shadowsocks: ShadowsocksConfig,
        sessionTag: String,
        securityGroupId: String,
        ikev2PSK: String,
        credential: CloudSigner.Credential
    ) async throws -> String {
        let placement = try await resolvePlacement(region: region, credential: credential)
        let imageId = await resolveImageId(region: region, credential: credential)
        let script = try buildUserDataScript(shadowsocks: shadowsocks, ikev2PSK: ikev2PSK)
        let base64UserData = Data(script.utf8).base64EncodedString()

        let payload: [String: Any] = [
            "Placement": ["Zone": placement.zone],
            "InstanceType": placement.instanceType,
            "ImageId": imageId,
            "InstanceChargeType": "POSTPAID_BY_HOUR",
            "InstanceName": "vpn-\(sessionTag)",
            "UserData": base64UserData,
            "SecurityGroupIds": [securityGroupId],
            "InternetAccessible": [
                "InternetChargeType": "TRAFFIC_POSTPAID_BY_HOUR",
                "InternetMaxBandwidthOut": 30,
                "PublicIpAssigned": true,
            ],
            "TagSpecification": [
                [
                    "ResourceType": "instance",
                    "Tags": [
                        ["Key": "SessionId", "Value": sessionTag],
                        ["Key": "ManagedBy", "Value": "VPNSpawner"],
                    ],
                ]
            ],
        ]

        let data = try await CloudAPIClient.request(
            host: host,
            service: service,
            action: "RunInstances",
            version: version,
            region: region,
            payload: payload,
            credential: credential
        )

        struct RunInstancesResponse: Decodable {
            struct Body: Decodable {
                let InstanceIdSet: [String]?
            }
            let Response: Body
        }

        let decoded = try JSONDecoder().decode(RunInstancesResponse.self, from: data)
        guard let id = decoded.Response.InstanceIdSet?.first else {
            throw CloudAPIError.badResponse("No instance ID returned by cloud provider")
        }
        return id
    }

    static func describeInstance(
        instanceId: String,
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> ComputeInstanceInfo {
        let payload: [String: Any] = [
            "InstanceIds": [instanceId],
        ]

        let data = try await CloudAPIClient.request(
            host: host,
            service: service,
            action: "DescribeInstances",
            version: version,
            region: region,
            payload: payload,
            credential: credential
        )

        struct ResponseEnvelope: Decodable {
            struct Body: Decodable {
                struct Instance: Decodable {
                    let InstanceId: String
                    let InstanceState: String
                    let PublicIpAddresses: [String]?
                }
                let InstanceSet: [Instance]?
            }
            let Response: Body
        }

        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        guard let instance = decoded.Response.InstanceSet?.first(where: { $0.InstanceId == instanceId }) else {
            throw CloudAPIError.badResponse("Instance \(instanceId) not found")
        }

        return ComputeInstanceInfo(
            instanceId: instance.InstanceId,
            state: instance.InstanceState,
            publicIP: instance.PublicIpAddresses?.first
        )
    }

    static func terminateInstance(
        instanceId: String,
        region: String,
        credential: CloudSigner.Credential
    ) async throws {
        let payload: [String: Any] = [
            "InstanceIds": [instanceId],
            "ReleasePrepaidDataDisks": true,
        ]

        _ = try await CloudAPIClient.request(
            host: host,
            service: service,
            action: "TerminateInstances",
            version: version,
            region: region,
            payload: payload,
            credential: credential
        )
    }
}
