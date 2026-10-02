import CryptoKit
import Foundation

/// Invokes the AWS controller Lambda (synchronous Invoke API) with SigV4-signed requests.
enum LambdaClient {
    static func invoke(payload: [String: Any], config: AWSCredentialConfig, secret: String) async throws -> Data {
        let host = "lambda.\(config.functionRegion).amazonaws.com"
        let path = "/2015-03-31/functions/\(config.functionName)/invocations"
        guard let url = URL(string: "https://\(host)\(path)") else { throw CloudAPIError.invalidURL }
        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        // Terminate waits up to ~2 min for the security group to free up.
        request.timeoutInterval = 200
        for (name, value) in AWSSigner.headers(
            method: "POST", host: host, path: path, body: body,
            service: "lambda", region: config.functionRegion,
            accessKeyId: config.accessKeyId, secret: secret
        ) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, (200...299).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw CloudAPIError.api(code: "AWS \(http?.statusCode ?? 0)", message: message ?? String(decoding: data, as: UTF8.self))
        }
        if http?.value(forHTTPHeaderField: "X-Amz-Function-Error") != nil {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["errorMessage"] as? String
            throw CloudAPIError.api(code: "ControllerError", message: message ?? "Lambda function failed")
        }
        return data
    }
}

/// AWS Signature Version 4 for a single JSON POST.
enum AWSSigner {
    static func headers(
        method: String, host: String, path: String, body: Data,
        service: String, region: String, accessKeyId: String, secret: String, date: Date = Date()
    ) -> [String: String] {
        let stamp = formatted(date, "yyyyMMdd'T'HHmmss'Z'")
        let day = String(stamp.prefix(8))
        let payloadHash = hex(SHA256.hash(data: body))
        let canonicalHeaders = "content-type:application/json\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(stamp)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [method, uriEncodePath(path), "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        return [
            "Content-Type": "application/json",
            "X-Amz-Date": stamp,
            "X-Amz-Content-Sha256": payloadHash,
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }

    /// SigV4 canonical URI: each path segment URI-encoded (Lambda function names are already safe, ARNs aren't).
    private static func uriEncodePath(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: date)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
