import SwiftUI

/// What the access key must be allowed to do, in plain words, plus a vendor template.
/// Add a vendor by adding a `PermissionTemplate` to `PermissionTemplate.all` (AWS goes here).
struct PermissionTemplate: Identifiable {
    let id: String
    let vendor: String
    let consoleURL: URL
    let steps: [String]
    let policyJSON: String
    /// Extra statement for "Runs from: Cloud function".
    let cloudFunctionJSON: String

    static let all: [PermissionTemplate] = [.tencent, .aws]

    /// AWS always runs through its controller Lambda, so the app's key only needs to invoke it;
    /// the Lambda's own role (terraform/aws/vpn_spawner.tf) holds the EC2 permissions.
    static let aws = PermissionTemplate(
        id: "aws",
        vendor: "AWS",
        consoleURL: URL(string: "https://console.aws.amazon.com/iam/home#/users")!,
        steps: [
            "Deploy the vpn-spawner-controller Lambda (terraform/aws/vpn_spawner.tf does this and the steps below).",
            "IAM → Users → Create user vpn-spawner-app, no console access.",
            "Add permissions → Create inline policy → JSON → paste the template below (put in your account ID).",
            "Security credentials → Create access key → Application running outside AWS.",
            "Back here: in AWS, tap Paste credentials and paste the key file's contents.",
        ],
        policyJSON: """
        {
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Action": "lambda:InvokeFunction",
            "Resource": "arn:aws:lambda:ca-central-1:<YOUR_ACCOUNT_ID>:function:vpn-spawner-controller"
          }]
        }
        """,
        cloudFunctionJSON: ""
    )

    static let tencent = PermissionTemplate(
        id: "tencent",
        vendor: "Tencent Cloud",
        consoleURL: URL(string: "https://console.cloud.tencent.com/cam")!,
        steps: [
            "Open Tencent Cloud console → Access Management (CAM).",
            "Users → Create user → Custom → programmatic access only, no console login. Name it vpn-spawner.",
            "Policies → Create custom policy → Create by policy syntax → paste the template below → save as vpn-spawner.",
            "Attach the policy to the vpn-spawner user.",
            "Create an API key for that user and copy SecretId and SecretKey.",
            "Back here: tap Paste credentials and paste them in one go.",
        ],
        // Mirrors docs/permissions/cam-policy.json.
        policyJSON: """
        {
          "version": "2.0",
          "statement": [
            {
              "effect": "allow",
              "action": [
                "cvm:DescribeZones", "cvm:DescribeImages", "cvm:DescribeInstances",
                "cvm:DescribeInstancesStatus", "cvm:DescribeInstanceTypeConfigs",
                "cvm:DescribeZoneInstanceConfigInfos", "cvm:RunInstances",
                "cvm:DeleteInstancesActionTimer", "cvm:ImportInstancesActionTimer",
                "cvm:DescribeInstancesActionTimer",
                "vpc:DescribeVpcEx", "vpc:DescribeSubnetEx",
                "cvm:DescribeSecurityGroups", "cvm:DescribeSecurityGroupPolicies",
                "cvm:DescribeSecurityGroupPolicys", "cvm:CreateSecurityGroup",
                "cvm:CreateSecurityGroupPolicy",
                "vpc:DescribeSecurityGroups", "vpc:DescribeSecurityGroupPolicies",
                "vpc:CreateSecurityGroup", "vpc:CreateSecurityGroupPolicies",
                "tag:AddResourceTag", "tag:TagResources", "finance:trade"
              ],
              "resource": "*"
            },
            {
              "effect": "allow",
              "action": ["cvm:TerminateInstances", "cvm:DeleteSecurityGroup"],
              "resource": "*",
              "condition": {
                "for_any_value:string_equal": {"qcs:resource_tag": ["ManagedBy&VPNSpawner"]}
              }
            }
          ]
        }
        """,
        cloudFunctionJSON: """
        {
          "effect": "allow",
          "action": ["scf:InvokeFunction"],
          "resource": ["qcs::scf:ap-guangzhou:uin/<YOUR_ACCOUNT_ID>:namespace/default/function/vpn-spawner-controller"]
        }
        """
    )
}

/// The capabilities, in human words. Shared by the Settings footer and the guide.
enum KeyCapability: CaseIterable {
    case look, launch, pay, firewall, timer, deleteOwn, cloudFunction

    var text: String {
        switch self {
        case .look: return "See regions, prices and server images"
        case .launch: return "Start pay-as-you-go servers"
        case .pay: return "Pay for what it starts (needed for any purchase)"
        case .firewall: return "Create a firewall that only lets your devices in"
        case .timer: return "Set and move each server's self-destruct timer"
        case .deleteOwn: return "Delete servers and firewalls, but only the ones this app created"
        case .cloudFunction: return "Call this app's cloud function"
        }
    }

    var symbol: String {
        switch self {
        case .look: return "eye"
        case .launch: return "play.circle"
        case .pay: return "creditcard"
        case .firewall: return "shield.lefthalf.filled"
        case .timer: return "timer"
        case .deleteOwn: return "trash"
        case .cloudFunction: return "cloud"
        }
    }

    static func needed(for mode: ExecutionMode) -> [KeyCapability] {
        mode == .controller ? allCases : allCases.filter { $0 != .cloudFunction }
    }
}

/// Compact footer list under the key fields.
struct KeyCapabilitiesFooter: View {
    let mode: ExecutionMode
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use a separate, limited key, never your main account key. To launch a server it must be allowed to:")
                .lineLimit(expanded ? nil : 2)
            if expanded {
                ForEach(KeyCapability.needed(for: mode), id: \.self) { capability in
                    Label {
                        Text(capability.text)
                    } icon: {
                        Image(systemName: capability.symbol)
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                    }
                }
                Text("Nothing else: it can't touch other servers, storage or billing settings. Stored only in this iPhone's Keychain.")
            }
            Button(expanded ? "Less" : "More") {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
        }
    }
}

/// Pushed guide: why a limited key, how to create it, and the exact policy to paste.
struct KeyPermissionsGuideView: View {
    let mode: ExecutionMode
    @State private var vendorID: String

    init(mode: ExecutionMode, initialVendor: String = PermissionTemplate.all[0].id) {
        self.mode = mode
        _vendorID = State(initialValue: initialVendor)
    }
    @State private var toast: String?

    private var template: PermissionTemplate {
        PermissionTemplate.all.first { $0.id == vendorID } ?? .tencent
    }

    var body: some View {
        List {
            if PermissionTemplate.all.count > 1 {
                Section {
                    Picker("Cloud", selection: $vendorID) {
                        ForEach(PermissionTemplate.all) { Text($0.vendor).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                Text("If this phone or the app were ever compromised, a limited key can only start and delete VPN servers. Your main key could empty your account or delete everything in it.")
                    .font(.subheadline)
            } header: {
                Text("Why a separate key")
            }

            Section {
                ForEach(KeyCapability.needed(for: mode), id: \.self) { capability in
                    Label(capability.text, systemImage: capability.symbol)
                }
            } header: {
                Text("What it must be allowed to do")
            }

            Section {
                ForEach(Array(template.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.footnote.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(.tint.opacity(0.15), in: Circle())
                            .foregroundStyle(.tint)
                        Text(step).font(.subheadline)
                    }
                }
                Link("Open \(template.vendor) console", destination: template.consoleURL)
            } header: {
                Text("Create it")
            }

            policySection("Policy template", template.policyJSON,
                          footer: "Deleting is limited to resources tagged ManagedBy=VPNSpawner, which this app adds to everything it creates.")
            if mode == .controller && !template.cloudFunctionJSON.isEmpty {
                policySection("Add for cloud function mode", template.cloudFunctionJSON,
                              footer: "Add this statement to the policy's list. Replace <YOUR_ACCOUNT_ID> with your account ID (top-right of the console).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Key permissions")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
    }

    private func policySection(_ title: String, _ json: String, footer: String) -> some View {
        Section {
            ScrollView(.horizontal) {
                Text(json)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
            Button {
                UIPasteboard.general.string = json
                Haptics.success()
                toast = "Copied \(title.lowercased())"
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}
