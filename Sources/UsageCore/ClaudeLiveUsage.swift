import Foundation

public struct ClaudeLiveUsage: Codable, Sendable {
    public static let relativePath = "Library/Application Support/Agent Meter/claude-usage.json"
    public static let refreshRequestPath = "Library/Application Support/Agent Meter/claude-refresh-request"

    public enum Status: String, Codable, Sendable {
        case ready, clientMissing, needsLogin, timedOut, unavailable, throttled
        public var message: String {
            switch self {
            case .ready: "Automatic refresh every 5 minutes"
            case .clientMissing: "Install or select the official Claude Code client."
            case .needsLogin: "Sign in through Claude Code to load account limits."
            case .timedOut: "Claude Code timed out. Will retry automatically."
            case .unavailable: "Account limits temporarily unavailable. Will retry automatically."
            case .throttled: "Claude rate-limited the limits request. Will retry automatically."
            }
        }
    }

    public var status: Status
    public let attemptedAt: Date
    public var quotas: [Quota]
    public var fable: Quota?
    public var models: [ModelQuota]?
    public var separateSignIn: Bool?
    public var retryAt: Date?
    public var throttledSince: Date?

    public init(status: Status, attemptedAt: Date = .now, quotas: [Quota] = [], fable: Quota? = nil,
                models: [ModelQuota]? = nil, separateSignIn: Bool? = nil) {
        self.status = status
        self.attemptedAt = attemptedAt
        self.quotas = quotas
        self.fable = fable
        self.models = models
        self.separateSignIn = separateSignIn
    }

    public static let throttleBackoff: TimeInterval = 60 * 60
    public static let refreshInterval: TimeInterval = 5 * 60

    public func scheduleStopped(at now: Date = .now, watchingSince: Date) -> Bool {
        guard !waiting(at: now), (retryAt ?? .distantPast) <= now else { return false }
        let overdue = 3 * Self.refreshInterval
        return now.timeIntervalSince(attemptedAt) >= overdue && now.timeIntervalSince(watchingSince) >= overdue
    }

    public mutating func keep(_ old: Self?) {
        if status == .throttled {
            retryAt = attemptedAt.addingTimeInterval(Self.throttleBackoff)
            throttledSince = old?.status == .throttled ? old?.throttledSince ?? old?.attemptedAt : attemptedAt
        }
        guard [.timedOut, .unavailable, .clientMissing, .throttled, .needsLogin].contains(status), let old else { return }
        quotas = old.quotas
        fable = old.fable
        models = old.models
    }

    public func waiting(at now: Date = .now) -> Bool {
        guard status == .throttled, let retryAt else { return false }
        return retryAt > now && retryAt.timeIntervalSince(attemptedAt) <= Self.throttleBackoff
    }

    public func message(at now: Date = .now, stopped: Bool = false) -> String {
        if stopped {
            let last = attemptedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return "The background collector has not run since \(last). Turn automatic refresh back on in Settings → Claude account."
        }
        switch status {
        case .throttled where separateSignIn != true:
            return "Claude Code is rate-limited by your other sessions. Sign in for Agent Meter to get reset times."
        case .throttled:
            let next = (retryAt ?? attemptedAt).formatted(.dateTime.hour().minute())
            let shown = quotas.map(\.observedAt).max().map { " Showing limits from \($0.formatted(.dateTime.hour().minute()))." } ?? ""
            guard let since = throttledSince, now.timeIntervalSince(since) >= 2 * Self.throttleBackoff else {
                return "Claude rate-limited the limits request (429).\(shown) Next try at \(next)."
            }
            let start = since.formatted(.dateTime.hour().minute())
            return "Claude has refused the limits request since \(start).\(shown) Next try at \(next). If it keeps failing, sign in for Agent Meter again in Settings."
        case .needsLogin where separateSignIn == true:
            return "Agent Meter's Claude sign-in expired. Sign in again in Settings → Claude account."
        default:
            return status.message
        }
    }

    public static func parse(_ data: Data, now: Date = .now) -> Self {
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            return Self(status: .unavailable, attemptedAt: now)
        }
        guard value.available == true else { return Self(status: .needsLogin, attemptedAt: now) }
        guard let limits = value.limits else { return Self(status: .throttled, attemptedAt: now) }
        let windows = [(QuotaWindow.fiveHours, limits.fiveHour), (.sevenDays, limits.sevenDay)]
        let quotas = windows.compactMap { window, value in value?.quota(window: window, now: now) }
        let fable = limits.scoped?.first {
            $0.name?.localizedCaseInsensitiveContains("fable") == true
        }?.quota(window: .sevenDays, now: now)
        var models: [ModelQuota] = []
        let named = [("Opus", limits.opus), ("Sonnet", limits.sonnet)]
            + (limits.scoped ?? []).compactMap { window -> (String, Window?)? in window.name.map { ($0, window) } }
        for (name, window) in named {
            guard !name.localizedCaseInsensitiveContains("fable"),
                  let model = ModelQuota(name: name, quota: window?.quota(window: .sevenDays, now: now)),
                  !models.contains(where: { $0.matches(model) }) else { continue }
            models.append(model)
        }
        return Self(status: quotas.isEmpty && fable == nil && models.isEmpty ? .unavailable : .ready,
                    attemptedAt: now, quotas: quotas, fable: fable, models: models)
    }

    public static func read(_ url: URL) -> Self? {
        guard let file = try? openLog(url), let data = try? file.read(upToCount: 8193), data.count <= 8192,
              let usage = try? JSONDecoder().decode(Self.self, from: data),
              usage.attemptedAt <= .now.addingTimeInterval(60),
              usage.quotas.allSatisfy({ $0.used.isFinite && (0...100).contains($0.used) }),
              usage.fable.map({ $0.window == .sevenDays && $0.used.isFinite && (0...100).contains($0.used) }) != false,
              (usage.models ?? []).allSatisfy({ $0.quota.used.isFinite && (0...100).contains($0.quota.used) }) else { return nil }
        return usage
    }

    private struct Response: Decodable {
        let available: Bool?
        let limits: Limits?
        enum CodingKeys: String, CodingKey { case available = "rate_limits_available", limits = "rate_limits" }
    }

    private struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let opus: Window?
        let sonnet: Window?
        let scoped: [Window]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour", sevenDay = "seven_day", opus = "seven_day_opus", sonnet = "seven_day_sonnet"
            case scoped = "model_scoped"
        }
    }

    private struct Window: Decodable {
        let percent: Double?
        let name: String?
        let reset: String?
        enum CodingKeys: String, CodingKey {
            case percent = "utilization", name = "display_name", reset = "resets_at"
        }
        func quota(window: QuotaWindow, now: Date) -> Quota? {
            percent.flatMap { Quota(window: window, used: $0, observedAt: now,
                                   resetEpoch: timestamp(reset)?.timeIntervalSince1970) }
        }
    }
}

public struct ModelQuota: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let quota: Quota
    public var id: String { name.lowercased() }

    public init?(name: String, quota: Quota?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quota, !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        self.name = trimmed
        self.quota = quota
    }

    func matches(_ other: ModelQuota) -> Bool {
        id == other.id || id.contains(other.id) || other.id.contains(id)
    }

    public static func newest(_ groups: [ModelQuota]...) -> [ModelQuota] {
        var result: [ModelQuota] = []
        for model in groups.joined() {
            if let index = result.firstIndex(where: { $0.matches(model) }) {
                if model.quota.observedAt > result[index].quota.observedAt { result[index] = model }
            } else {
                result.append(model)
            }
        }
        let order = ["opus", "sonnet"]
        func rank(_ model: ModelQuota) -> Int { order.firstIndex { model.id.contains($0) } ?? order.count }
        return result.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }
}
