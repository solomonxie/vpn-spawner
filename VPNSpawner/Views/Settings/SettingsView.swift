import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: SessionManager
    @State private var config = CloudCredentialConfig()
    @State private var secretKey = ""
    @State private var showSecretKey = false
    @State private var pasteMode = false
    @State private var pasteBuffer = ""
    @State private var showCredentialInfo = false
    @State private var test: (ok: Bool, text: String)?
    @State private var isTesting = false
    @State private var loaded = false
    @State private var editingFunctionName = false

    var body: some View {
        Form {
            modeSection
            credentialsSection
            testSection
            HistorySection(manager: manager)
            demoSection
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onAppear {
            let stored = CloudCredentialConfig.load()
            config = stored.config
            secretKey = stored.secretKey
            loaded = true
        }
        .onChange(of: config) { _, _ in persist() }
        .onChange(of: secretKey) { _, _ in persist() }
    }

    private func persist() {
        guard loaded else { return }
        config.save(secretKey: secretKey)
        test = nil
    }

    // MARK: Credentials

    private var credentialsSection: some View {
        Section {
            if pasteMode {
                TextEditor(text: $pasteBuffer)
                    .font(.callout.monospaced())
                    .frame(minHeight: 90)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(alignment: .topLeading) {
                        if pasteBuffer.isEmpty {
                            Text("secret_id: AKID…\nsecret_key: …")
                                .font(.callout.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: pasteBuffer) { old, new in
                        applyPaste(new, wasPaste: new.count - old.count > 1)
                    }
            } else {
                TextField("SecretId", text: $config.secretId)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Group {
                        if showSecretKey {
                            TextField("SecretKey", text: $secretKey)
                        } else {
                            SecureField("SecretKey", text: $secretKey)
                        }
                    }
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Button {
                        showSecretKey.toggle()
                    } label: {
                        Image(systemName: showSecretKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showSecretKey ? "Hide SecretKey" : "Show SecretKey")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Tencent Cloud")
                Button {
                    showCredentialInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("About these keys")
                .popover(isPresented: $showCredentialInfo) {
                    Text("Use the vpn-spawner sub-user's key, not your root key. It can only create and delete servers this app tagged.\n\nStored in this iPhone's Keychain and sent only to Tencent Cloud's API.")
                        .font(.callout)
                        .padding()
                        .frame(idealWidth: 300)
                        .presentationCompactAdaptation(.popover)
                }
                Spacer()
                Button(pasteMode ? "Back to fields" : "Paste both") {
                    pasteBuffer = ""
                    pasteMode.toggle()
                }
                .font(.caption.weight(.medium))
                .textCase(nil)
            }
        } footer: {
            if !config.secretId.isEmpty && !config.secretId.hasPrefix("AKID") {
                Text("Tencent SecretIds usually start with AKID.")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Accepts `key: value` / `key=value` lines in any common spelling; fills only what it found.
    private func applyPaste(_ text: String, wasPaste: Bool) {
        var foundId: String?
        var foundKey: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.replacingOccurrences(of: "export ", with: "")
            guard let sep = raw.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let name = raw[..<sep].lowercased().filter { $0.isLetter }
            let value = raw[raw.index(after: sep)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }
            if name.hasSuffix("secretid") { foundId = value }
            if name.hasSuffix("secretkey") { foundKey = value }
        }
        if let foundId { config.secretId = foundId }
        if let foundKey { secretKey = foundKey }
        if wasPaste && (foundId != nil || foundKey != nil) {
            pasteBuffer = ""
            pasteMode = false
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            Picker("Runs from", selection: $config.executionMode) {
                Text("This iPhone").tag(ExecutionMode.direct)
                Text("Cloud function").tag(ExecutionMode.controller)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if config.executionMode == .direct {
                tradeoff(.pro, "Nothing to set up. Free.")
                tradeoff(.pro, "Works right now with the key below.")
                tradeoff(.con, "Each step runs from this phone. If closed, it resumes when reopened; Tencent's timer still deletes the server on time.")
            } else {
                tradeoff(.pro, "Launch, allowlist and cleanup run inside Tencent, so a flaky phone connection can't interrupt them.")
                tradeoff(.con, "One-time setup in your Tencent account (role + function).")
                tradeoff(.con, "Costs a little: under ¥0.01 per session.")
                functionRow
                NavigationLink {
                    CloudFunctionGuideView(functionName: config.controllerFunctionName)
                } label: {
                    Label("How to set it up, permissions & cost", systemImage: "book")
                }
            }
        } header: {
            Text("Runs from")
        }
    }

    private enum Tradeoff { case pro, con }

    private func tradeoff(_ kind: Tradeoff, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: kind == .pro ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(kind == .pro ? .green : .orange)
        }
    }

    /// Fixed default name; editable only on purpose.
    @ViewBuilder
    private var functionRow: some View {
        if editingFunctionName {
            HStack {
                TextField("Function name", text: $config.controllerFunctionName)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { editingFunctionName = false }
                Button("Default") {
                    config.controllerFunctionName = CloudCredentialConfig.defaultFunctionName
                    editingFunctionName = false
                }
                .font(.caption)
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.controllerFunctionName)
                        .font(.callout.monospaced())
                    Text("Function in your account, in the launch region")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { editingFunctionName = true }
                    .font(.callout)
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if isTesting {
                        ProgressView()
                    } else if let test {
                        Image(systemName: test.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(test.ok ? .green : .red)
                    }
                }
            }
            .disabled(isTesting || (config.secretId.isEmpty && !config.isDemoMode))
        } footer: {
            if let test {
                Text(test.text).foregroundStyle(test.ok ? Color.secondary : Color.red)
            }
        }
    }

    private func testConnection() async {
        if config.isDemoMode {
            test = (true, "Demo mode: nothing to test.")
            return
        }
        guard !config.secretId.isEmpty, !secretKey.isEmpty else {
            test = (false, "Enter both SecretId and SecretKey.")
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            _ = try await CloudAPIClient.request(
                host: "cvm.tencentcloudapi.com",
                service: "cvm",
                action: "DescribeInstances",
                version: "2017-03-12",
                region: LaunchPreferences.load().region,
                payload: ["Limit": 1],
                credential: CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)
            )
            test = (true, "Connected to Tencent Cloud.")
        } catch {
            test = (false, error.localizedDescription)
        }
    }

    // MARK: Demo

    private var demoSection: some View {
        Section {
            Toggle("Demo mode", isOn: $config.isDemoMode)
                .tint(.purple)
        } footer: {
            Text("Simulates a session with no cloud calls and no cost.")
        }
    }
}
