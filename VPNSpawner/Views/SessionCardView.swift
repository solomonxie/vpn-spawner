import SwiftUI

struct SessionCardView: View {
    @ObservedObject var manager: SessionManager
    let session: SessionRecord
    @State private var showPassword = false
    @State private var showQRCode = false
    @State private var showStopConfirmation = false
    @State private var copiedNotice = false

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            timerSection
            if session.status == .ready {
                connectionDetailsSection
                actionButtonsSection
            } else if session.status == .provisioning {
                provisioningSection
            } else if session.status == .failed {
                failureSection
            }
            footerControlsSection
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .sheet(isPresented: $showQRCode) {
            QRCodeView(
                content: session.shadowsocks.uriString,
                title: "\(session.region) Shadowsocks"
            )
        }
        .confirmationDialog(
            "Stop & Teardown Node?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop & Clean Up Resources", role: .destructive) {
                Task { await manager.terminateSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will immediately terminate CVM node (\(session.instanceId ?? "unallocated")), release its public IP (\(session.publicIP ?? "none")), and stop cloud provider billing.")
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.id)
                        .font(.headline)
                    if session.isDemo {
                        Text("DEMO")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }
                Text("Region: \(session.region)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        Text(session.status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch session.status {
        case .idle: return .gray
        case .provisioning: return .orange
        case .ready: return .green
        case .stopping: return .yellow
        case .terminated: return .gray
        case .failed: return .red
        }
    }

    private var timerSection: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                .frame(width: 140, height: 140)

            Circle()
                .trim(from: 0, to: CGFloat(session.progress))
                .stroke(
                    AngularGradient(
                        colors: [.blue, .cyan, .teal],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 140, height: 140)
                .animation(.linear(duration: 1.0), value: session.progress)

            VStack(spacing: 4) {
                Text(session.formattedRemainingTime)
                    .font(.system(.title2, design: .monospaced, weight: .bold))
                Text("Remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var provisioningSection: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(manager.operationStatusMessage.isEmpty ? "Spinning up CVM instance..." : manager.operationStatusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var failureSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title2)
            Text(session.errorMessage ?? "An error occurred during provisioning.")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var connectionDetailsSection: some View {
        VStack(spacing: 10) {
            Divider()

            detailRow(title: "Public IP", value: session.publicIP ?? "—", copyable: true)
            detailRow(title: "Port", value: "\(session.shadowsocks.port)", copyable: false)
            detailRow(title: "Cipher", value: session.shadowsocks.method, copyable: false)

            HStack {
                Text("Password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(showPassword ? session.shadowsocks.password : "••••••••••••")
                    .font(.system(.subheadline, design: .monospaced))
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                Button {
                    UIPasteboard.general.string = session.shadowsocks.password
                    flashCopied()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Est. Cost")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "¥%.2f (~¥%.2f/hr)", session.currentCostEstimate, session.estimatedCostPerHour))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRow(title: String, value: String, copyable: Bool) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
            if copyable && value != "—" {
                Button {
                    UIPasteboard.general.string = value
                    flashCopied()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    guard let url = session.shadowsocks.shadowrocketURL else { return }
                    if UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    } else {
                        UIPasteboard.general.string = session.shadowsocks.uriString
                        flashCopied()
                    }
                } label: {
                    Label("Shadowrocket", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showQRCode = true
                } label: {
                    Label("QR Code", systemImage: "qrcode")
                        .font(.subheadline.bold())
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.bordered)
            }

            Button {
                UIPasteboard.general.string = session.shadowsocks.uriString
                flashCopied()
            } label: {
                Label(copiedNotice ? "Copied!" : "Copy URI Link", systemImage: copiedNotice ? "checkmark" : "link")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }
        }
    }

    private var footerControlsSection: some View {
        HStack(spacing: 12) {
            if session.status == .ready {
                Menu {
                    Button("+30 Minutes") {
                        Task { await manager.extendSession(minutes: 30) }
                    }
                    Button("+60 Minutes") {
                        Task { await manager.extendSession(minutes: 60) }
                    }
                } label: {
                    Label("Extend", systemImage: "plus.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                showStopConfirmation = true
            } label: {
                Label("Stop & Clean Up", systemImage: "xmark.circle")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func flashCopied() {
        copiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedNotice = false
        }
    }
}
