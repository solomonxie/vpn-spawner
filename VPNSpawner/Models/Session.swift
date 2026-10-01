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
    var shadowsocks: ShadowsocksConfig
    var estimatedCostPerHour: Double
    var isDemo: Bool
    var errorMessage: String?

    init(
        id: String = "sess_\(UUID().uuidString.prefix(8).lowercased())",
        status: SessionStatus = .idle,
        startTime: Date = Date(),
        durationMinutes: Int = 30,
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
    }

    var totalDuration: TimeInterval {
        expiryTime.timeIntervalSince(startTime)
    }

    var remainingTime: TimeInterval {
        max(0, expiryTime.timeIntervalSince(Date()))
    }

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(startTime)
        return min(max(elapsed / totalDuration, 0), 1)
    }

    var hasExpired: Bool {
        remainingTime <= 0
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
        let elapsedSeconds = Date().timeIntervalSince(startTime)
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
