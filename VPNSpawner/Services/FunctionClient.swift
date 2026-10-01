import Foundation

struct ControllerInvocationResult: Decodable {
    let success: Bool
    let status: String?
    let instanceId: String?
    let publicIP: String?
    let message: String?
    let securityGroupId: String?
    let allowedIps: [String]?
    let ikev2Psk: String?
}

enum FunctionClient {
    private static let host = "scf.tencentcloudapi.com"
    private static let service = "scf"
    private static let version = "2018-04-16"

    static func invoke(
        functionName: String,
        region: String,
        action: String,
        session: SessionRecord,
        extra: [String: Any] = [:],
        credential: CloudSigner.Credential
    ) async throws -> ControllerInvocationResult {
        var requestDict: [String: Any] = [
            "action": action,
            "sessionId": session.id,
            "region": region,
            "instanceId": session.instanceId ?? "",
            "shadowsocks": [
                "port": session.shadowsocks.port,
                "password": session.shadowsocks.password,
                "method": session.shadowsocks.method,
            ],
            "expiryTimestamp": Int(session.expiryTime.timeIntervalSince1970),
        ]
        if let sgId = session.securityGroupId {
            requestDict["securityGroupId"] = sgId
        }
        requestDict.merge(extra) { _, new in new }

        let clientContextData = try JSONSerialization.data(withJSONObject: requestDict)
        let clientContextString = String(data: clientContextData, encoding: .utf8) ?? "{}"

        let payload: [String: Any] = [
            "FunctionName": functionName,
            "Qualifier": "$LATEST",
            "InvocationType": "RequestResponse",
            "ClientContext": clientContextString,
        ]

        let data = try await CloudAPIClient.request(
            host: host,
            service: service,
            action: "InvokeFunction",
            version: version,
            region: region,
            payload: payload,
            credential: credential
        )

        struct SCFInvokeResponse: Decodable {
            struct Result: Decodable {
                let RetMsg: String?
                let FunctionRequestId: String?
                let ErrorMessage: String?
            }
            struct Body: Decodable {
                let Result: Result?
            }
            let Response: Body
        }

        let decoded = try JSONDecoder().decode(SCFInvokeResponse.self, from: data)
        if let errMsg = decoded.Response.Result?.ErrorMessage, !errMsg.isEmpty {
            throw CloudAPIError.api(code: "ControllerError", message: errMsg)
        }

        if let retMsg = decoded.Response.Result?.RetMsg,
           let retData = retMsg.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ControllerInvocationResult.self, from: retData) {
            return parsed
        }

        return ControllerInvocationResult(
            success: true,
            status: "ok",
            instanceId: nil,
            publicIP: nil,
            message: decoded.Response.Result?.RetMsg,
            securityGroupId: nil,
            allowedIps: nil,
            ikev2Psk: nil
        )
    }
}
