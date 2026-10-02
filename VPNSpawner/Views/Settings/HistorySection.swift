import SwiftUI

/// Session history + activity logs, rendered as the last sections of Settings.
struct HistorySection: View {
    @ObservedObject var manager: SessionManager
    @State private var showLogsSheet = false

    var body: some View {
        Section {
            if manager.history.isEmpty {
                Text("No past sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.history) { session in
                    sessionRow(session)
                }
            }
            Button {
                showLogsSheet = true
            } label: {
                Label("Activity log", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("History")
        }
        .sheet(isPresented: $showLogsSheet) {
            logsSheet
        }
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
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

    private var logsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.logs, id: \.self) { log in
                        Text(log)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showLogsSheet = false
                    }
                }
            }
        }
    }
}
