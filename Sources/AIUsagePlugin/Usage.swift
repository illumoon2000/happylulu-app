import Foundation

public struct UsageWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    // Round down: 0.4% left must never look like an extra 1% of allowance.
    public var remainingPercent: Int { Int(floor(min(100, max(0, 100 - usedPercent)))) }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

public struct RateLimitBucket: Decodable, Sendable {
    public let limitId: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
}

public struct RateLimitsResponse: Decodable, Sendable {
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?

    public func weeklyWindow() throws -> UsageWindow {
        let bucket: RateLimitBucket?
        if let map = rateLimitsByLimitId, !map.isEmpty {
            bucket = map["codex"]
        } else {
            bucket = rateLimits.flatMap { $0.limitId == nil || $0.limitId == "codex" ? $0 : nil }
        }
        guard let bucket else { throw UsageError.noCodexQuota }
        guard let weekly = [bucket.primary, bucket.secondary].compactMap({ $0 })
            .first(where: { $0.windowDurationMins == 10_080 && $0.usedPercent.isFinite })
        else { throw UsageError.noWeeklyQuota }
        return weekly
    }
}

public struct UsageSnapshot: Sendable {
    public let weekly: UsageWindow
    public let fetchedAt: Date
    public let accountKey: String?

    public init(weekly: UsageWindow, fetchedAt: Date = Date(), accountKey: String? = nil) {
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.accountKey = accountKey
    }

    public func isStale(at date: Date = Date(), intervalMinutes: Int) -> Bool {
        if let reset = weekly.resetDate, date >= reset { return true }
        return date.timeIntervalSince(fetchedAt) >= Double(max(intervalMinutes * 2, 10) * 60)
    }
}

public enum UsageError: LocalizedError {
    case cliNotFound, notLoggedIn, unsupportedAccount, noWeeklyQuota, noCodexQuota
    case timeout, disconnected, invalidResponse, loginFailed, loginTimeout, server(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: return "Codex CLI를 찾을 수 없습니다. 연결 설정에서 실행 파일을 선택하세요."
        case .notLoggedIn: return "ChatGPT에 로그인하면 주간 잔여량을 확인할 수 있습니다."
        case .unsupportedAccount: return "ChatGPT 로그인이 필요합니다. API 키 계정에서는 주간 한도를 조회할 수 없습니다."
        case .noWeeklyQuota: return "이 계정에서 주간 한도가 제공되지 않았습니다."
        case .noCodexQuota: return "Codex 사용량 정보를 찾을 수 없습니다."
        case .timeout: return "사용량 조회 시간이 초과되었습니다. 연결을 확인하고 다시 시도하세요."
        case .disconnected: return "Codex 연결이 종료되었습니다. 새로고침하거나 CLI 경로를 확인하세요."
        case .invalidResponse: return "Codex 응답을 읽지 못했습니다. CLI를 업데이트하고 다시 시도하세요."
        case .loginFailed: return "로그인을 완료하지 못했습니다. 다시 시도하세요."
        case .loginTimeout: return "로그인 대기 시간이 지났습니다. 로그인 버튼을 눌러 다시 시도하세요."
        case .server: return "사용량을 조회하지 못했습니다. Codex 로그인과 네트워크를 확인하세요."
        }
    }
}

public enum LabelFormat: String, Codable, CaseIterable, Sendable {
    case named, percentage

    public func title(remaining: Int?, stale: Bool = false) -> String {
        let value = remaining.map { "\($0)%" } ?? "—"
        return (self == .named ? "Codex \(value)" : value) + (stale && remaining != nil ? " ·" : "")
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var refreshMinutes = 5
    public var labelFormat: LabelFormat = .named
    public var notificationsEnabled = false
    public var notificationThreshold = 20
    public var cliPath = ""

    public init() {}

    public mutating func normalize() {
        if ![1, 5, 10, 15, 30].contains(refreshMinutes) { refreshMinutes = 5 }
        if ![10, 20, 30].contains(notificationThreshold) { notificationThreshold = 20 }
        cliPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LowUsageAlertGate {
    private var deliveredKey: String?

    public init(deliveredKey: String? = nil) { self.deliveredKey = deliveredKey }

    public func pendingKey(for window: UsageWindow, threshold: Int, enabled: Bool) -> String? {
        guard enabled, window.remainingPercent <= threshold, let reset = window.resetsAt else { return nil }
        let key = "\(Int(reset))-\(threshold)"
        return key != deliveredKey ? key : nil
    }

    public mutating func markDelivered(_ key: String) { deliveredKey = key }
}
