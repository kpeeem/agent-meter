import Foundation

public enum QuotaSeries: String, Codable, Sendable, CaseIterable {
    case claudeFiveHours = "claude.5h", claudeWeek = "claude.7d"
    case codexFiveHours = "codex.5h", codexWeek = "codex.7d"
    case grokWeek = "grok.7d"

    public var title: String {
        switch self {
        case .claudeFiveHours: "Claude 5h"
        case .claudeWeek: "Claude 7d"
        case .codexFiveHours: "Codex 5h"
        case .codexWeek: "Codex 7d"
        case .grokWeek: "Grok 7d"
        }
    }

    public var provider: Provider? {
        switch self {
        case .claudeFiveHours, .claudeWeek: .claude
        case .codexFiveHours, .codexWeek: .codex
        case .grokWeek: nil
        }
    }

    public var shortWindow: Bool { self == .claudeFiveHours || self == .codexFiveHours }
}

public struct QuotaSample: Codable, Sendable, Equatable {
    public let series: QuotaSeries
    public let used: Double
    public let at: Date
}

public enum QuotaHistory {
    public static let retention: TimeInterval = 14 * 86_400

    public static func record(_ result: ScanResult, into samples: [QuotaSample], now: Date = .now) -> [QuotaSample] {
        var current = result.claudeQuotas.map { ($0.window == .fiveHours ? QuotaSeries.claudeFiveHours : .claudeWeek, $0) }
            + result.codexQuotas.map { ($0.window == .fiveHours ? QuotaSeries.codexFiveHours : .codexWeek, $0) }
        if let quota = result.grok?.quota { current.append((.grokWeek, quota)) }
        var updated = samples.filter { now.timeIntervalSince($0.at) < retention && $0.at <= now.addingTimeInterval(60) }
        for (series, quota) in current where !quota.isStale(at: now) && quota.observedAt <= now.addingTimeInterval(60) {
            if let last = updated.last(where: { $0.series == series }) {
                guard quota.observedAt > last.at else { continue }
                if abs(quota.used - last.used) < 1, quota.observedAt.timeIntervalSince(last.at) < 600 { continue }
            }
            updated.append(QuotaSample(series: series, used: quota.used, at: quota.observedAt))
        }
        return updated
    }
}
