import SwiftUI

struct SettingsView: View {
    @State private var config = CloudCredentialConfig()
    @State private var secretKey = ""
    @State private var showSecretKey = false
    @State private var testStatus = ""
    @State private var isTesting = false
    @State private var showSaveSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Demo / Sandbox Mode", isOn: $config.isDemoMode)
                        .tint(.purple)
                    if config.isDemoMode {
                        Text("Simulates the complete CVM node lifecycle, timer countdown, QR codes, and teardown without requiring cloud credentials or incurring billing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Environment")
                }

                Section {
                    TextField("SecretId", text: $config.secretId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        if showSecretKey {
                            TextField("SecretKey", text: $secretKey)
                        } else {
                            SecureField("SecretKey", text: $secretKey)
                        }
                        Button {
                            showSecretKey.toggle()
                        } label: {
                            Image(systemName: showSecretKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } header: {
                    Text("Tencent Cloud Credentials")
                } footer: {
                    Text("Stored securely in the iOS Keychain. Never logged or transmitted outside Tencent Cloud API requests.")
                }

                Section {
                    Picker("Execution Mode", selection: $config.executionMode) {
                        ForEach(ExecutionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    if config.executionMode == .controller {
                        TextField("SCF Controller Name", text: $config.controllerFunctionName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Orchestration")
                } footer: {
                    Text(config.executionMode == .direct
                         ? "Direct Mode calls Tencent CVM APIs directly from your device using your CAM keys."
                         : "Controller Mode invokes your user-owned SCF function to orchestrate provisioning and cleanup independent of the phone.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test Cloud Connection")
                            if isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting || (config.secretId.isEmpty && !config.isDemoMode))

                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundStyle(testStatus.contains("Success") ? .green : .red)
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Required CAM Permissions")
                            .font(.subheadline.bold())
                        Text("• cvm:RunInstances\n• cvm:DescribeInstances\n• cvm:TerminateInstances\n• scf:InvokeFunction (if using SCF Controller)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Security & IAM Guidance")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveSettings()
                    }
                }
            }
            .onAppear {
                let loaded = CloudCredentialConfig.load()
                config = loaded.config
                secretKey = loaded.secretKey
            }
            .alert("Settings Saved", isPresented: $showSaveSuccess) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func saveSettings() {
        config.save(secretKey: secretKey)
        showSaveSuccess = true
    }

    private func testConnection() {
        if config.isDemoMode {
            testStatus = "Success (Demo Mode simulation active)"
            return
        }

        guard !config.secretId.isEmpty, !secretKey.isEmpty else {
            testStatus = "Please enter both SecretId and SecretKey"
            return
        }

        isTesting = true
        testStatus = "Contacting Tencent Cloud..."

        let cred = CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)
        Task {
            do {
                _ = try await CloudAPIClient.request(
                    host: "cvm.tencentcloudapi.com",
                    service: "cvm",
                    action: "DescribeInstances",
                    version: "2017-03-12",
                    region: config.region,
                    payload: ["Limit": 1],
                    credential: cred
                )
                testStatus = "Success: Tencent Cloud API connected."
            } catch {
                testStatus = "Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}
