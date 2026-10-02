import SwiftUI

/// No server running: pick protocols and lifetime, then one Launch button.
struct IdleView: View {
    @ObservedObject var manager: SessionManager
    @State private var prefs = LaunchPreferences.load()
    @State private var showMoreProtocols = false

    static let regions: [(id: String, name: String)] = [
        ("ap-guangzhou", "Guangzhou"),
        ("ap-shanghai", "Shanghai"),
        ("ap-beijing", "Beijing"),
        ("ap-hongkong", "Hong Kong"),
        ("ap-tokyo", "Tokyo"),
        ("ap-singapore", "Singapore"),
    ]

    static func regionName(_ id: String) -> String {
        regions.first { $0.id == id }?.name ?? id
    }

    private var primaryProtocols: [VPNProtocol] { [.ikev2, .shadowsocks] }
    private var moreProtocols: [VPNProtocol] { VPNProtocol.allCases.filter { !primaryProtocols.contains($0) } }

    var body: some View {
        List {
            Section {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(primaryProtocols) { protocolRow($0) }
                // Plain toggle row instead of DisclosureGroup: its first expand in a List was slow.
                Button {
                    showMoreProtocols.toggle()
                } label: {
                    HStack {
                        Text("More protocols")
                            .foregroundStyle(.primary)
                        Spacer()
                        let extra = moreProtocols.filter(prefs.protocols.contains).count
                        if extra > 0 {
                            Text("\(extra) on")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: showMoreProtocols ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMoreProtocols {
                    ForEach(moreProtocols) { protocolRow($0) }
                }
            } header: {
                HStack {
                    Text("Protocols")
                    Spacer()
                    Text("\(prefs.protocols.count) on")
                }
            } footer: {
                Text("IKEv2 connects right here. Others import into Shadowrocket or WireGuard.")
            }

            Section("Server") {
                Picker("Region", selection: $prefs.region) {
                    ForEach(Self.regions, id: \.id) { region in
                        Text(region.name).tag(region.id)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Auto-destroy after")
                    Picker("Auto-destroy after", selection: $prefs.durationMinutes) {
                        ForEach(LaunchPreferences.durations, id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { launchBar }
        .onChange(of: prefs) { _, new in new.save() }
    }

    private var hero: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("No server running")
                    .font(.headline)
                Text("Ready in ~2 min · deletes itself when time's up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func protocolRow(_ proto: VPNProtocol) -> some View {
        let isOn = prefs.protocols.contains(proto)
        return Button {
            if isOn {
                prefs.protocols.remove(proto)
            } else {
                prefs.protocols.insert(proto)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: proto.symbol)
                    .font(.body)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(proto.displayName)
                            .foregroundStyle(.primary)
                        if proto.isNative {
                            Text("Built in")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(proto.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var launchBar: some View {
        VStack(spacing: 8) {
            if let error = manager.launchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await manager.launch(prefs) }
            } label: {
                Text("Launch")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(manager.isOperating || prefs.protocols.isEmpty)
            Text("About ¥0.05/hr · \(Self.regionName(prefs.region)) · auto-destroys after \(prefs.durationMinutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
