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

    static func buildUserDataScript(shadowsocks: ShadowsocksConfig) -> String {
        """
        #!/bin/bash
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y shadowsocks-libev
        cat <<EOF > /etc/shadowsocks-libev/config.json
        {
            "server": "0.0.0.0",
            "server_port": \(shadowsocks.port),
            "password": "\(shadowsocks.password)",
            "timeout": 300,
            "method": "\(shadowsocks.method)",
            "fast_open": false,
            "nameserver": "8.8.8.8",
            "mode": "tcp_and_udp"
        }
        EOF
        systemctl restart shadowsocks-libev
        systemctl enable shadowsocks-libev
        """
    }

    static func resolveZone(region: String, credential: CloudSigner.Credential) async -> String {
        do {
            let data = try await CloudAPIClient.request(
                host: host,
                service: service,
                action: "DescribeZones",
                version: version,
                region: region,
                payload: [:],
                credential: credential
            )
            struct ZoneResp: Decodable {
                struct Body: Decodable {
                    struct ZoneInfo: Decodable {
                        let Zone: String
                        let ZoneState: String
                    }
                    let ZoneSet: [ZoneInfo]?
                }
                let Response: Body
            }
            let decoded = try JSONDecoder().decode(ZoneResp.self, from: data)
            if let available = decoded.Response.ZoneSet?.first(where: { $0.ZoneState == "AVAILABLE" })?.Zone {
                return available
            }
        } catch {
            // fallback to default
        }
        return "\(region)-3"
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
        credential: CloudSigner.Credential
    ) async throws -> String {
        let zone = await resolveZone(region: region, credential: credential)
        let imageId = await resolveImageId(region: region, credential: credential)
        let script = buildUserDataScript(shadowsocks: shadowsocks)
        let base64UserData = Data(script.utf8).base64EncodedString()

        let payload: [String: Any] = [
            "Placement": ["Zone": zone],
            "InstanceType": "S5.MEDIUM2",
            "ImageId": imageId,
            "InstanceChargeType": "POSTPAID_BY_HOUR",
            "InstanceName": "vpn-\(sessionTag)",
            "UserData": base64UserData,
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
