import Foundation

public enum WorkOrigin: String, Codable, Sendable, CaseIterable {
    case interactive
    case claudeSubagent, claudeScripted
    case codexGuardian, codexSubagent, codexScripted, codexImported, codexService

    public var provider: Provider { rawValue.hasPrefix("claude") ? .claude : .codex }

    public var title: String {
        switch self {
        case .interactive: String(localized: "Your sessions")
        case .claudeSubagent: String(localized: "Claude subagents")
        case .claudeScripted: String(localized: "Scripted Claude runs")
        case .codexGuardian: String(localized: "Codex Guardian reviews")
        case .codexSubagent: String(localized: "Codex subagents")
        case .codexScripted: String(localized: "Scripted Codex runs")
        case .codexImported: String(localized: "Claude sessions imported into Codex")
        case .codexService: String(localized: "Other Codex background threads")
        }
    }

    public var detail: String {
        switch self {
        case .interactive: ""
        case .claudeSubagent: String(localized: "Task agents your Claude sessions started")
        case .claudeScripted: String(localized: "claude -p from scripts, scheduled jobs and SDK apps")
        case .codexGuardian: String(localized: "Automatic model reviews of risky commands")
        case .codexSubagent: String(localized: "Agents your Codex threads spawned")
        case .codexScripted: String(localized: "codex exec from scripts and jobs")
        case .codexImported: String(localized: "The Codex app copies Claude Code transcripts into its own threads")
        case .codexService: String(localized: "Memory, titles and other service work")
        }
    }
}

public struct BackgroundUsage: Sendable, Identifiable, Equatable {
    public let origin: WorkOrigin
    public var runs: Int
    public var tokens: Tokens
    public var lastActivity: Date
    public var id: WorkOrigin { origin }

    static func collect(_ logs: [ParsedLog], from cutoff: Date, to now: Date) -> [BackgroundUsage] {
        var groups: [WorkOrigin: BackgroundUsage] = [:]
        for log in logs where log.origin != .interactive {
            guard let last = log.lastActivity, last >= cutoff, last <= now.addingTimeInterval(60) else { continue }
            let tokens = log.events.filter { $0.date >= cutoff && $0.date <= now }.reduce(Tokens()) { $0 + $1.tokens }
            var group = groups[log.origin] ?? BackgroundUsage(origin: log.origin, runs: 0, tokens: Tokens(), lastActivity: last)
            group.runs += 1
            group.tokens = group.tokens + tokens
            group.lastActivity = max(group.lastActivity, last)
            groups[log.origin] = group
        }
        return groups.values.sorted {
            $0.tokens.total == $1.tokens.total ? $0.runs > $1.runs : $0.tokens.total > $1.tokens.total
        }
    }
}
