import Foundation

public actor UsageScanner {
    private struct Cached {
        let source: LogSource
        let size: Int
        let modified: Date
        let parsed: ParsedLog?
    }

    private var files: [URL: Cached] = [:]

    public init() {}

    public func scan(_ roots: [LogSource: URL], days: Int, now: Date = .now,
                     desktopHistory: URL? = nil, statisticsCache: URL? = nil,
                     automaticClaude: URL? = nil, grokUsage: URL? = nil, codexUsage: URL? = nil) -> ScanResult {
        var result = ScanResult()
        result.grok = grokUsage.flatMap(GrokUsage.read)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: 1 - min(30, max(1, days)), to: start) ?? start
        let oldest = min(cutoff, now.addingTimeInterval(-7 * 86_400))
        var refreshed: [URL: Cached] = [:]

        for (source, folder) in roots {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                          .contentModificationDateKey, .fileSizeKey]
            guard folder.lastPathComponent == source.folder,
                  let info = try? folder.resourceValues(forKeys: Set(keys)),
                  info.isDirectory == true, info.isSymbolicLink != true,
                  let entries = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in result.unreadable.insert(source); return true }
                  ) else {
                result.unreadable.insert(source)
                continue
            }

            if source == .claudeProjects {
                let snapshot = ClaudeQuota.read(in: folder, now: now)
                result.claudeQuotas = snapshot.quotas
                result.claudeFableQuota = snapshot.fable
                result.claudeFableQuotaFromCode = snapshot.fable != nil
            }

            for case let url as URL in entries {
                guard let metadata = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if metadata.isSymbolicLink == true {
                    entries.skipDescendants()
                    continue
                }
                guard metadata.isRegularFile == true, url.pathExtension == "jsonl",
                      source.provider == .claude || url.lastPathComponent.hasPrefix("rollout-"),
                      let size = metadata.fileSize, size > 0,
                      let modified = metadata.contentModificationDate, modified >= oldest else { continue }

                if let cached = files[url], cached.source == source, cached.size == size, cached.modified == modified {
                    refreshed[url] = cached
                    continue
                }

                do {
                    let parsed = try source.provider == .claude
                        ? Parsers.claude(url, size: size) : Parsers.codex(url, size: size)
                    refreshed[url] = Cached(source: source, size: size, modified: modified, parsed: parsed)
                } catch {
                    result.skippedFiles += 1
                }
            }
        }
        files = refreshed

        var desktopQuotas: [Quota] = []
        if let desktopHistory, result.claudeQuotas.allSatisfy({ $0.isStale(at: now) }) {
            let desktop = ClaudeQuota.readDesktopHistory(desktopHistory, now: now)
            if !desktop.isEmpty,
               result.claudeQuotas.isEmpty || desktop.contains(where: { !$0.isStale(at: now) }) {
                result.claudeQuotas = desktop
                result.claudeQuotasFromDesktop = true
                desktopQuotas = desktop
            }
        }
        if let statisticsCache, let quota = ClaudeQuota.readStatisticsFableQuota(statisticsCache, now: now),
           quota.observedAt > (result.claudeFableQuota?.observedAt ?? .distantPast) {
            result.claudeFableQuota = quota
            result.claudeFableQuotaFromCode = false
        }
        let statisticsModels = statisticsCache.map { ClaudeQuota.readStatisticsModelQuotas($0, now: now) } ?? []
        result.claudeModelQuotas = ModelQuota.newest(statisticsModels)
        if let automaticClaude, let live = ClaudeLiveUsage.read(automaticClaude) {
            result.automaticClaude = live
            result.claudeModelQuotas = ModelQuota.newest(statisticsModels,
                                                         (live.models ?? []).filter { $0.quota.observedAt <= now })
            for quota in live.quotas where quota.observedAt <= now {
                guard let index = result.claudeQuotas.firstIndex(where: { $0.window == quota.window }) else {
                    result.claudeQuotas.append(quota)
                    continue
                }
                let current = result.claudeQuotas[index]
                let cacheOnly = current.resetsAt == nil && !quota.isStale(at: now)
                    && current.observedAt.timeIntervalSince(quota.observedAt) < 15 * 60
                if current.observedAt < quota.observedAt || cacheOnly {
                    result.claudeQuotas[index] = quota
                } else if current.resetsAt == nil, let reset = quota.resetsAt, reset > current.observedAt {
                    result.claudeQuotas[index] = current.replacingReset(reset)
                }
            }
            result.claudeQuotasAutomatic = result.claudeQuotas.contains { live.quotas.contains($0) }
            result.claudeQuotasFromDesktop = result.claudeQuotas.contains { quota in
                desktopQuotas.contains { $0.window == quota.window && $0.observedAt == quota.observedAt }
            }
            if let quota = live.fable, quota.observedAt <= now,
               quota.observedAt > (result.claudeFableQuota?.observedAt ?? .distantPast) {
                result.claudeFableQuota = quota
                result.claudeFableQuotaFromCode = true
                result.claudeFableQuotaAutomatic = true
            }
        }

        let claudeLogs = refreshed.values.filter { $0.source.provider == .claude }.compactMap(\.parsed)
        let codexLogs = refreshed.values.filter { $0.source.provider == .codex }.compactMap(\.parsed)
        let claude = summarize(claudeLogs, provider: .claude, from: cutoff, to: now, calendar: calendar)
        let codex = summarize(codexLogs, provider: .codex, from: cutoff, to: now, calendar: calendar)
        result.sessions = claude.sessions + codex.sessions
        var activityByID: [String: NotchActivity] = [:]
        for session in result.sessions where !session.isService && now.timeIntervalSince(session.lastActivity) < 4 * 3600 {
            let activity = NotchActivity.recent(session)
            activityByID[activity.id] = activity
        }
        for entry in refreshed.values where entry.source == .codexSessions {
            guard let activity = entry.parsed?.notchActivity, activity.updatedAt <= now,
                  now.timeIntervalSince(activity.updatedAt) < 15 * 60 else { continue }
            if let current = activityByID[activity.id], current.updatedAt > activity.updatedAt { continue }
            activityByID[activity.id] = activity
        }
        result.notchActivities = Array(activityByID.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(64))
        result.dailyUsage = claude.days + codex.days
        if claude.fableEstimateUSD > 0 || (roots[.claudeProjects] != nil && !result.unreadable.contains(.claudeProjects)) {
            result.fableEstimateUSD = claude.fableEstimateUSD
        }
        let codexLive = codexUsage.flatMap(CodexLiveUsage.read)
        result.codexLive = codexLive
        let liveQuotas = (codexLive?.quotas ?? []).filter { $0.observedAt <= now }
        let codexLatest = QuotaWindow.allCases.compactMap { window in
            (codexLogs.flatMap(\.quotas) + liveQuotas).filter {
                $0.window == window && $0.observedAt <= now
            }.max { $0.observedAt < $1.observedAt }
        }
        let newestCodex = codexLatest.map(\.observedAt).max() ?? .distantPast
        result.codexQuotas = codexLatest.filter { newestCodex.timeIntervalSince($0.observedAt) < 3600 }
        result.codexQuotasLive = result.codexQuotas.contains { liveQuotas.contains($0) }
        return result
    }

    private func summarize(_ logs: [ParsedLog], provider: Provider, from cutoff: Date, to now: Date,
                           calendar: Calendar) -> (sessions: [SessionUsage], days: [DailyUsage], fableEstimateUSD: Double) {
        var days: [Date: DailyUsage] = [:]
        var fableEstimateUSD: Double = 0
        let sessions = Dictionary(grouping: logs, by: \.session).compactMap { id, logs -> SessionUsage? in
            let events: [TokenEvent]
            if provider == .claude {
                var messages: [String: TokenEvent] = [:]
                for event in logs.lazy.flatMap(\.events) {
                    if let old = messages[event.key],
                       old.tokens.output > event.tokens.output
                       || (old.tokens.output == event.tokens.output && old.date >= event.date) { continue }
                    messages[event.key] = event
                }
                events = Array(messages.values)
            } else {
                events = logs.max {
                    if $0.events.count != $1.events.count { return $0.events.count < $1.events.count }
                    return ($0.events.last?.date ?? .distantPast) < ($1.events.last?.date ?? .distantPast)
                }?.events ?? []
            }
            var sessionDays: [Date: Tokens] = [:]
            var tokens = Tokens()
            var last: Date?
            for event in events where event.date >= cutoff && event.date <= now {
                let date = calendar.startOfDay(for: event.date)
                sessionDays[date] = (sessionDays[date] ?? Tokens()) + event.tokens
                tokens = tokens + event.tokens
                fableEstimateUSD += event.fableCostUSD
                last = max(last ?? event.date, event.date)
            }
            guard let last else { return nil }
            let service = logs.contains(where: \.isService)
            for (date, tokens) in sessionDays {
                var usage = days[date] ?? DailyUsage(date: date, provider: provider, tokens: Tokens(), sessions: 0)
                usage.tokens = usage.tokens + tokens
                if !service { usage.sessions += 1 }
                days[date] = usage
            }
            let project = logs.filter { !$0.project.isEmpty }.max {
                $0.events.count < $1.events.count
            }?.project ?? ""
            return SessionUsage(sessionID: id, provider: provider, project: project,
                                tokens: tokens, lastActivity: last, isService: service,
                                entrypoint: logs.lazy.compactMap(\.entrypoint).first)
        }
        return (sessions, Array(days.values), fableEstimateUSD)
    }
}
