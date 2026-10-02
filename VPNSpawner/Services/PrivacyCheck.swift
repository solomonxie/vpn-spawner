import CoreLocation
import Foundation

/// Checks what the internet (and apps) can still learn about the user's location with the VPN on.
@MainActor
final class PrivacyCheck: ObservableObject {
    enum Status { case running, pass, warn, fail, skipped }

    enum Kind: String, CaseIterable, Identifiable {
        case exitIP, provider, ipv6, dns, latency, speed, location, timeZone
        var id: String { rawValue }

        var title: String {
            switch self {
            case .exitIP: return "Exit IP"
            case .provider: return "Provider & geolocation"
            case .latency: return "Latency to server"
            case .speed: return "Download speed"
            case .ipv6: return "IPv6 leak"
            case .dns: return "DNS"
            case .location: return "Location Services"
            case .timeZone: return "Time zone & region"
            }
        }

        var symbol: String {
            switch self {
            case .exitIP: return "network"
            case .provider: return "building.2"
            case .latency: return "stopwatch"
            case .speed: return "speedometer"
            case .ipv6: return "6.circle"
            case .dns: return "signpost.right"
            case .location: return "location"
            case .timeZone: return "clock"
            }
        }
    }

    struct Result: Identifiable {
        let kind: Kind
        var status: Status
        var summary: String
        var advice: String?
        var id: Kind { kind }
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var isRunning = false
    /// Exit location as reported by myip.ipip.net, e.g. "中国 广东 广州 电信".
    @Published private(set) var exitLocation: String?
    /// Exit IP's time zone per the geolocation database (ipinfo / ip-api), e.g. "Asia/Shanghai".
    private var exitTimeZone: String?
    private var preferChina = true

    var passed: Int { results.filter { $0.status == .pass }.count }
    var counted: Int { results.filter { $0.status != .skipped && $0.status != .running }.count }

    func run(nodeIP: String, region: String? = nil) async {
        preferChina = region.map(IPEcho.mainlandRegions.contains) ?? true
        isRunning = true
        defer { isRunning = false }
        results = Kind.allCases.map { Result(kind: $0, status: .running, summary: "Checking…") }

        let exit = await checkExitIP(nodeIP: nodeIP)
        update(exit)
        update(await checkProvider(nodeIP: nodeIP))
        async let v6 = checkIPv6()
        async let dns = checkDNS()
        async let latency = checkLatency(nodeIP: nodeIP)
        update(await v6)
        update(await dns)
        update(await latency)
        update(await checkLocationServices())
        update(checkTimeZone())
        update(await checkSpeed())
    }

    private func update(_ result: Result) {
        if let i = results.firstIndex(where: { $0.kind == result.kind }) {
            results[i] = result
        }
    }

    // MARK: Checks

    private func checkExitIP(nodeIP: String) async -> Result {
        // Many echo services race (country-appropriate ones first); first answer wins.
        guard let answer = try? await IPEcho.lookup(preferChina: preferChina) else {
            return Result(kind: .exitIP, status: .fail, summary: "No IP check service reachable",
                          advice: "No internet through the tunnel. Disconnect and Connect again.")
        }
        exitLocation = answer.place
        let summary = "\(answer.ip)\(answer.place.map { " · \($0)" } ?? "") (\(answer.source))"
        return answer.ip == nodeIP
            ? Result(kind: .exitIP, status: .pass, summary: summary, advice: "Sites see the server's address, not yours.")
            : Result(kind: .exitIP, status: .fail, summary: "Sites see \(summary), not the server",
                     advice: "Turn the VPN on (Connect), wait for Connected, then run again.")
    }

    /// What IP-lookup apps (Speedtest, Fing…) show: provider and city, here from two independent databases.
    private func checkProvider(nodeIP: String) async -> Result {
        var reports: [(source: String, ip: String, place: String, org: String, zone: String?)] = []
        if let json = await Self.fetchJSON("https://ipinfo.io/json"), let ip = json["ip"] as? String {
            let place = [json["city"], json["region"], json["country"]].compactMap { $0 as? String }.joined(separator: ", ")
            reports.append(("ipinfo", ip, place, json["org"] as? String ?? "?", json["timezone"] as? String))
        }
        if let json = await Self.fetchJSON("http://ip-api.com/json/?fields=status,country,regionName,city,isp,as,timezone,query"),
           let ip = json["query"] as? String {
            let place = [json["city"], json["regionName"], json["country"]].compactMap { $0 as? String }.joined(separator: ", ")
            reports.append(("ip-api", ip, place, json["isp"] as? String ?? "?", json["timezone"] as? String))
        }
        guard let first = reports.first else {
            return Result(kind: .provider, status: .skipped, summary: "Geolocation services unreachable",
                          advice: "They're sometimes blocked from mainland China. The exit IP check above still applies.")
        }
        exitTimeZone = reports.compactMap(\.zone).first
        let summary = reports.map { "\($0.org) · \($0.place) (\($0.source))" }.joined(separator: "\n")
        if reports.contains(where: { $0.ip != nodeIP }) {
            return Result(kind: .provider, status: .fail, summary: summary,
                          advice: "A lookup saw an address other than the server's. Reconnect, then run again.")
        }
        let countries = Set(reports.map { $0.place.components(separatedBy: ", ").last ?? "" })
        if countries.count > 1 {
            return Result(kind: .provider, status: .warn, summary: summary,
                          advice: "Location databases disagree about this server's country, so some sites may place you differently.")
        }
        return Result(kind: .provider, status: .pass, summary: summary,
                      advice: "Sites see a cloud provider in \(first.place), not your home network.")
    }

    /// Round trip to the node's own endpoint (median of 3).
    private func checkLatency(nodeIP: String) async -> Result {
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = Date()
            if await Self.fetch("http://\(nodeIP):8389/health", timeout: 5) != nil {
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        guard !samples.isEmpty else {
            return Result(kind: .latency, status: .fail, summary: "Server didn't answer",
                          advice: "If your IP changed, use \"Allow this device's current IP\".")
        }
        let ms = Int(samples.sorted()[samples.count / 2])
        let status: Status = ms < 200 ? .pass : (ms < 500 ? .warn : .fail)
        return Result(kind: .latency, status: status, summary: "\(ms) ms",
                      advice: status == .pass ? "Responsive enough for browsing and calls." : "Slow link; a closer region may help.")
    }

    /// Streams up to 5 MB from a large file on a China-friendly mirror and stops; works without Range support.
    private func checkSpeed() async -> Result {
        let limit = 5 * 1024 * 1024
        for urlString in ["https://mirrors.tencent.com/ubuntu/ls-lR.gz", "https://speed.cloudflare.com/__down?bytes=5242880"] {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let start = Date()
            var received = 0
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                for try await _ in bytes {
                    received += 1
                    if received >= limit || Date().timeIntervalSince(start) > 15 { break }
                }
            } catch {
                continue
            }
            guard received > 256 * 1024 else { continue }
            let mbps = Double(received) * 8 / Date().timeIntervalSince(start) / 1_000_000
            let status: Status = mbps >= 5 ? .pass : .warn
            return Result(kind: .speed, status: status, summary: String(format: "%.1f Mbps", mbps),
                          advice: status == .pass ? "Fine for video and calls." : "Slow; try another region or protocol.")
        }
        return Result(kind: .speed, status: .skipped, summary: "Speed test servers unreachable", advice: nil)
    }

    private func checkIPv6() async -> Result {
        for url in ["https://api6.ipify.org", "https://ipv6.icanhazip.com"] {
            if let body = await Self.fetch(url, timeout: 6) {
                let address = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if address.contains(":") {
                    return Result(kind: .ipv6, status: .fail, summary: "IPv6 goes around the VPN: \(address)",
                                  advice: "Sites that use IPv6 see your real network. Reconnect from this app (it routes all traffic through the tunnel), or turn off IPv6 on this Wi-Fi.")
                }
            }
        }
        return Result(kind: .ipv6, status: .pass, summary: "No IPv6 path outside the tunnel",
                      advice: "IPv6 can't reveal your real network.")
    }

    private func checkDNS() async -> Result {
        // edns.ip-api.com reports which resolver looked the name up. Often slow or blocked from mainland China.
        let host = "\(UUID().uuidString.prefix(8).lowercased()).edns.ip-api.com"
        guard let body = await Self.fetch("https://\(host)/json", timeout: 8),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dns = json["dns"] as? [String: Any],
              let resolver = dns["ip"] as? String else {
            return Result(kind: .dns, status: .skipped, summary: "DNS test service unreachable",
                          advice: "Try a browser test below (dnsleaktest.com) if it loads.")
        }
        let geo = (dns["geo"] as? String) ?? "unknown"
        let country = exitLocation.flatMap(Self.englishCountry)
        if let country, geo.localizedCaseInsensitiveContains(country) {
            return Result(kind: .dns, status: .pass, summary: "Resolver \(resolver) · \(geo)",
                          advice: "Name lookups happen in the server's country.")
        }
        return Result(kind: .dns, status: country == nil ? .skipped : .warn, summary: "Resolver \(resolver) · \(geo)",
                      advice: country == nil ? "Couldn't compare with the exit country."
                        : "Lookups go through a resolver outside the exit country. Reconnect from this app so DNS goes through the tunnel.")
    }

    private func checkLocationServices() async -> Result {
        // Device-wide flag; Apple warns against calling it on the main thread.
        let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard enabled else {
            return Result(kind: .location, status: .pass, summary: "Off on this iPhone",
                          advice: "Apps can't read GPS or Wi-Fi position.")
        }
        return Result(kind: .location, status: .warn, summary: "On. Apps you allowed see your real position",
                      advice: "A VPN only changes your IP. GPS and Wi-Fi positioning ignore it. In Settings → Privacy & Security → Location Services, set apps you don't trust to Never.")
    }

    private func checkTimeZone() -> Result {
        let zone = TimeZone.current.identifier
        let region = Locale.current.region?.identifier ?? "?"
        if let exitZone = exitTimeZone {
            let same = TimeZone(identifier: exitZone)?.secondsFromGMT() == TimeZone.current.secondsFromGMT()
            return Result(kind: .timeZone, status: same ? .pass : .warn, summary: "\(zone) · region \(region)",
                          advice: same ? "Matches the exit IP's time zone (\(exitZone))."
                            : "The exit IP is in \(exitZone). Websites read your time zone and language directly, so a site that compares them can tell. Changing it affects your clock.")
        }
        guard let place = exitLocation, let expected = Self.zonePrefixes(for: place) else {
            return Result(kind: .timeZone, status: .skipped, summary: "\(zone) · region \(region)",
                          advice: "Couldn't compare with the exit country.")
        }
        let matches = expected.contains { zone.hasPrefix($0) }
        return Result(kind: .timeZone, status: matches ? .pass : .warn, summary: "\(zone) · region \(region)",
                      advice: matches ? "Matches the exit country."
                        : "Websites read your time zone and language directly; they don't match where the VPN exits. Only matters if a site checks; changing it affects your clock.")
    }

    // MARK: Helpers

    private static func fetch(_ url: String, timeout: TimeInterval = 6) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fetchJSON(_ url: String) async -> [String: Any]? {
        guard let body = await fetch(url), let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func firstIPv4(in text: String) -> String? {
        guard let range = text.range(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Countries the app's regions exit in, as ipip.net (Chinese) and ip-api (English) name them.
    private static let countries: [(chinese: String, english: String, zones: [String])] = [
        ("香港", "Hong Kong", ["Asia/Hong_Kong"]),
        ("中国", "China", ["Asia/Shanghai", "Asia/Chongqing", "Asia/Urumqi", "Asia/Harbin"]),
        ("日本", "Japan", ["Asia/Tokyo"]),
        ("新加坡", "Singapore", ["Asia/Singapore"]),
        ("美国", "United States", ["America/"]),
        ("德国", "Germany", ["Europe/Berlin"]),
    ]

    private static func englishCountry(_ place: String) -> String? {
        countries.first { place.contains($0.chinese) }?.english
    }

    private static func zonePrefixes(for place: String) -> [String]? {
        countries.first { place.contains($0.chinese) }?.zones
    }
}
