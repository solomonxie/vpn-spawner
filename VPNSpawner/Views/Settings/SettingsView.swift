import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: SessionManager
    @State private var config = CloudCredentialConfig()
    @State private var secretKey = ""
    @State private var showSecretKey = false
    @State private var pasteMode = false
    @State private var pasteBuffer = ""
    @State private var test: (ok: Bool, text: String)?
    @State private var isTesting = false
    @State private var loaded = false
    @State private var editingFunctionName = false
    @State private var accountVendor = LaunchPreferences.load().effectiveVendor

    var body: some View {
        Form {
            modeSection
            switch accountVendor {
            case .tencent:
                credentialsSection
            case .aws:
                AWSCredentialsSection(vendor: $accountVendor)
            }
            activitySection
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
        .onChange(of: config) { old, new in
            if loaded && old.executionMode != new.executionMode {
                UserDefaults.standard.set(true, forKey: CloudCredentialConfig.modeChosenKey)
            }
            persist()
        }
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
            VendorPicker(selection: $accountVendor)
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
            // Mirrors the AWS block: the function this key invokes sits with the key.
            if config.executionMode == .controller {
                functionRow
            }
            Button {
                pasteBuffer = ""
                pasteMode.toggle()
            } label: {
                Label(pasteMode ? "Back to fields" : "Paste credentials",
                      systemImage: pasteMode ? "character.cursor.ibeam" : "doc.on.clipboard")
            }
            testRow
            NavigationLink {
                KeyPermissionsGuideView(mode: config.executionMode)
            } label: {
                Label("Permissions this key needs", systemImage: "key.viewfinder")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let test {
                    Text(test.text).foregroundStyle(test.ok ? Color.secondary : Color.red)
                }
                if !config.secretId.isEmpty && !config.secretId.hasPrefix("AKID") {
                    Text("Tencent SecretIds usually start with AKID.")
                        .foregroundStyle(.orange)
                }
                KeyCapabilitiesFooter(mode: config.executionMode)
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
            .padding(.vertical, 4)

            if config.executionMode == .controller {
                NavigationLink {
                    CloudFunctionGuideView(functionName: config.controllerFunctionName)
                } label: {
                    Label("How to set it up, permissions & cost", systemImage: "book")
                }
            }
        } header: {
            Text("Runs from")
        } footer: {
            // Footer text, not rows, so the comparison doesn't read as tappable options.
            RunsFromComparison(selected: config.executionMode)
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
                    Text("Function in your Tencent account (\(IdleView.regionName(FunctionClient.functionRegion)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { editingFunctionName = true }
                    .font(.callout)
            }
        }
    }

    private var testRow: some View {
        Button {
            Task { await testConnection() }
        } label: {
            HStack {
                Label("Test connection", systemImage: "bolt.horizontal.circle")
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
    }

    /// All history and logs live on this one page.
    private var activitySection: some View {
        Section {
            NavigationLink {
                ActivityLogView(manager: manager)
            } label: {
                Label("Activity log", systemImage: "list.bullet.rectangle")
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

/// Picks which cloud's key form is shown; first row of the account card.
struct VendorPicker: View {
    @Binding var selection: CloudVendor

    var body: some View {
        Picker("Cloud", selection: $selection) {
            ForEach(CloudVendor.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 4)
    }
}
