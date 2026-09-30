import SwiftUI

struct HistoryView: View {
    @ObservedObject var manager: SessionManager
    @State private var showLogsSheet = false

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        NavigationStack {
            List {
                if manager.history.isEmpty {
                    ContentUnavailableView(
                        "No Past Sessions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Terminated sessions and cleanup audits will appear here.")
                    )
                } else {
                    Section {
                        ForEach(manager.history) { session in
                            sessionRow(session)
                        }
                    } header: {
                        Text("Session History")
                    }
                }
            }
            .navigationTitle("History & Audit")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLogsSheet = true
                    } label: {
                        Label("Logs", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showLogsSheet) {
                logsSheet
            }
        }
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.id)
                    .font(.headline)
                if session.isDemo {
                    Text("DEMO")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(session.status.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(session.status == .terminated ? Color.secondary : Color.red)
            }

            HStack {
                Text("Region: \(session.region)")
                Spacer()
                Text(session.instanceId ?? "unallocated")
                    .font(.system(.caption, design: .monospaced))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Text(dateFormatter.string(from: session.startTime))
                Spacer()
                Text(String(format: "Cost: ¥%.2f", session.currentCostEstimate))
                    .font(.caption.bold())
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var logsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.logs, id: \.self) { log in
                        Text(log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Activity Logs")
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
