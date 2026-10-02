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
    var replaced: [String]? = nil
    var terminateAt: String? = nil
    var securityGroupDeleted: Bool? = nil
    var instances: [FoundInstance]? = nil

    struct FoundInstance: Decodable {
        let instanceId: String
        let status: String?
        let publicIP: String?
    }
}

/// One entry point to the controller function for both vendors (Tencent SCF, AWS Lambda).
/// Requests carry "vendor"; the function then manages the session's region on that cloud.
enum ControllerClient {
    static func invoke(
        _ action: String,
        session: SessionRecord,
        extra: [String: Any] = [:]
    ) async throws -> ControllerInvocationResult {
        var payload = FunctionClient.requestBody(action: action, session: session, region: session.region)
        payload.merge(extra) { _, new in new }
        switch session.vendor ?? .tencent {
        case .tencent:
            let (config, secretKey) = CloudCredentialConfig.load()
            return try await FunctionClient.invoke(
                functionName: config.controllerFunctionName,
                payload: payload,
                credential: CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)
            )
        case .aws:
            let (config, secret) = AWSCredentialConfig.load()
            payload["vendor"] = "aws"
            let data = try await LambdaClient.invoke(payload: payload, config: config, secret: secret)
            return try JSONDecoder().decode(ControllerInvocationResult.self, from: data)
        }
    }
}

enum FunctionClient {
    /// Where the controller function is deployed (docs/setup.md); it manages any region.
    static let functionRegion = CloudCredentialConfig.defaultRegion

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
        var payload = requestBody(action: action, session: session, region: region)
        payload.merge(extra) { _, new in new }
        return try await invoke(functionName: functionName, payload: payload, credential: credential)
    }

    static func requestBody(action: String, session: SessionRecord, region: String) -> [String: Any] {
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
        return requestDict
    }

    static func invoke(
        functionName: String,
        payload requestDict: [String: Any],
        credential: CloudSigner.Credential
    ) async throws -> ControllerInvocationResult {
        let clientContextData = try JSONSerialization.data(withJSONObject: requestDict)
        let clientContextString = String(data: clientContextData, encoding: .utf8) ?? "{}"

        let payload: [String: Any] = [
            "FunctionName": functionName,
            "Qualifier": "$LATEST",
            "InvocationType": "RequestResponse",
            "ClientContext": clientContextString,
        ]

        let data: Data
        do {
            data = try await CloudAPIClient.request(
                host: host,
                service: service,
                action: "Invoke",
                version: version,
                region: functionRegion,
                payload: payload,
                credential: credential
            )
        } catch CloudAPIError.api(let code, _) where code.contains("ResourceNotFound") {
            throw CloudAPIError.badResponse(
                "Cloud function \"\(functionName)\" isn't deployed in \(functionRegion). Use Settings → Runs from → This iPhone."
            )
        }

        struct SCFInvokeResponse: Decodable {
            struct Result: Decodable {
                let RetMsg: String?
                let FunctionRequestId: String?
                let ErrMsg: String?
            }
            struct Body: Decodable {
                let Result: Result?
            }
            let Response: Body
        }

        let decoded = try JSONDecoder().decode(SCFInvokeResponse.self, from: data)
        if let errMsg = decoded.Response.Result?.ErrMsg, !errMsg.isEmpty {
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
