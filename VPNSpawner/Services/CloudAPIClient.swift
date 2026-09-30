import Foundation

enum CloudAPIError: LocalizedError {
    case api(code: String, message: String)
    case badResponse(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .api(let code, let message): return "\(code): \(message)"
        case .badResponse(let message): return message
        case .invalidURL: return "Invalid API URL"
        }
    }

    static func parse(data: Data) -> CloudAPIError {
        if let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data),
           let error = envelope.Response.Error {
            return .api(code: error.Code, message: error.Message)
        }
        return .badResponse(String(data: data, encoding: .utf8) ?? "Cloud request failed")
    }
}

private struct CloudErrorEnvelope: Decodable {
    struct Body: Decodable {
        struct APIError: Decodable {
            let Code: String
            let Message: String
        }
        let Error: APIError?
    }
    let Response: Body
}

enum CloudAPIClient {
    static func request(
        host: String,
        service: String,
        action: String,
        version: String,
        region: String? = nil,
        payload: [String: Any],
        credential: CloudSigner.Credential
    ) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "https://\(host)/") else {
            throw CloudAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        for (key, value) in CloudSigner.headers(
            host: host,
            service: service,
            action: action,
            version: version,
            region: region,
            payload: body,
            credential: credential
        ) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudAPIError.parse(data: data)
        }
        if let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data),
           let error = envelope.Response.Error {
            throw CloudAPIError.api(code: error.Code, message: error.Message)
        }
        return data
    }
}
