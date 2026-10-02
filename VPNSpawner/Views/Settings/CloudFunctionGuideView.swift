import SwiftUI

/// One-time setup for "Runs from: Cloud function": what gets created, permissions, cost.
struct CloudFunctionGuideView: View {
    let functionName: String

    private let rolePermissions = [
        "cvm:RunInstances, cvm:TerminateInstances (tag ManagedBy=VPNSpawner only)",
        "cvm:Describe* for zones, images, instances, prices",
        "cvm:Import/Delete/DescribeInstancesActionTimer (self-destruct timer)",
        "cvm:CreateSecurityGroup(+Policy), DeleteSecurityGroup (tagged only)",
        "vpc:Describe*Ex, tag:TagResources, finance:trade (pay-as-you-go orders)",
    ]

    var body: some View {
        List {
            Section {
                Text("A small function in your Tencent account runs launch, allowlist and cleanup on Tencent's side. The app only asks it to act.")
            }

            Section("What gets created") {
                step(1, "CAM role **SCF_VPNSpawner**", "Trusted by the SCF service (scf.qcloud.com), with the permissions below.")
                step(2, "Function **\(functionName)**", "Python 3.10 event function in the region you launch in. 128 MB, 180 s timeout, execution role SCF_VPNSpawner. Code: this repo's controller/ folder.")
                step(3, "Invoke permission for this app's key", "Add scf:InvokeFunction on that one function to the vpn-spawner policy.")
                step(4, "Switch this app to Cloud function", "Settings → Runs from.")
            }

            Section {
                ForEach(rolePermissions, id: \.self) { line in
                    Text(line).font(.caption.monospaced())
                }
            } header: {
                Text("Role permissions")
            } footer: {
                Text("Same least-privilege policy as the vpn-spawner key. Deleting is limited to resources the app tagged.")
            }

            Section {
                LabeledContent("Per session", value: "under ¥0.01")
                LabeledContent("Compute", value: "¥0.00011108 / GB-s")
                LabeledContent("Calls", value: "¥0.0133 / 10,000")
                LabeledContent("Outbound traffic", value: "¥0.80 / GB")
            } header: {
                Text("Cost")
            } footer: {
                Text("Tencent SCF pay-as-you-go prices, mainland China. Idle costs nothing. Servers themselves are billed separately.")
            }

            Section("Tencent docs") {
                Link("Cloud Function (SCF) documentation", destination: URL(string: "https://cloud.tencent.com/document/product/583")!)
                Link("CAM roles", destination: URL(string: "https://cloud.tencent.com/document/product/598")!)
                Link("SCF pricing", destination: URL(string: "https://cloud.tencent.com/document/product/583/12281")!)
            }
        }
        .navigationTitle("Cloud function setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.15), in: Circle())
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
