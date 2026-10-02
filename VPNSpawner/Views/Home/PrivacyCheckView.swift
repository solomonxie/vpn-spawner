import SwiftUI

/// Runs the in-app privacy checks and explains what a VPN can and can't hide.
struct PrivacyCheckView: View {
    let nodeIP: String
    @StateObject private var check = PrivacyCheck()

    private static let browserTests: [(title: String, url: String, what: String)] = [
        ("browserleaks.com/ip", "https://browserleaks.com/ip", "IP, IPv6, location, time zone"),
        ("browserleaks.com/webrtc", "https://browserleaks.com/webrtc", "WebRTC address leaks"),
        ("ipleak.net", "https://ipleak.net", "IP, DNS and torrent leaks"),
        ("dnsleaktest.com", "https://www.dnsleaktest.com", "Which DNS servers answer you"),
    ]

    var body: some View {
        List {
            Section {
                summary
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                ForEach(check.results) { CheckRow(result: $0) }
            } header: {
                Text("This iPhone, through the VPN")
            }

            Section {
                ForEach(Self.hiddenFacts, id: \.title) { fact in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.title).font(.subheadline.weight(.medium))
                            Text(fact.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: fact.symbol).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What a VPN can't hide")
            } footer: {
                Text("A VPN changes the address websites see. Anything an app reads from the phone itself still tells the truth.")
            }

            Section {
                ForEach(Self.browserTests, id: \.url) { test in
                    Link(destination: URL(string: test.url)!) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(test.title).foregroundStyle(.primary)
                                Text(test.what).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Browser tests")
            } footer: {
                Text("Open in Safari with the VPN on. They also catch browser-only leaks such as WebRTC. Some load slowly or not at all from mainland China.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy check")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check.run(nodeIP: nodeIP) }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: summarySymbol)
                .font(.title)
                .foregroundStyle(summaryColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryTitle).font(.headline)
                Text("Server \(nodeIP)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await check.run(nodeIP: nodeIP) }
            } label: {
                Text("Run again")
            }
            .buttonStyle(.bordered)
            .disabled(check.isRunning)
        }
        .padding(.horizontal, 4)
    }

    private var summaryTitle: String {
        if check.isRunning { return "Checking…" }
        return "\(check.passed) of \(check.counted) look good"
    }

    private var summarySymbol: String {
        if check.isRunning { return "hourglass" }
        return check.passed == check.counted ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var summaryColor: Color {
        if check.isRunning { return .secondary }
        return check.passed == check.counted ? .green : .orange
    }

    private static let hiddenFacts: [(title: String, detail: String, symbol: String)] = [
        ("GPS and Wi-Fi positioning", "Apps with location access get your real position. Set untrusted apps to Never in Location Services.", "location.fill"),
        ("SIM and carrier", "Your carrier's country code is readable by apps and sometimes sent to servers.", "simcard"),
        ("Apple ID and app store region", "Apps can tailor by your account region, not your IP.", "person.crop.circle"),
        ("Accounts and history", "Signed-in services remember where you usually are. Logging in reveals you even over a VPN.", "clock.arrow.circlepath"),
        ("Time zone and language", "Websites read them directly from the browser.", "globe"),
    ]
}

private struct CheckRow: View {
    let result: PrivacyCheck.Result

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.kind.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(result.summary)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if let advice = result.advice {
                    Text(advice).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if result.status == .running {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch result.status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .running: return "circle"
        }
    }

    private var color: Color {
        switch result.status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .skipped, .running: return .secondary
        }
    }

    private var statusLabel: String {
        switch result.status {
        case .pass: return "OK"
        case .warn: return "Check"
        case .fail: return "Leak"
        case .skipped: return "Skipped"
        case .running: return ""
        }
    }
}
