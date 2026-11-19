import Foundation

public struct GrokUsage: Codable, Sendable {
    public static let relativePath = "Library/Application Support/Agent Meter/grok-usage.json"

    public enum Status: String, Codable, Sendable {
        case ready, signedOut, keyDenied, expired, noPlan, unavailable

        public var message: String {
            switch self {
            case .ready: String(localized: "Weekly included usage through Grok Bot")
            case .signedOut: String(localized: "Sign in to Grok Bot to load the weekly limit.")
            case .keyDenied: String(localized: "Allow access to “Grok Bot Safe Storage” in Keychain to read the Grok Bot session.")
            case .expired: String(localized: "Open Grok Bot to refresh its sign-in.")
            case .noPlan: String(localized: "This Grok account has no weekly included usage.")
            case .unavailable: String(localized: "Grok usage temporarily unavailable. Will retry automatically.")
            }
        }
    }

    public var status: Status
    public let attemptedAt: Date
    public var quota: Quota?
    public var plan: String?

    public init(status: Status, attemptedAt: Date = .now, quota: Quota? = nil, plan: String? = nil) {
        self.status = status
        self.attemptedAt = attemptedAt
        self.quota = quota
        self.plan = plan
    }

    public static func parse(_ data: Data, now: Date = .now) -> Self {
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            return Self(status: .unavailable, attemptedAt: now)
        }
        let plan = value.plan.flatMap { NotchText.clean($0, limit: 40, singleLine: true) }
        guard value.hasLimit == true else { return Self(status: .noPlan, attemptedAt: now, plan: plan) }
        let quota = Quota(window: .sevenDays, used: value.percent ?? 0, observedAt: now,
                          resetEpoch: timestamp(value.reset)?.timeIntervalSince1970)
        return Self(status: quota == nil ? .unavailable : .ready, attemptedAt: now, quota: quota, plan: plan)
    }

    public static func read(_ url: URL) -> Self? {
        guard let file = try? openLog(url), let data = try? file.read(upToCount: 4097), data.count <= 4096,
              let usage = try? JSONDecoder().decode(Self.self, from: data),
              usage.attemptedAt <= .now.addingTimeInterval(60),
              usage.quota.map({ $0.window == .sevenDays && (0...100).contains($0.used) }) != false else { return nil }
        return usage
    }

    private struct Response: Decodable {
        let percent: Double?
        let reset: String?
        let hasLimit: Bool?
        let plan: String?

        enum CodingKeys: String, CodingKey {
            case percent = "usagePercent", reset = "nextResetTimestampUtc"
            case hasLimit = "hasNonZeroIncludedLimit", plan = "grokPlanLabel"
        }
    }
}
