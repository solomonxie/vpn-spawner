import Foundation

struct LaunchResult {
    let instanceId: String
    let instanceType: String
    let hourlyPrice: Double?
}

struct ComputeInstanceInfo {
    let instanceId: String
    let state: String
    let publicIP: String?
}

enum ComputeClient {
    private static let host = "cvm.tencentcloudapi.com"
    private static let service = "cvm"
    private static let version = "2017-03-12"

    private static let safeValue = try! NSRegularExpression(pattern: "^[A-Za-z0-9+/=_.:-]+$")

    /// Fills controller/bootstrap.sh (bundled), the same script the SCF controller uses.
    static func buildUserDataScript(shadowsocks: ShadowsocksConfig, ikev2PSK: String, protocols: [VPNProtocol]) throws -> String {
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
        let ordered = VPNProtocol.allCases.filter((protocols.isEmpty ? Array(VPNProtocol.defaults) : protocols).contains)
        script = script.replacingOccurrences(of: "{{PROTOCOLS}}", with: ordered.map(\.rawValue).joined(separator: ","))
        for (key, value) in values {
            let range = NSRange(value.startIndex..., in: value)
            guard safeValue.firstMatch(in: value, range: range) != nil else {
                throw CloudAPIError.badResponse("\(key) has characters unsafe for the bootstrap script")
            }
            script = script.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return script
    }

    /// Cheapest small x86 (zone, instance type) on sale with hourly billing; mirrors controller/app.py.
    static func resolvePlacement(region: String, credential: CloudSigner.Credential) async throws -> (zone: String, instanceType: String, hourlyPrice: Double?) {
        let data = try await CloudAPIClient.request(
            host: host,
            service: service,
            action: "DescribeZoneInstanceConfigInfos",
            version: version,
            region: region,
            payload: [
                "Filters": [
                    ["Name": "instance-charge-type", "Values": ["POSTPAID_BY_HOUR"]],
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
                    let CpuType: String?
                    let Cpu: Int
                    let Memory: Int
                }
                let InstanceTypeQuotaSet: [Quota]?
            }
            let Response: Body
        }
        let quotas = try JSONDecoder().decode(QuotaResp.self, from: data).Response.InstanceTypeQuotaSet ?? []
        // The Ubuntu image is x86_64; ARM families (Ampere, Kunpeng, Yitian) can't boot it.
        let candidates = quotas.filter { q in
            let x86 = ["Intel", "AMD"].contains { (q.CpuType ?? "").contains($0) }
            return q.Status == "SELL" && (q.Price?.UnitPrice ?? 0) > 0 && x86 && (1...2).contains(q.Cpu) && q.Memory >= 1
        }
        guard let best = candidates.min(by: {
            ($0.Price?.UnitPrice ?? .infinity, $0.Cpu, $0.Memory, $0.InstanceType)
                < ($1.Price?.UnitPrice ?? .infinity, $1.Cpu, $1.Memory, $1.InstanceType)
        }) else {
            throw CloudAPIError.badResponse("No small x86 instance type on sale in \(region)")
        }
        return (best.Zone, best.InstanceType, best.Price?.UnitPrice)
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
        protocols: [VPNProtocol],
        terminateAt: Date,
        credential: CloudSigner.Credential
    ) async throws -> LaunchResult {
        let placement = try await resolvePlacement(region: region, credential: credential)
        let imageId = await resolveImageId(region: region, credential: credential)
        let script = try buildUserDataScript(shadowsocks: shadowsocks, ikev2PSK: ikev2PSK, protocols: protocols)
        // Tencent caps UserData at 16 KB (base64); cloud-init decompresses gzip user-data itself.
        let base64UserData = try Gzip.compress(Data(script.utf8)).base64EncodedString()

        let payload: [String: Any] = [
            "Placement": ["Zone": placement.zone],
            "InstanceType": placement.instanceType,
            "ImageId": imageId,
            "InstanceChargeType": "POSTPAID_BY_HOUR",
            // Fixed name; the session lives in the SessionId tag. Old nodes are replaced before launch.
            "InstanceName": "vpn-spawner-node",
            "UserData": base64UserData,
            "SecurityGroupIds": [securityGroupId],
            // Survives the app dying: Tencent terminates the instance itself.
            "ActionTimer": ["TimerAction": "TerminateInstances", "ActionTime": timerTime(terminateAt)],
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
        return LaunchResult(instanceId: id, instanceType: placement.instanceType, hourlyPrice: placement.hourlyPrice)
    }

    /// Tencent requires ActionTime > now + 5 min, in UTC ISO8601.
    static func timerTime(_ date: Date) -> String {
        let at = max(date, Date().addingTimeInterval(6 * 60))
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: at)
    }

    /// Replaces the instance's cloud-side terminate timer.
    static func rescheduleTerminate(
        instanceId: String,
        at date: Date,
        region: String,
        credential: CloudSigner.Credential
    ) async throws {
        let data = try await CloudAPIClient.request(
            host: host, service: service, action: "DescribeInstancesActionTimer", version: version,
            region: region,
            payload: ["InstanceIds": [instanceId]],
            credential: credential
        )
        struct TimersResp: Decodable {
            struct Body: Decodable {
                struct Timer: Decodable {
                    let ActionTimerId: String?
                    let InstanceId: String?
                    let TimerAction: String?
                    let Status: String?
                }
                let ActionTimers: [Timer]?
            }
            let Response: Body
        }
        // Re-check InstanceId: an ignored filter once returned (and let us delete) other instances' timers.
        let old = (try JSONDecoder().decode(TimersResp.self, from: data).Response.ActionTimers ?? [])
            .filter { $0.InstanceId == instanceId && $0.TimerAction == "TerminateInstances" && ($0.Status ?? "UNDO") == "UNDO" }
            .compactMap(\.ActionTimerId)
        // Tencent allows one timer per instance: delete, then import with retries. The watchdog
        // (controller reap, every 10 min) terminates anything left without a timer.
        if !old.isEmpty {
            _ = try await CloudAPIClient.request(
                host: host, service: service, action: "DeleteInstancesActionTimer", version: version,
                region: region, payload: ["ActionTimerIds": old], credential: credential
            )
        }
        var lastError: Error?
        for attempt in 1...3 {
            do {
                _ = try await CloudAPIClient.request(
                    host: host, service: service, action: "ImportInstancesActionTimer", version: version,
                    region: region,
                    payload: [
                        "InstanceIds": [instanceId],
                        "ActionTimer": ["TimerAction": "TerminateInstances", "ActionTime": timerTime(date)],
                    ],
                    credential: credential
                )
                return
            } catch {
                lastError = error
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw lastError ?? CloudAPIError.badResponse("Couldn't set the delete timer")
    }

    /// One node at a time: terminates any managed instance still alive. Returns their IDs.
    static func replaceRunningNodes(region: String, credential: CloudSigner.Credential) async throws -> [String] {
        let alive = try await describe(
            payload: ["Filters": [["Name": "tag:ManagedBy", "Values": ["VPNSpawner"]]], "Limit": 100],
            region: region,
            credential: credential
        )
        .filter { !["TERMINATING", "SHUTDOWN", "LAUNCH_FAILED"].contains($0.state) }
        .map(\.instanceId)
        if !alive.isEmpty {
            _ = try await CloudAPIClient.request(
                host: host, service: service, action: "TerminateInstances", version: version,
                region: region, payload: ["InstanceIds": alive], credential: credential
            )
        }
        return alive
    }

    /// Instances tagged with this session; recovers the ID if the app died mid-launch.
    static func findInstances(
        sessionTag: String,
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> [ComputeInstanceInfo] {
        try await describe(
            payload: ["Filters": [
                ["Name": "tag:SessionId", "Values": [sessionTag]],
                ["Name": "tag:ManagedBy", "Values": ["VPNSpawner"]],
            ]],
            region: region,
            credential: credential
        )
    }

    /// nil when the instance no longer exists (e.g. its cloud timer already terminated it).
    static func instanceIfExists(
        instanceId: String,
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> ComputeInstanceInfo? {
        do {
            return try await describe(payload: ["InstanceIds": [instanceId]], region: region, credential: credential)
                .first { $0.instanceId == instanceId }
        } catch CloudAPIError.api(let code, _) where code.contains("NotFound") {
            return nil
        }
    }

    private static func describe(
        payload: [String: Any],
        region: String,
        credential: CloudSigner.Credential
    ) async throws -> [ComputeInstanceInfo] {
        let data = try await CloudAPIClient.request(
            host: host, service: service, action: "DescribeInstances", version: version,
            region: region, payload: payload, credential: credential
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
        return (try JSONDecoder().decode(ResponseEnvelope.self, from: data).Response.InstanceSet ?? []).map {
            ComputeInstanceInfo(instanceId: $0.InstanceId, state: $0.InstanceState, publicIP: $0.PublicIpAddresses?.first)
        }
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
