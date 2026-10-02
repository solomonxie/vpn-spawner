import Foundation
import Combine
import UIKit

/// Session lifecycle. Every step is persisted before and after its cloud call, and
/// `resume()` continues from whatever state was saved, so launch and teardown survive
/// the app being backgrounded, killed, or restarted. A Tencent-side terminate timer
/// (set at RunInstances, moved when ready/extended) bounds billing even if the app never returns.
@MainActor
final class SessionManager: ObservableObject {
    @Published var currentSession: SessionRecord?
    @Published var history: [SessionRecord] = []
    @Published var isOperating = false
    @Published var operationStatusMessage = ""
    @Published var logs: [String] = []
    @Published var launchError: String?
    /// Steps of the current launch or teardown, shown live on the session card.
    @Published var activityLog: [String] = []

    private var timer: AnyCancellable?
    private var provisioning: Task<Void, Never>?
    private var terminating = false
    private let sessionKey = "vpn.current.session"
    private let historyKey = "vpn.history.sessions"

    /// Cloud timer at launch covers provisioning too; it's moved to ready + planned once ready.
    private static let provisioningBuffer: TimeInterval = 10 * 60
    private static let bootTimeout: TimeInterval = 4 * 60
    private static let installTimeout: TimeInterval = 6 * 60

    init() {
        loadPersistedState()
        startTimer()
        Task { await resume() }
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        if let data = UserDefaults.standard.data(forKey: sessionKey),
           var session = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            // Sessions saved before readyTime existed counted down from launch.
            if session.status == .ready && session.readyTime == nil {
                session.readyTime = session.startTime
            }
            currentSession = session
            appendLog("Restored session \(session.id) [\(session.status.rawValue)]")
            if session.status == .ready {
                SubscriptionServer.shared.start(with: session.shadowsocks.uriString)
            }
        }
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let list = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            history = list
        }
    }

    private func save(_ session: SessionRecord?) {
        currentSession = session
        persistState()
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
            .sink { [weak self] _ in self?.handleTick() }
    }

    private func handleTick() {
        guard let session = currentSession else { return }
        if session.status == .ready && session.hasExpired && !terminating {
            appendLog("Session \(session.id) expired. Tearing down...")
            Task { await terminateSession() }
            return
        }
        if [.ready, .provisioning, .stopping].contains(session.status) {
            objectWillChange.send()
        }
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logs.append(line)
        if logs.count > 100 { logs.removeFirst() }
        activityLog.append(line)
        if activityLog.count > 40 { activityLog.removeFirst() }
    }

    private func credentials() -> (CloudCredentialConfig, CloudSigner.Credential) {
        let (config, secretKey) = CloudCredentialConfig.load()
        return (config, CloudSigner.Credential(secretId: config.secretId, secretKey: secretKey))
    }

    /// Asks iOS for extra time so an in-flight step can finish if the app is backgrounded.
    private func withBackgroundTime(_ name: String, _ work: () async -> Void) async {
        let id = UIApplication.shared.beginBackgroundTask(withName: name)
        await work()
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }

    private func setStage(_ stage: ProvisionStage) {
        guard var session = currentSession, session.stage != stage else { return }
        session.stage = stage
        session.stageStartedAt = Date()
        save(session)
        operationStatusMessage = stage.rawValue
    }

    // MARK: - Resume

    /// Continues whatever the saved session was doing. Safe to call repeatedly.
    func resume() async {
        guard let session = currentSession, !session.isDemo, provisioning == nil, !terminating else { return }
        switch session.status {
        case .provisioning:
            appendLog("Resuming provisioning of \(session.id)")
            await runProvisioning()
        case .stopping:
            appendLog("Resuming teardown of \(session.id)")
            await terminateSession()
        case .ready:
            await reconcileSession()
            if currentSession?.hasExpired == true {
                await terminateSession()
            }
        default:
            break
        }
    }

    // MARK: - Launch

    /// UI entry point: launches with the saved/edited launch preferences.
    func launch(_ prefs: LaunchPreferences) async {
        prefs.save()
        await launchSession(
            region: prefs.region,
            durationMinutes: prefs.durationMinutes,
            cipher: "chacha20-ietf-poly1305",
            port: 8388,
            protocols: prefs.protocols.isEmpty ? VPNProtocol.defaults : prefs.protocols
        )
    }

    func launchSession(
        region: String,
        durationMinutes: Int,
        cipher: String,
        port: Int,
        protocols: Set<VPNProtocol> = VPNProtocol.defaults
    ) async {
        let (config, secretKey) = CloudCredentialConfig.load()
        launchError = nil
        if !config.isDemoMode && (config.secretId.isEmpty || secretKey.isEmpty) {
            launchError = "Add your Tencent Cloud SecretId and SecretKey in Settings first."
            appendLog("Launch blocked: no Tencent Cloud credentials configured")
            return
        }

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
            isDemo: config.isDemoMode
        )
        session.ikev2PSK = ShadowsocksConfig.generatePassword(length: 24)
        session.protocols = VPNProtocol.allCases.filter(protocols.contains)
        activityLog = []
        session.stage = .preparing
        session.stageStartedAt = Date()
        save(session)
        appendLog("Launching \(tag) in \(region) (\(session.isDemo ? "Demo" : config.executionMode.rawValue))")

        if session.isDemo {
            await simulateProvisioning()
            return
        }
        await runProvisioning()
    }

    /// Runs the provisioning state machine as a cancellable task (Stop cancels it).
    private func runProvisioning() async {
        guard provisioning == nil else { return }
        let task = Task { await withBackgroundTime("provision") { await driveProvisioning() } }
        provisioning = task
        await task.value
        provisioning = nil
    }

    /// Idempotent provisioning state machine; each branch skips work already recorded.
    private func driveProvisioning() async {
        isOperating = true
        defer {
            isOperating = false
            operationStatusMessage = ""
        }
        let (config, credential) = credentials()

        do {
            try await ensureInstance(config: config, credential: credential)
            try await waitForBoot(credential: credential)
            try await waitForServices(config: config, credential: credential)
        } catch is CancellationError {
            appendLog("Provisioning cancelled")
        } catch {
            guard !Task.isCancelled, var session = currentSession, session.status == .provisioning else { return }
            session.status = .failed
            session.errorMessage = error.localizedDescription
            save(session)
            appendLog("Launch failed: \(error.localizedDescription). Cloud timer will still terminate any created server.")
        }
    }

    private func ensureInstance(config: CloudCredentialConfig, credential: CloudSigner.Credential) async throws {
        guard var session = currentSession, session.instanceId == nil else { return }

        // The app may have died after RunInstances but before saving the ID.
        if session.securityGroupId != nil || config.executionMode == .controller {
            if let found = try await ComputeClient.findInstances(
                sessionTag: session.id, region: session.region, credential: credential
            ).first {
                try Task.checkCancellation()
                session.instanceId = found.instanceId
                save(session)
                appendLog("Recovered instance \(found.instanceId) by session tag")
                return
            }
        }

        setStage(.preparing)
        let myIP = try await PublicIPService.current()
        appendLog("Node will only accept traffic from \(myIP)")
        let terminateAt = Date().addingTimeInterval(TimeInterval((session.plannedMinutes ?? 10) * 60) + Self.provisioningBuffer)

        switch config.executionMode {
        case .direct:
            if session.securityGroupId == nil {
                let replaced = try await ComputeClient.replaceRunningNodes(region: session.region, credential: credential)
                if !replaced.isEmpty {
                    appendLog("Replaced leftover node(s): \(replaced.joined(separator: ", "))")
                }
                let sgId = try await FirewallClient.create(
                    sessionTag: session.id, allowIPs: [myIP], region: session.region, credential: credential
                )
                try Task.checkCancellation()
                session.securityGroupId = sgId
                session.allowedIPs = [myIP]
                save(session)
                appendLog("Security group created: \(sgId)")
            }
            setStage(.launching)
            do {
                let launched = try await ComputeClient.launchInstance(
                    region: session.region,
                    shadowsocks: session.shadowsocks,
                    sessionTag: session.id,
                    securityGroupId: session.securityGroupId ?? "",
                    ikev2PSK: session.ikev2PSK ?? "",
                    protocols: session.protocols ?? Array(VPNProtocol.defaults),
                    terminateAt: terminateAt,
                    credential: credential
                )
                let instanceId = launched.instanceId
                try Task.checkCancellation()
                session = currentSession ?? session
                session.instanceId = instanceId
                session.instanceType = launched.instanceType
                if let price = launched.hourlyPrice {
                    session.estimatedCostPerHour = price
                }
                save(session)
                appendLog("Type \(launched.instanceType) at ¥\(launched.hourlyPrice.map { String(format: "%.2f", $0) } ?? "?")/hr")
                appendLog("Instance \(instanceId) created; Tencent will terminate it by \(ComputeClient.timerTime(terminateAt)) at the latest")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let sgId = session.securityGroupId {
                    _ = await FirewallClient.delete(securityGroupId: sgId, region: session.region, credential: credential, attempts: 1)
                }
                throw error
            }

        case .controller:
            setStage(.launching)
            let result = try await FunctionClient.invoke(
                functionName: config.controllerFunctionName,
                region: session.region,
                action: "launch",
                session: session,
                extra: [
                    "allowIps": [myIP],
                    "ikev2Psk": session.ikev2PSK ?? "",
                    "protocols": (session.protocols ?? Array(VPNProtocol.defaults)).map(\.rawValue),
                    "expiryTimestamp": Int(terminateAt.timeIntervalSince1970),
                ],
                credential: credential
            )
            guard result.success, let instanceId = result.instanceId else {
                throw CloudAPIError.badResponse(result.message ?? "Controller launch failed")
            }
            if let replaced = result.replaced, !replaced.isEmpty {
                appendLog("Replaced leftover node(s): \(replaced.joined(separator: ", "))")
            }
            try Task.checkCancellation()
            session = currentSession ?? session
            session.instanceId = instanceId
            session.securityGroupId = result.securityGroupId
            session.allowedIPs = result.allowedIps ?? [myIP]
            session.ikev2PSK = result.ikev2Psk ?? session.ikev2PSK
            save(session)
        }
    }

    private func waitForBoot(credential: CloudSigner.Credential) async throws {
        guard let session = currentSession, session.publicIP == nil, let instanceId = session.instanceId else { return }
        setStage(.booting)
        let deadline = Date().addingTimeInterval(Self.bootTimeout)
        while Date() < deadline {
            if let info = try? await ComputeClient.instanceIfExists(
                instanceId: instanceId, region: session.region, credential: credential
            ), let ip = info.publicIP, !ip.isEmpty, info.state == "RUNNING" {
                try Task.checkCancellation()
                var updated = currentSession ?? session
                updated.publicIP = ip
                updated.shadowsocks.host = ip
                // Tunnelled traffic hairpinning back to the node arrives from its own public IP.
                if let sgId = updated.securityGroupId,
                   let allowed = try? await FirewallClient.allow(ip: ip, securityGroupId: sgId, region: updated.region, credential: credential) {
                    updated.allowedIPs = allowed
                }
                save(updated)
                appendLog("Server RUNNING at \(ip)")
                return
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw CloudAPIError.badResponse("Timed out waiting for the server to boot")
    }

    private func waitForServices(config: CloudCredentialConfig, credential: CloudSigner.Credential) async throws {
        guard let session = currentSession, let ip = session.publicIP else { return }
        setStage(.installing)
        let deadline = Date().addingTimeInterval(Self.installTimeout)
        var lastStage: String?
        while Date() < deadline {
            if let health = await NodeHealth.check(ip: ip) {
                if let stage = health.stage, stage != lastStage {
                    lastStage = stage
                    appendLog("Node: \(stage)")
                }
                if health.stage == "failed" {
                    throw CloudAPIError.badResponse("Node setup failed: \(health.error ?? "unknown error"). Clean Up and launch again.")
                }
                if health.isReady {
                    try Task.checkCancellation()
                    for (proto, reason) in health.unavailable ?? [:] {
                        appendLog("Unavailable: \(proto) (\(reason))")
                    }
                    await markReady(config: config, credential: credential)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw CloudAPIError.badResponse("Server is up but VPN services didn't start in time")
    }

    /// Countdown and cloud self-destruct both start now, when the node is actually usable.
    private func markReady(config: CloudCredentialConfig, credential: CloudSigner.Credential) async {
        guard var session = currentSession else { return }
        let now = Date()
        session.readyTime = now
        session.expiryTime = now.addingTimeInterval(TimeInterval((session.plannedMinutes ?? 10) * 60))
        session.status = .ready
        session.stage = nil
        if let ip = session.publicIP, let endpoints = await NodeHealth.endpoints(ip: ip) {
            session.endpoints = endpoints
            appendLog("Protocols ready: \(endpoints.map(\.proto.displayName).joined(separator: ", "))")
        }
        save(session)
        SubscriptionServer.shared.start(with: session.shadowsocks.uriString)
        appendLog("Node ready after \(Int(now.timeIntervalSince(session.startTime)))s; countdown started")
        await scheduleCloudTerminate(session: session, config: config, credential: credential)
    }

    private func scheduleCloudTerminate(session: SessionRecord, config: CloudCredentialConfig, credential: CloudSigner.Credential) async {
        guard let instanceId = session.instanceId else { return }
        do {
            if config.executionMode == .controller {
                _ = try await FunctionClient.invoke(
                    functionName: config.controllerFunctionName,
                    region: session.region,
                    action: "extend",
                    session: session,
                    credential: credential
                )
            } else {
                try await ComputeClient.rescheduleTerminate(
                    instanceId: instanceId, at: session.expiryTime, region: session.region, credential: credential
                )
            }
            appendLog("Cloud self-destruct set to \(ComputeClient.timerTime(session.expiryTime))")
        } catch {
            appendLog("Couldn't move cloud timer (launch timer still applies): \(error.localizedDescription)")
        }
    }

    private func simulateProvisioning() async {
        guard var s = currentSession else { return }
        isOperating = true
        setStage(.launching)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        s = currentSession ?? s
        s.instanceId = "ins-demo\(Int.random(in: 1000...9999))"
        save(s)
        setStage(.installing)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        s = currentSession ?? s
        let ip = "119.29.\(Int.random(in: 10...240)).\(Int.random(in: 2...254))"
        s.publicIP = ip
        s.shadowsocks.host = ip
        s.readyTime = Date()
        s.expiryTime = Date().addingTimeInterval(TimeInterval((s.plannedMinutes ?? 10) * 60))
        s.status = .ready
        s.stage = nil
        save(s)
        appendLog("Demo node ready at \(ip)")
        isOperating = false
        operationStatusMessage = ""
    }

    // MARK: - Extend / allowlist

    func extendSession(minutes: Int = 30) async {
        guard var session = currentSession, session.status == .ready else { return }
        session.expiryTime = session.expiryTime.addingTimeInterval(TimeInterval(minutes * 60))
        save(session)
        appendLog("Extended \(session.id) by \(minutes) min")
        guard !session.isDemo else { return }
        let (config, credential) = credentials()
        await scheduleCloudTerminate(session: session, config: config, credential: credential)
    }

    func allowCurrentIP() async {
        guard var session = currentSession, session.status == .ready, !session.isDemo else { return }
        let (config, credential) = credentials()

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
            save(session)
            appendLog("Allowed \(ip). Allowlist: \(allowed.joined(separator: ", "))")
        } catch {
            appendLog("Allow current IP failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Teardown

    /// Idempotent: re-running after a crash finishes whatever is left.
    func terminateSession() async {
        guard currentSession != nil, !terminating else { return }
        terminating = true
        if let provisioning {
            provisioning.cancel()
            await provisioning.value
        }
        guard var session = currentSession else {
            terminating = false
            return
        }
        if session.status != .stopping || session.stopStartedAt == nil {
            activityLog = []
            session.stopStartedAt = Date()
        }
        session.status = .stopping
        save(session)

        isOperating = true
        operationStatusMessage = "Tearing down cloud resources..."
        appendLog("Terminating \(session.id) (\(session.instanceId ?? "no instance"))")

        var verified = session.isDemo
        await withBackgroundTime("terminate") {
            if session.isDemo {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return
            }
            let (config, credential) = credentials()
            operationStatusMessage = "Disconnecting VPN..."
            await NativeVPNController.shared.remove()
            if NativeVPNController.anySystemVPNActive {
                appendLog("A VPN this app didn't create (Safari profile / manual) is still on. Turn it off in Settings → VPN, or teardown calls may stall.")
            } else {
                appendLog("VPN disconnected")
            }
            verified = await destroyAndVerify(&session, config: config, credential: credential)
        }

        if verified {
            session.cleanupVerified = !session.isDemo
            closeSession(session, status: .terminated, note: "verified deleted: no server or firewall left")
        } else {
            session.errorMessage = "Couldn't confirm deletion yet. Retries when you reopen the app; Tencent's delete timer is still set."
            save(session)
            appendLog("Teardown not verified; session kept in Stopping for retry")
        }
        terminating = false
        isOperating = false
        operationStatusMessage = ""
    }

    private static let verifyTimeout: TimeInterval = 150

    /// Deletes, then proves absence: instance not found by ID or session tag, and firewall deleted
    /// (Tencent refuses that while any server still uses it).
    private func destroyAndVerify(
        _ session: inout SessionRecord,
        config: CloudCredentialConfig,
        credential: CloudSigner.Credential
    ) async -> Bool {
        let region = session.region
        operationStatusMessage = "Deleting server..."
        if session.instanceId == nil,
           let found = try? await ComputeClient.findInstances(sessionTag: session.id, region: region, credential: credential).first {
            session.instanceId = found.instanceId
            save(session)
        }
        if let instanceId = session.instanceId {
            if config.executionMode == .controller && !config.controllerFunctionName.isEmpty {
                _ = try? await FunctionClient.invoke(
                    functionName: config.controllerFunctionName,
                    region: region,
                    action: "terminate",
                    session: session,
                    extra: ["firewallWaitSeconds": 0],
                    credential: credential
                )
            }
            do {
                try await ComputeClient.terminateInstance(instanceId: instanceId, region: region, credential: credential)
            } catch CloudAPIError.api(let code, _) where code.contains("NotFound") {
                // Already gone (cloud timer, console, or an earlier attempt).
            } catch {
                appendLog("Terminate call failed (will verify anyway): \(error.localizedDescription)")
            }
        }

        operationStatusMessage = "Verifying server is gone..."
        var serverGone = false
        let deadline = Date().addingTimeInterval(Self.verifyTimeout)
        while Date() < deadline {
            let byId: ComputeInstanceInfo?? = session.instanceId == nil ? .some(nil)
                : try? await ComputeClient.instanceIfExists(instanceId: session.instanceId!, region: region, credential: credential)
            let byTag = try? await ComputeClient.findInstances(sessionTag: session.id, region: region, credential: credential)
            if case .some(.none) = byId, byTag?.isEmpty == true {
                serverGone = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        appendLog(serverGone ? "Verified: server no longer exists" : "Server still listed after \(Int(Self.verifyTimeout))s")

        var firewallGone = true
        if let sgId = session.securityGroupId {
            operationStatusMessage = "Deleting firewall..."
            firewallGone = await FirewallClient.delete(securityGroupId: sgId, region: region, credential: credential)
            appendLog(firewallGone ? "Verified: firewall \(sgId) deleted" : "Firewall \(sgId) still in use")
        }
        if serverGone && firewallGone {
            operationStatusMessage = "Verified: nothing left billing"
        }
        return serverGone && firewallGone
    }

    private func closeSession(_ session: SessionRecord, status: SessionStatus, note: String) {
        var closed = session
        closed.status = status
        closed.endTime = closed.endTime ?? Date()
        history.insert(closed, at: 0)
        if history.count > 20 { history.removeLast() }
        currentSession = nil
        SubscriptionServer.shared.stop()
        persistState()
        appendLog("Session \(session.id) \(note)")
    }

    // MARK: - Reconcile

    func reconcileSession() async {
        guard let session = currentSession, let instanceId = session.instanceId, !session.isDemo else { return }
        let (config, credential) = credentials()
        guard !config.secretId.isEmpty else { return }

        do {
            guard let info = try await ComputeClient.instanceIfExists(
                instanceId: instanceId, region: session.region, credential: credential
            ), !["TERMINATING", "SHUTDOWN", "LAUNCH_FAILED"].contains(info.state) else {
                appendLog("Instance \(instanceId) is gone (cloud timer or console). Closing session.")
                if let sgId = session.securityGroupId {
                    _ = await FirewallClient.delete(securityGroupId: sgId, region: session.region, credential: credential, attempts: 1)
                }
                await NativeVPNController.shared.remove()
                closeSession(session, status: .terminated, note: "closed; instance already gone")
                return
            }
            var updated = session
            if let ip = info.publicIP {
                updated.publicIP = ip
                updated.shadowsocks.host = ip
                if updated.status == .ready, updated.endpoints?.isEmpty ?? true {
                    updated.endpoints = await NodeHealth.endpoints(ip: ip)
                }
            }
            save(updated)
        } catch {
            appendLog("Reconcile error: \(error.localizedDescription)")
        }
    }
}
