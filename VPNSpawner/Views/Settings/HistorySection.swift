import SwiftUI

/// Session history + activity logs, rendered as the last sections of Settings.
struct HistorySection: View {
    @ObservedObject var manager: SessionManager

    static let recentCount = 5

    var body: some View {
        Section {
            if manager.history.isEmpty {
                Text("No past sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.history.prefix(Self.recentCount)) { session in
                    Self.sessionRow(session)
                }
            }
            // Pushed, not a sheet: a sheet attached inside a Form section closed itself on first open.
            NavigationLink {
                ActivityLogView(manager: manager)
            } label: {
                HStack {
                    Label("Activity log", systemImage: "list.bullet.rectangle")
                    Spacer()
                    let older = max(0, manager.history.count - Self.recentCount)
                    if older > 0 {
                        Text("\(older) older")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("History")
        }
    }

    static func sessionRow(_ session: SessionRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.cleanupVerified == true ? "checkmark.seal.fill" : "clock.arrow.circlepath")
                .foregroundStyle(session.cleanupVerified == true ? .green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.startTime, format: .dateTime.month().day().hour().minute())
                    if session.isDemo { DemoBadge() }
                }
                Text("\(IdleView.regionName(session.region)) · \(session.instanceId ?? "no server")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.cleanupVerified == true ? "Deleted" : session.status.rawValue)
                .font(.caption)
                .foregroundStyle(session.status == .terminated ? Color.secondary : Color.red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.cleanupVerified == true ? "Verified deleted" : session.status.rawValue)
    }
}

/// Older sessions (beyond the latest few) and the app's activity log.
struct ActivityLogView: View {
    @ObservedObject var manager: SessionManager

    var body: some View {
        List {
            let older = manager.history.dropFirst(HistorySection.recentCount)
            if !older.isEmpty {
                Section("Earlier sessions") {
                    ForEach(Array(older)) { HistorySection.sessionRow($0) }
                }
            }
            Section("Log") {
                if manager.logs.isEmpty {
                    Text("Nothing logged since the app started.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(manager.logs.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Activity Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
