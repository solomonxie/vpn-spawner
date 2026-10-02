import Foundation

/// "What IP does the internet see?" from many echo services at once; first answer wins.
/// Services are often blocked or unreliable outside their home country, so they're grouped,
/// and the group matching where traffic exits is tried first (the rest race right behind it).
enum IPEcho {
    struct Answer {
        let ip: String
        let place: String?
        let source: String
    }

    private enum Parse { case plain, ipip, cipcc, json(ip: String, place: [String]) }

    private struct Source {
        let url: String
        let parse: Parse
    }

    private static let mainlandChina: [Source] = [
        Source(url: "https://myip.ipip.net", parse: .ipip),
        Source(url: "http://cip.cc", parse: .cipcc),
        Source(url: "https://ip.3322.net", parse: .plain),
    ]

    private static let global: [Source] = [
        Source(url: "https://ipinfo.io/json", parse: .json(ip: "ip", place: ["city", "region", "country"])),
        Source(url: "http://ip-api.com/json/?fields=query,city,regionName,country", parse: .json(ip: "query", place: ["city", "regionName", "country"])),
        Source(url: "https://api.ipify.org", parse: .plain),
        Source(url: "https://ifconfig.me/ip", parse: .plain),
        Source(url: "https://icanhazip.com", parse: .plain),
        Source(url: "https://checkip.amazonaws.com", parse: .plain),
    ]

    /// Tencent regions inside mainland China, where Chinese echo services are the reliable ones.
    static let mainlandRegions: Set<String> = [
        "ap-guangzhou", "ap-shanghai", "ap-beijing", "ap-chengdu", "ap-chongqing", "ap-nanjing",
    ]

    /// - Parameter preferChina: exit (or device) is in mainland China; gives those sources a head start.
    static func lookup(preferChina: Bool, timeout: TimeInterval = 6) async throws -> Answer {
        let (first, second) = preferChina ? (mainlandChina, global) : (global, mainlandChina)
        let ordered = first.map { ($0, 0.0) } + second.map { ($0, 0.4) }
        let answer = await withTaskGroup(of: Answer?.self) { group -> Answer? in
            for (source, delay) in ordered {
                group.addTask {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    return await query(source, timeout: timeout)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        guard let answer else { throw CloudAPIError.badResponse("No IP check service reachable") }
        return answer
    }

    private static func query(_ source: Source, timeout: TimeInterval) async -> Answer? {
        guard let url = URL(string: source.url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        // Several echo services return a web page to browsers but plain text to curl.
        request.setValue("curl/8.4.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else { return nil }
        let host = url.host ?? source.url
        switch source.parse {
        case .plain:
            return firstIPv4(in: body).map { Answer(ip: $0, place: nil, source: host) }
        case .ipip:
            let place = body.components(separatedBy: "来自于：").dropFirst().first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return firstIPv4(in: body).map { Answer(ip: $0, place: place, source: host) }
        case .cipcc:
            let place = body.split(separator: "\n")
                .first { $0.hasPrefix("地址") }?
                .components(separatedBy: ":").dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
            return firstIPv4(in: body).map { Answer(ip: $0, place: place, source: host) }
        case .json(let ipKey, let placeKeys):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = json[ipKey] as? String, firstIPv4(in: ip) == ip else { return nil }
            let place = placeKeys.compactMap { json[$0] as? String }.filter { !$0.isEmpty }.joined(separator: ", ")
            return Answer(ip: ip, place: place.isEmpty ? nil : place, source: host)
        }
    }

    static func firstIPv4(in text: String) -> String? {
        guard let range = text.range(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
