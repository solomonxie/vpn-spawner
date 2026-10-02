import SwiftUI

/// AWS invoke-only key: the app only calls the controller Lambda, which does all EC2 work.
struct AWSCredentialsSection: View {
    @State private var config = AWSCredentialConfig()
    @State private var secret = ""
    @State private var showSecret = false
    @State private var pasteMode = false
    @State private var pasteBuffer = ""
    @State private var loaded = false
    @State private var test: (ok: Bool, text: String)?
    @State private var isTesting = false

    var body: some View {
        Section {
            if pasteMode {
                TextEditor(text: $pasteBuffer)
                    .font(.callout.monospaced())
                    .frame(minHeight: 90)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: pasteBuffer) { old, new in
                        applyPaste(new, wasPaste: new.count - old.count > 1)
                    }
            } else {
                TextField("Access key ID", text: $config.accessKeyId)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Group {
                        if showSecret {
                            TextField("Secret access key", text: $secret)
                        } else {
                            SecureField("Secret access key", text: $secret)
                        }
                    }
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Button {
                        showSecret.toggle()
                    } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showSecret ? "Hide secret" : "Show secret")
                }
            }
            LabeledContent("Function") {
                Text("\(config.functionName) · \(CloudVendor.regionName(config.functionRegion))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Text("Test AWS connection")
                    Spacer()
                    if isTesting {
                        ProgressView()
                    } else if let test {
                        Image(systemName: test.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(test.ok ? .green : .red)
                    }
                }
            }
            .disabled(isTesting || !config.isComplete || secret.isEmpty)
            NavigationLink {
                KeyPermissionsGuideView(mode: .controller, initialVendor: "aws")
            } label: {
                Text("Permissions this key needs")
            }
        } header: {
            HStack {
                Text("Access key")
                Spacer()
                Button(pasteMode ? "Back to fields" : "Paste credentials") {
                    pasteBuffer = ""
                    pasteMode.toggle()
                }
                .font(.caption.weight(.medium))
                .textCase(nil)
            }
        } footer: {
            if let test {
                Text(test.text).foregroundStyle(test.ok ? Color.secondary : Color.red)
            } else {
                Text("Only needs permission to call the function. Kept in Keychain.")
            }
        }
        .onAppear {
            let stored = AWSCredentialConfig.load()
            config = stored.config
            secret = stored.secret
            loaded = true
        }
        .onChange(of: config) { _, _ in persist() }
        .onChange(of: secret) { _, _ in persist() }
    }

    private func persist() {
        guard loaded else { return }
        config.save(secret: secret)
        test = nil
    }

    /// Accepts the terraform key file (`access_key_id: …`, `secret_access_key: …`, `region: …`, `function: …`)
    /// or AWS env/credentials spellings.
    private func applyPaste(_ text: String, wasPaste: Bool) {
        var found = false
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.replacingOccurrences(of: "export ", with: "")
            guard let sep = raw.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let name = raw[..<sep].lowercased().filter { $0.isLetter }
            let value = raw[raw.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }
            switch name {
            case "accesskeyid", "awsaccesskeyid": config.accessKeyId = value; found = true
            case "secretaccesskey", "awssecretaccesskey": secret = value; found = true
            case "region": config.functionRegion = value
            case "function": config.functionName = value
            default: break
            }
        }
        if wasPaste && found {
            pasteBuffer = ""
            pasteMode = false
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let data = try await LambdaClient.invoke(
                payload: ["vendor": "aws", "action": "find", "region": CloudVendor.aws.defaultRegion, "sessionId": "settings-test"],
                config: config, secret: secret
            )
            let ok = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["success"] as? Bool == true
            test = ok ? (true, "Connected to the AWS controller.") : (false, "The function answered with an error.")
        } catch {
            test = (false, error.localizedDescription)
        }
    }
}
