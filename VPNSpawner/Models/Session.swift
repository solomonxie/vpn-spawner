import Foundation

enum SessionStatus: String, Codable, CaseIterable {
    case idle = "Idle"
    case provisioning = "Provisioning"
    case ready = "Ready"
    case stopping = "Stopping"
    case terminated = "Terminated"
    case failed = "Failed"

    var colorName: String {
        switch self {
        case .idle: return "secondary"
        case .provisioning: return "orange"
        case .ready: return "green"
        case .stopping: return "yellow"
        case .terminated: return "gray"
        case .failed: return "red"
        }
    }
}

/// Provisioning steps with typical durations measured on Tencent Cloud, for the progress hint.
enum ProvisionStage: String, Codable, CaseIterable {
    case preparing = "Detecting your IP & creating firewall"
    case launching = "Launching server"
    case booting = "Server booting"
    case installing = "Installing Shadowsocks + IKEv2"

    var step: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// Typical seconds remaining from the start of this stage until ready.
    var typicalRemaining: TimeInterval {
        switch self {
        case .preparing: return 120
        case .launching: return 110
        case .booting: return 100
        case .installing: return 75
        }
    }
}

struct SessionRecord: Codable, Identifiable, Hashable {
    var id: String
    var status: SessionStatus
    var startTime: Date
    var expiryTime: Date
    var region: String
    var instanceId: String?
    var publicIP: String?
    var securityGroupId: String?
    var allowedIPs: [String]?
    var ikev2PSK: String?
    var shadowsocks: ShadowsocksConfig
    var estimatedCostPerHour: Double
    var isDemo: Bool
    var errorMessage: String?
    /// Countdown length; the countdown starts at readyTime, not at launch.
    var plannedMinutes: Int?
    var readyTime: Date?
    var stage: ProvisionStage?
    var stageStartedAt: Date?
    /// Set only after Tencent confirms the instance and its firewall no longer exist.
    var cleanupVerified: Bool?
    var stopStartedAt: Date?
    /// Protocols requested at launch; nil for sessions from before multi-protocol (IKEv2 + Shadowsocks).
    var protocols: [VPNProtocol]?
    /// Filled from the node's /client.json once ready.
    var endpoints: [NodeEndpoint]?
    var instanceType: String?
    /// When the session closed; freezes elapsed time and cost in history.
    var endTime: Date?

    init(
        id: String = "sess_\(UUID().uuidString.prefix(8).lowercased())",
        status: SessionStatus = .idle,
        startTime: Date = Date(),
        durationMinutes: Int = 10,
        region: String = "ap-guangzhou",
        instanceId: String? = nil,
        publicIP: String? = nil,
        securityGroupId: String? = nil,
        shadowsocks: ShadowsocksConfig = ShadowsocksConfig(),
        estimatedCostPerHour: Double = 0.25,
        isDemo: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.status = status
        self.startTime = startTime
        self.expiryTime = startTime.addingTimeInterval(TimeInterval(durationMinutes * 60))
        self.region = region
        self.instanceId = instanceId
        self.publicIP = publicIP
        self.securityGroupId = securityGroupId
        self.shadowsocks = shadowsocks
        self.estimatedCostPerHour = estimatedCostPerHour
        self.isDemo = isDemo
        self.errorMessage = errorMessage
        self.plannedMinutes = durationMinutes
    }

    private var countdownStart: Date { readyTime ?? startTime }

    var totalDuration: TimeInterval {
        expiryTime.timeIntervalSince(countdownStart)
    }

    /// Before the node is ready the full planned time is shown, frozen.
    var remainingTime: TimeInterval {
        guard readyTime != nil else { return TimeInterval((plannedMinutes ?? 10) * 60) }
        return max(0, expiryTime.timeIntervalSince(Date()))
    }

    var progress: Double {
        guard readyTime != nil, totalDuration > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(countdownStart)
        return min(max(elapsed / totalDuration, 0), 1)
    }

    var provisioningElapsed: TimeInterval { Date().timeIntervalSince(startTime) }

    /// Estimated seconds until ready, from the current stage's typical remaining time.
    var estimatedSecondsLeft: TimeInterval {
        guard let stage else { return ProvisionStage.preparing.typicalRemaining }
        let inStage = Date().timeIntervalSince(stageStartedAt ?? startTime)
        return max(5, stage.typicalRemaining - inStage)
    }

    var hasExpired: Bool {
        readyTime != nil && remainingTime <= 0
    }

    var formattedRemainingTime: String {
        let remaining = Int(remainingTime)
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var elapsedHours: Double {
        let elapsedSeconds = (endTime ?? Date()).timeIntervalSince(startTime)
        return max(0, elapsedSeconds / 3600.0)
    }

    var currentCostEstimate: Double {
        elapsedHours * estimatedCostPerHour
    }

    var subscriptionURLString: String {
        if let publicIP, !publicIP.isEmpty, !isDemo {
            return "http://\(publicIP):8389/sub"
        }
        return "http://127.0.0.1:8964/sub"
    }
}
