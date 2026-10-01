import SwiftUI

struct LaunchCardView: View {
    @ObservedObject var manager: SessionManager
    @State private var selectedRegion = "ap-guangzhou"
    @State private var selectedDuration = 30
    @State private var selectedCipher = "chacha20-ietf-poly1305"
    @State private var portString = "8388"

    private let availableRegions = [
        ("ap-guangzhou", "Guangzhou (ap-guangzhou)"),
        ("ap-shanghai", "Shanghai (ap-shanghai)"),
        ("ap-beijing", "Beijing (ap-beijing)"),
        ("ap-hongkong", "Hong Kong (ap-hongkong)"),
        ("ap-tokyo", "Tokyo (ap-tokyo)"),
        ("ap-singapore", "Singapore (ap-singapore)"),
    ]

    private let durations = [30, 60, 120]
    private let ciphers = [
        "chacha20-ietf-poly1305",
        "aes-256-gcm",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch New Node")
                    .font(.title2.bold())
                Text("Deploys an ephemeral Tencent Cloud instance with automatic one-hour scheduled teardown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cloud Region")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("Region", selection: $selectedRegion) {
                        ForEach(availableRegions, id: \.0) { region in
                            Text(region.1).tag(region.0)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Session Lifetime")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Picker("Duration", selection: $selectedDuration) {
                            ForEach(durations, id: \.self) { min in
                                Text("\(min) min").tag(min)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cipher")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Picker("Cipher", selection: $selectedCipher) {
                            ForEach(ciphers, id: \.self) { cipher in
                                Text(cipher).tag(cipher)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Port")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        TextField("8388", text: $portString)
                            .keyboardType(.numberPad)
                            .padding(10)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(width: 90)
                }

                HStack {
                    Image(systemName: "clock.badge.checkmark")
                        .foregroundStyle(.blue)
                    Text("Auto-terminates after expiry. No permanent billing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                let port = Int(portString) ?? 8388
                Task {
                    await manager.launchSession(
                        region: selectedRegion,
                        durationMinutes: selectedDuration,
                        cipher: selectedCipher,
                        port: port
                    )
                }
            } label: {
                Label("Launch Node", systemImage: "bolt.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isOperating)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}
