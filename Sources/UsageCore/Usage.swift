import Foundation

public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex

    public var id: Self { self }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }

    public func sessionURL(_ id: UUID) -> URL? {
        guard self == .codex else { return nil }
        return URL(string: "codex://threads/\(id.uuidString.lowercased())")
    }

    public static func codexPluginURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "codex", components.host == "plugins",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.hasPrefix("/"),
              !components.path.dropFirst().contains("/") else { return nil }
        let id = components.path.dropFirst()
        guard !id.isEmpty,
              id.utf8.count <= 200, id != ".", id != "..",
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 64, 95].contains($0) }) else { return nil }
        return URL(string: "codex://plugins/\(id)")
    }

    public func resumeCommand(_ id: UUID) -> String {
        let command = self == .claude ? "claude --resume" : "codex resume"
        return "\(command) \(id.uuidString.lowercased())"
    }
}

public enum LogSource: String, CaseIterable, Sendable, Identifiable {
    case claudeProjects, codexSessions, codexArchive

    public var id: Self { self }
    public var provider: Provider { self == .claudeProjects ? .claude : .codex }

    public var folder: String {
        switch self {
        case .claudeProjects: "projects"
        case .codexSessions: "sessions"
        case .codexArchive: "archived_sessions"
        }
    }
}

public enum QuotaWindow: Int, CaseIterable, Codable, Sendable, Identifiable {
    case fiveHours = 300
    case sevenDays = 10080

    public var id: Self { self }
    public var title: String { self == .fiveHours ? "5h" : "7d" }
}

public struct Quota: Codable, Sendable, Equatable, Identifiable {
    public let window: QuotaWindow
    public let used: Double
    public let observedAt: Date
    public let resetsAt: Date?
    public var id: QuotaWindow { window }

    init?(window: QuotaWindow, used: Double, observedAt: Date, resetEpoch: Double?) {
        guard used.isFinite, (0...100).contains(used) else { return nil }
        self.window = window
        self.used = used
        self.observedAt = observedAt
        self.resetsAt = resetEpoch.flatMap {
            $0.isFinite && $0 > 0 && $0 < 32_503_680_000 ? Date(timeIntervalSince1970: $0) : nil
        }
    }

    public func isStale(at now: Date) -> Bool {
        if let resetsAt, resetsAt <= now { return true }
        return now.timeIntervalSince(observedAt) >= Double(window.rawValue * 60)
    }

    public func replacingReset(_ date: Date?) -> Quota {
        Quota(window: window, used: used, observedAt: observedAt, resetEpoch: date?.timeIntervalSince1970) ?? self
    }

    public func projectedExhaustion(at now: Date) -> Date? {
        guard let resetsAt, resetsAt > now, used < 100 else { return nil }
        let duration = Double(window.rawValue * 60)
        let elapsed = duration - resetsAt.timeIntervalSince(observedAt)
        let short = duration < 86_400
        guard elapsed > 0, elapsed <= duration, used > 0,
              short ? used >= 10 : elapsed >= 86_400 else { return nil }
        let exhaustion = observedAt.addingTimeInterval((100 - used) / (used / elapsed))
        guard exhaustion < resetsAt, exhaustion > now || now.timeIntervalSince(observedAt) < 300 else { return nil }
        return max(now, exhaustion)
    }
}

public struct Tokens: Sendable, Equatable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0

    public init(input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0) {
        self.input = input
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public var total: Int64 { Self.add(Self.add(input, cached), Self.add(cacheWrite, output)) }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: add(lhs.input, rhs.input), cached: add(lhs.cached, rhs.cached),
             cacheWrite: add(lhs.cacheWrite, rhs.cacheWrite), output: add(lhs.output, rhs.output))
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
    }
}

public struct SessionUsage: Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)-\(sessionID.uuidString)" }
    public let sessionID: UUID
    public let provider: Provider
    public let project: String
    public let tokens: Tokens
    public let lastActivity: Date
    public var isService = false
    public var entrypoint: String?
    public var origin = WorkOrigin.interactive
}

public struct ProjectUsage: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let tokens: Tokens
    public let sessions: [SessionUsage]
    public var name: String { path.isEmpty ? "Unknown project" : (path as NSString).lastPathComponent }
}

public struct DailyUsage: Sendable {
    public let date: Date
    public let provider: Provider
    public var tokens: Tokens
    public var sessions: Int
}

public struct ScanResult: Sendable {
    public var sessions: [SessionUsage] = []
    public var notchActivities: [NotchActivity] = []
    public var dailyUsage: [DailyUsage] = []
    public var claudeQuotas: [Quota] = []
    public var claudeQuotasFromDesktop = false
    public var claudeFableQuota: Quota?
    public var claudeFableQuotaFromCode = false
    public var automaticClaude: ClaudeLiveUsage?
    public var claudeQuotasAutomatic = false
    public var claudeQuotasLive = false
    public var claudeFableQuotaAutomatic = false
    public var claudeModelQuotas: [ModelQuota] = []
    public var grok: GrokUsage?
    public var fableEstimateUSD: Double?
    public var codexQuotas: [Quota] = []
    public var background: [BackgroundUsage] = []
    public var agentProcesses: AgentProcessSnapshot?
    public var codexLive: CodexLiveUsage?
    public var codexQuotasLive = false
    public var unreadable: Set<LogSource> = []
    public var skippedFiles = 0

    public init() {}

    public func quotas(for provider: Provider) -> [Quota] {
        provider == .claude ? claudeQuotas : codexQuotas
    }

    public func projects(for provider: Provider?) -> [ProjectUsage] {
        let visible = sessions.filter { provider == nil || $0.provider == provider }
        return Dictionary(grouping: visible, by: \.project).map { path, sessions in
            ProjectUsage(path: path, tokens: sessions.reduce(Tokens()) { $0 + $1.tokens },
                         sessions: sessions.sorted { $0.lastActivity > $1.lastActivity })
        }.sorted {
            $0.tokens.total == $1.tokens.total ? $0.path < $1.path : $0.tokens.total > $1.tokens.total
        }
    }
}

func projectPath(_ value: String?) -> String? {
    guard let value, value.hasPrefix("/"), value.utf8.count <= 4096 else { return nil }
    return URL(fileURLWithPath: value).standardizedFileURL.path
}
