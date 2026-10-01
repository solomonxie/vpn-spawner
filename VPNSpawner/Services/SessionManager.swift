import Foundation
import Combine

@MainActor
final class SessionManager: ObservableObject {
    @Published var currentSession: SessionRecord?
    @Published var history: [SessionRecord] = []
    @Published var isOperating = false
    @Published var operationStatusMessage = ""
    @Published var logs: [String] = []

    private var timer: AnyCancellable?
    private let sessionKey = "vpn.current.session"
    private let historyKey = "vpn.history.sessions"

    init() {
        loadPersistedState()
        startTimer()
    }

    private func loadPersistedState() {
        if let data = UserDefaults.standard.data(forKey: sessionKey),
           let session = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            currentSession = session
            appendLog("Restored active session \(session.id) [\(session.status.rawValue)]")
            if session.status == .ready {
                SubscriptionServer.shared.start(with: session.shadowsocks.uriString)
            }
        }
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let list = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            history = list
        }
    }

    private func persistState() {
        if let currentSession, let data = try? JSONEncoder().encode(currentSession) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func startTimer() {
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.handleTick()
            }
    }

    private func handleTick() {
        guard let session = currentSession else { return }

        if session.status == .ready && session.hasExpired {
            appendLog("Session \(session.id) has expired. Initiating automatic teardown...")
            Task {
                await terminateSession()
            }
            return
        }

        // Trigger objectWillChange to update UI countdown
        if session.status == .ready || session.status == .provisioning {
            objectWillChange.send()
        }
    }

    private func markReady(session: inout SessionRecord) {
        session.status = .ready
        currentSession = session
        persistState()
        SubscriptionServer.shared.start(with: session.shadowsocks.uriString)
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 100 { logs.removeFirst() }
    }

    func launchSession(
        region: String,
        durationMinutes: Int,
        cipher: String,
        port: Int
    ) async {
        let (config, secretKey) = CloudCredentialConfig.load()
        let isDemo = config.isDemoMode || config.secretId.isEmpty || secretKey.isEmpty

        let tag = "sess-\(Int(Date().timeIntervalSince1970) % 100000)"
        var session = SessionRecord(
            id: tag,
            status: .provisioning,
            startTime: Date(),
            durationMinutes: durationMinutes,
            region: region,
            shadowsocks: ShadowsocksConfig(
                host: "",
                port: port,
                password: ShadowsocksConfig.generatePassword(),
                method: cipher,
                tag: "Tencent-\(region)"
            ),
            isDemo: isDemo
        )
        currentSession = session
        persistState()

        isOperating = true
        operationStatusMessage = "Requesting cloud node in \(region)..."
        appendLog("Initiating session \(tag) in \(region) (mode: \(isDemo ? "Demo" : config.executionMode.rawValue))")

        if isDemo {
            await simulateProvisioning(session: session)
            return
        }

        let credential = CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)

        do {
            operationStatusMessage = "Detecting your public IP..."
            let myIP = try await PublicIPService.current()
            appendLog("Node will only accept traffic from \(myIP)")

            switch config.executionMode {
            case .direct:
                operationStatusMessage = "Creating firewall for \(myIP)..."
                let sgId = try await FirewallClient.create(
                    sessionTag: tag,
                    allowIPs: [myIP],
                    region: region,
                    credential: credential
                )
                session.securityGroupId = sgId
                session.allowedIPs = [myIP]
                currentSession = session
                persistState()
                appendLog("Security group created: \(sgId)")

                operationStatusMessage = "Launching CVM instance with Shadowsocks..."
                let instanceId: String
                do {
                    instanceId = try await ComputeClient.launchInstance(
                        region: region,
                        shadowsocks: session.shadowsocks,
                        sessionTag: tag,
                        securityGroupId: sgId,
                        credential: credential
                    )
                } catch {
                    _ = await FirewallClient.delete(securityGroupId: sgId, region: region, credential: credential, attempts: 1)
                    throw error
                }
                session.instanceId = instanceId
                currentSession = session
                persistState()
                appendLog("CVM instance created: \(instanceId). Waiting for public IP & bootstrap...")

                await pollDirectInstance(instanceId: instanceId, region: region, credential: credential)

            case .controller:
                operationStatusMessage = "Invoking SCF controller \(config.controllerFunctionName)..."
                let result = try await FunctionClient.invoke(
                    functionName: config.controllerFunctionName,
                    region: region,
                    action: "launch",
                    session: session,
                    extra: ["allowIps": [myIP]],
                    credential: credential
                )
                if !result.success {
                    throw CloudAPIError.badResponse(result.message ?? "Controller launch failed")
                }
                if let instanceId = result.instanceId {
                    session.instanceId = instanceId
                }
                session.securityGroupId = result.securityGroupId
                session.allowedIPs = result.allowedIps ?? [myIP]
                currentSession = session
                persistState()
                if let ip = result.publicIP {
                    session.publicIP = ip
                    session.shadowsocks.host = ip
                    markReady(session: &session)
                    appendLog("Controller returned node \(session.instanceId ?? "") with IP \(ip)")
                } else if let instanceId = session.instanceId {
                    await pollDirectInstance(instanceId: instanceId, region: region, credential: credential)
                }
            }
        } catch {
            session.status = .failed
            session.errorMessage = error.localizedDescription
            currentSession = session
            persistState()
            appendLog("Launch failed: \(error.localizedDescription)")
        }

        isOperating = false
        operationStatusMessage = ""
    }

    private func pollDirectInstance(
        instanceId: String,
        region: String,
        credential: CloudSigner.Credential
    ) async {
        for attempt in 1...25 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            operationStatusMessage = "Checking node readiness (attempt \(attempt))..."
            do {
                let info = try await ComputeClient.describeInstance(
                    instanceId: instanceId,
                    region: region,
                    credential: credential
                )
                if let ip = info.publicIP, !ip.isEmpty, info.state == "RUNNING" {
                    guard var session = currentSession else { return }
                    session.publicIP = ip
                    session.shadowsocks.host = ip
                    markReady(session: &session)
                    appendLog("Node is RUNNING. Assigned public IP: \(ip)")
                    return
                }
            } catch {
                appendLog("Poll error: \(error.localizedDescription)")
            }
        }

        if var session = currentSession, session.publicIP == nil {
            session.status = .failed
            session.errorMessage = "Timed out waiting for public IP"
            currentSession = session
            persistState()
            appendLog("Timed out waiting for instance public IP")
        }
    }

    private func simulateProvisioning(session: SessionRecord) async {
        var s = session
        operationStatusMessage = "Allocating demo CVM in \(s.region)..."
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        s.instanceId = "ins-demo\(Int.random(in: 1000...9999))"
        currentSession = s
        persistState()
        appendLog("Demo instance created: \(s.instanceId ?? "")")

        operationStatusMessage = "Configuring Shadowsocks server..."
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let simulatedIP = "119.29.\(Int.random(in: 10...240)).\(Int.random(in: 2...254))"
        s.publicIP = simulatedIP
        s.shadowsocks.host = simulatedIP
        markReady(session: &s)
        appendLog("Demo node ready at \(simulatedIP):\(s.shadowsocks.port)")

        isOperating = false
        operationStatusMessage = ""
    }

    func extendSession(minutes: Int = 30) async {
        guard var session = currentSession, session.status == .ready else { return }
        session.expiryTime = session.expiryTime.addingTimeInterval(TimeInterval(minutes * 60))
        currentSession = session
        persistState()
        appendLog("Extended session \(session.id) by \(minutes) minutes. New expiry: \(session.expiryTime)")

        let (config, secretKey) = CloudCredentialConfig.load()
        if !session.isDemo && config.executionMode == .controller && !config.controllerFunctionName.isEmpty {
            let credential = CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)
            _ = try? await FunctionClient.invoke(
                functionName: config.controllerFunctionName,
                region: session.region,
                action: "extend",
                session: session,
                credential: credential
            )
        }
    }

    func allowCurrentIP() async {
        guard var session = currentSession, session.status == .ready, !session.isDemo else { return }
        let (config, secretKey) = CloudCredentialConfig.load()
        let credential = CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)

        isOperating = true
        operationStatusMessage = "Adding current IP to allowlist..."
        defer {
            isOperating = false
            operationStatusMessage = ""
        }

        do {
            let ip = try await PublicIPService.current()
            let allowed: [String]
            if config.executionMode == .controller {
                let result = try await FunctionClient.invoke(
                    functionName: config.controllerFunctionName,
                    region: session.region,
                    action: "allow_ip",
                    session: session,
                    extra: ["ip": ip],
                    credential: credential
                )
                guard result.success, let ips = result.allowedIps else {
                    throw CloudAPIError.badResponse(result.message ?? "Controller allow_ip failed")
                }
                session.securityGroupId = result.securityGroupId ?? session.securityGroupId
                allowed = ips
            } else {
                guard let sgId = session.securityGroupId else {
                    throw CloudAPIError.badResponse("Session has no security group")
                }
                allowed = try await FirewallClient.allow(ip: ip, securityGroupId: sgId, region: session.region, credential: credential)
            }
            session.allowedIPs = allowed
            currentSession = session
            persistState()
            appendLog("Allowed \(ip). Allowlist: \(allowed.joined(separator: ", "))")
        } catch {
            appendLog("Allow current IP failed: \(error.localizedDescription)")
        }
    }

    func terminateSession() async {
        guard var session = currentSession else { return }
        session.status = .stopping
        currentSession = session
        persistState()

        isOperating = true
        operationStatusMessage = "Tearing down cloud resources..."
        appendLog("Terminating session \(session.id) and destroying instance \(session.instanceId ?? "")")

        let (config, secretKey) = CloudCredentialConfig.load()

        if !session.isDemo {
            let credential = CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)
            if let instanceId = session.instanceId {
                try? await ComputeClient.terminateInstance(
                    instanceId: instanceId,
                    region: session.region,
                    credential: credential
                )
            }
            if config.executionMode == .controller && !config.controllerFunctionName.isEmpty {
                _ = try? await FunctionClient.invoke(
                    functionName: config.controllerFunctionName,
                    region: session.region,
                    action: "terminate",
                    session: session,
                    credential: credential
                )
            }
            if let sgId = session.securityGroupId {
                operationStatusMessage = "Releasing firewall \(sgId)..."
                let deleted = await FirewallClient.delete(securityGroupId: sgId, region: session.region, credential: credential)
                appendLog(deleted ? "Security group \(sgId) deleted" : "Security group \(sgId) still in use; will be swept on next launch")
            }
        } else {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        session.status = .terminated
        history.insert(session, at: 0)
        if history.count > 20 { history.removeLast() }
        currentSession = nil
        SubscriptionServer.shared.stop()
        persistState()
        appendLog("Session \(session.id) successfully terminated. Resources released.")

        isOperating = false
        operationStatusMessage = ""
    }

    func reconcileSession() async {
        guard let session = currentSession, let instanceId = session.instanceId, !session.isDemo else { return }
        let (config, secretKey) = CloudCredentialConfig.load()
        guard !config.secretId.isEmpty, !secretKey.isEmpty else { return }
        let credential = CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey)

        appendLog("Reconciling session \(session.id) with Tencent Cloud...")
        do {
            let info = try await ComputeClient.describeInstance(
                instanceId: instanceId,
                region: session.region,
                credential: credential
            )
            var updated = session
            if info.state == "RUNNING" {
                if let ip = info.publicIP {
                    updated.publicIP = ip
                    updated.shadowsocks.host = ip
                    updated.status = .ready
                    SubscriptionServer.shared.start(with: updated.shadowsocks.uriString)
                }
            } else if info.state == "TERMINATING" || info.state == "SHUTDOWN" {
                updated.status = .terminated
                currentSession = nil
                SubscriptionServer.shared.stop()
                history.insert(updated, at: 0)
                persistState()
                appendLog("Remote instance \(instanceId) is already \(info.state). Session closed.")
                return
            }
            currentSession = updated
            persistState()
            appendLog("Reconciliation complete. Status: \(info.state)")
        } catch {
            appendLog("Reconciliation error: \(error.localizedDescription)")
        }
    }
}
