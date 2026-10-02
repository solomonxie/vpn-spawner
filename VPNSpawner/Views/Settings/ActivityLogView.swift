import SwiftUI

enum SessionRow {
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

/// Every past session plus the app's activity log.
struct ActivityLogView: View {
    @ObservedObject var manager: SessionManager

    var body: some View {
        List {
            Section("Sessions") {
                if manager.history.isEmpty {
                    Text("No past sessions").foregroundStyle(.secondary)
                }
                ForEach(manager.history) { SessionRow.sessionRow($0) }
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
