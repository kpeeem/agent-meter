import Foundation

public struct CodexLiveUsage: Codable, Sendable {
    public static let relativePath = "Library/Application Support/Agent Meter/codex-usage.json"
    public static let throttleBackoff: TimeInterval = 60 * 60

    public enum Status: String, Codable, Sendable {
        case ready, signedOut, expired, throttled, unavailable

        public var message: String {
            switch self {
            case .ready: "Live limits from ChatGPT"
            case .signedOut: "Sign in to Codex with ChatGPT to load live limits."
            case .expired: "Codex sign-in needs renewing. Open Codex once and live limits come back."
            case .throttled: "ChatGPT rate-limited the limits request. Next try in an hour."
            case .unavailable: "Live Codex limits temporarily unavailable. Showing session logs."
            }
        }
    }

    public var status: Status
    public let attemptedAt: Date
    public var quotas: [Quota]
    public var plan: String?
    public var resets: Int?
    public var usableResets: Int?

    public init(status: Status, attemptedAt: Date = .now, quotas: [Quota] = [], plan: String? = nil,
                resets: Int? = nil, usableResets: Int? = nil) {
        self.status = status
        self.attemptedAt = attemptedAt
        self.quotas = quotas
        self.plan = plan
        self.resets = resets
        self.usableResets = usableResets
    }

    public func waiting(at now: Date = .now) -> Bool {
        status == .throttled && attemptedAt <= now && now.timeIntervalSince(attemptedAt) < Self.throttleBackoff
    }

    public mutating func keep(_ old: Self?) {
        guard status != .ready, let old else { return }
        quotas = old.quotas
        plan = plan ?? old.plan
        resets = resets ?? old.resets
        usableResets = usableResets ?? old.usableResets
    }

    public static func parse(_ data: Data, now: Date = .now) -> Self {
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            return Self(status: .unavailable, attemptedAt: now)
        }
        let quotas = [value.limits?.primary, value.limits?.secondary].compactMap { $0?.quota(at: now) }
        let plan = value.plan.flatMap { NotchText.clean($0, limit: 24, singleLine: true) }?.capitalized
        let count = { (value: Int?) in value.map { min(max($0, 0), 99) } }
        return Self(status: quotas.isEmpty ? .unavailable : .ready, attemptedAt: now, quotas: quotas, plan: plan,
                    resets: count(value.resets?.available), usableResets: count(value.resets?.usable))
    }

    public static func read(_ url: URL) -> Self? {
        guard let file = try? openLog(url), let data = try? file.read(upToCount: 4097), data.count <= 4096,
              let usage = try? JSONDecoder().decode(Self.self, from: data),
              usage.attemptedAt <= .now.addingTimeInterval(60),
              usage.quotas.allSatisfy({ $0.used.isFinite && (0...100).contains($0.used) }) else { return nil }
        return usage
    }

    private struct Response: Decodable {
        let plan: String?
        let limits: Limits?
        let resets: Resets?
        enum CodingKeys: String, CodingKey {
            case plan = "plan_type", limits = "rate_limit", resets = "rate_limit_reset_credits"
        }
    }

    private struct Resets: Decodable {
        let available: Int?
        let usable: Int?
        enum CodingKeys: String, CodingKey { case available = "available_count", usable = "applicable_available_count" }
    }

    private struct Limits: Decodable {
        let primary: Window?
        let secondary: Window?
        enum CodingKeys: String, CodingKey { case primary = "primary_window", secondary = "secondary_window" }
    }

    private struct Window: Decodable {
        let used: Double?
        let seconds: Int?
        let resetAt: Double?
        enum CodingKeys: String, CodingKey {
            case used = "used_percent", seconds = "limit_window_seconds", resetAt = "reset_at"
        }

        func quota(at now: Date) -> Quota? {
            guard let used, let seconds, seconds % 60 == 0, let window = QuotaWindow(rawValue: seconds / 60) else {
                return nil
            }
            return Quota(window: window, used: used, observedAt: now, resetEpoch: resetAt)
        }
    }
}
