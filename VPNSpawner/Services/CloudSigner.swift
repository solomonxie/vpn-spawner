import Foundation
import CryptoKit

enum CloudSigner {
    struct Credential: Equatable, Hashable {
        let secretId: String
        let secretKey: String
        let sessionToken: String?

        init(secretId: String, secretKey: String, sessionToken: String? = nil) {
            self.secretId = secretId
            self.secretKey = secretKey
            self.sessionToken = sessionToken
        }
    }

    static func headers(
        host: String,
        service: String,
        action: String,
        version: String,
        region: String?,
        payload: Data,
        credential: Credential,
        date: Date = Date()
    ) -> [String: String] {
        let timestamp = Int(date.timeIntervalSince1970)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateStamp = dateFormatter.string(from: date)

        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
        let signedHeaders = "content-type;host;x-tc-action"
        let hashedPayload = sha256Hex(payload)

        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            hashedPayload,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(timestamp),
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let secretDate = hmac(key: SymmetricKey(data: Data("TC3\(credential.secretKey)".utf8)), data: Data(dateStamp.utf8))
        let secretService = hmac(key: SymmetricKey(data: secretDate), data: Data(service.utf8))
        let secretSigning = hmac(key: SymmetricKey(data: secretService), data: Data("tc3_request".utf8))
        let signature = hmac(key: SymmetricKey(data: secretSigning), data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        let authorization = "TC3-HMAC-SHA256 Credential=\(credential.secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var result = [
            "Authorization": authorization,
            "Content-Type": contentType,
            "Host": host,
            "X-TC-Action": action,
            "X-TC-Timestamp": String(timestamp),
            "X-TC-Version": version,
        ]
        if let region { result["X-TC-Region"] = region }
        if let token = credential.sessionToken { result["X-TC-Token"] = token }
        return result
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }
}
