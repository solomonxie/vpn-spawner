import SwiftUI

/// Launching: count-up clock, step, estimate, live log. One action: cancel.
struct ProvisioningView: View {
    @ObservedObject var manager: SessionManager
    let session: SessionRecord
    @State private var confirmCancel = false

    var body: some View {
        let stage = session.stage ?? .preparing
        let total = ProvisionStage.allCases.count
        ScrollView {
            VStack(spacing: 28) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ElapsedClock(
                        since: session.startTime,
                        caption: session.estimatedSecondsLeft.map { "Launching · about \(Clock.format($0)) left" }
                            ?? "Launching · taking longer than usual"
                    )
                }
                .padding(.top, 24)

                VStack(spacing: 10) {
                    StepDots(current: stage.step, total: total)
                    Text(stage.rawValue)
                        .font(.headline)
                    Text("Step \(stage.step) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LiveLogView(lines: manager.activityLog)

                Label("Safe to close the app. It picks up where it left off, and the server deletes itself if you never come back.", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Cancel launch", role: .destructive) {
                    confirmCancel = true
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .confirmationDialog("Cancel this launch?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Launch & Clean Up", role: .destructive) {
                Task { await manager.terminateSession() }
            }
            Button("Keep Launching", role: .cancel) {}
        } message: {
            Text("Anything created so far is deleted.")
        }
    }
}

/// Cleaning up: count-up clock, current step, live log; retry if unverified.
struct StoppingView: View {
    @ObservedObject var manager: SessionManager
    let session: SessionRecord

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ElapsedClock(since: session.stopStartedAt ?? Date(), caption: "Cleaning up")
                    .padding(.top, 24)

                HStack(spacing: 10) {
                    if manager.isOperating {
                        ProgressView()
                    }
                    Text(manager.operationStatusMessage.isEmpty ? "Waiting to retry" : manager.operationStatusMessage)
                        .font(.headline)
                }

                LiveLogView(lines: manager.activityLog)

                if let error = session.errorMessage, !manager.isOperating {
                    VStack(spacing: 14) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button {
                            Task { await manager.terminateSession() }
                        } label: {
                            Text("Retry Clean Up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .tint(.red)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }
}

/// Launch failed: say why, offer the one thing to do next.
struct FailedView: View {
    @ObservedObject var manager: SessionManager
    let session: SessionRecord

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.orange)
                    .padding(.top, 40)
                Text("Launch didn't finish")
                    .font(.title3.weight(.semibold))
                Text(session.errorMessage ?? "Something went wrong while starting the server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await manager.terminateSession() }
                } label: {
                    Text("Clean Up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(manager.isOperating)

                Text("Deletes anything it created, then you can launch again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !manager.activityLog.isEmpty {
                    LiveLogView(lines: manager.activityLog)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { step in
                Capsule()
                    .fill(step <= current ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary))
                    .frame(width: step == current ? 22 : 8, height: 8)
            }
        }
        .animation(.spring(duration: 0.4), value: current)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}
