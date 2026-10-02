import CoreLocation
import Foundation

/// Checks what the internet (and apps) can still learn about the user's location with the VPN on.
@MainActor
final class PrivacyCheck: ObservableObject {
    enum Status { case running, pass, warn, fail, skipped }

    enum Kind: String, CaseIterable, Identifiable {
        case exitIP, ipv6, dns, location, timeZone
        var id: String { rawValue }

        var title: String {
            switch self {
            case .exitIP: return "Exit IP"
            case .ipv6: return "IPv6 leak"
            case .dns: return "DNS"
            case .location: return "Location Services"
            case .timeZone: return "Time zone & region"
            }
        }

        var symbol: String {
            switch self {
            case .exitIP: return "network"
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

    var passed: Int { results.filter { $0.status == .pass }.count }
    var counted: Int { results.filter { $0.status != .skipped && $0.status != .running }.count }

    func run(nodeIP: String) async {
        isRunning = true
        defer { isRunning = false }
        results = Kind.allCases.map { Result(kind: $0, status: .running, summary: "Checking…") }

        let exit = await checkExitIP(nodeIP: nodeIP)
        update(exit)
        async let v6 = checkIPv6()
        async let dns = checkDNS()
        update(await v6)
        update(await dns)
        update(await checkLocationServices())
        update(checkTimeZone())
    }

    private func update(_ result: Result) {
        if let i = results.firstIndex(where: { $0.kind == result.kind }) {
            results[i] = result
        }
    }

    // MARK: Checks

    private func checkExitIP(nodeIP: String) async -> Result {
        // myip.ipip.net answers from mainland China and includes a location: "当前 IP：x  来自于：中国 广东 广州 电信"
        if let body = await Self.fetch("https://myip.ipip.net"), let ip = Self.firstIPv4(in: body) {
            let place = body.components(separatedBy: "来自于：").dropFirst().first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            exitLocation = place
            return ip == nodeIP
                ? Result(kind: .exitIP, status: .pass, summary: "\(ip)\(place.map { " · \($0)" } ?? "")",
                         advice: "Sites see the server's address, not yours.")
                : Result(kind: .exitIP, status: .fail, summary: "Sites see \(ip), not the server",
                         advice: "Turn the VPN on (Connect), wait for Connected, then run again.")
        }
        if let body = await Self.fetch("https://ip.3322.net"), let ip = Self.firstIPv4(in: body) {
            return Result(kind: .exitIP, status: ip == nodeIP ? .pass : .fail, summary: ip,
                          advice: ip == nodeIP ? nil : "Turn the VPN on, then run again.")
        }
        return Result(kind: .exitIP, status: .fail, summary: "Couldn't reach an IP checker",
                      advice: "No internet through the tunnel. Disconnect and Connect again.")
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
