import Darwin
import Foundation

public enum ClaudeQuota {
    public static let fileName = ".agent-meter-quota.json"
    public static let desktopHistoryPath = "Library/Application Support/Claude/plan-usage-history.json"
    public static let statisticsCachePath = ".claude-statistics/usage-cache.json"

    public static func capture(_ input: Data, at date: Date = .now) throws -> [Quota] {
        let line = try JSONDecoder().decode(StatusLine.self, from: input)
        return [line.rateLimits?.fiveHour?.quota(.fiveHours, date),
                line.rateLimits?.sevenDay?.quota(.sevenDays, date)].compactMap { $0 }
    }

    public static func captureFable(in projects: URL, at date: Date = .now) -> Quota? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stateDirectory: URL
        let configDirectory: URL
        if let override = getenv("CLAUDE_CONFIG_DIR").flatMap({ String(validatingUTF8: $0) }), !override.isEmpty {
            guard override.hasPrefix("/") else { return nil }
            configDirectory = URL(fileURLWithPath: override, isDirectory: true)
            stateDirectory = configDirectory
        } else {
            stateDirectory = home
            configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        }
        let configuredProjects = configDirectory.appendingPathComponent(LogSource.claudeProjects.folder)
        guard projects.standardizedFileURL.path == configuredProjects.standardizedFileURL.path else { return nil }
        return readCodeFableQuota(stateDirectory.appendingPathComponent(".claude.json"), now: date)
    }

    public static func store(_ quotas: [Quota], in folder: URL, fable: Quota? = nil) throws {
        guard folder.lastPathComponent == LogSource.claudeProjects.folder else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !quotas.isEmpty || fable != nil else { return }
        let encoder = JSONEncoder()
        let bytes = try fable.map { try encoder.encode(Snapshot(quotas: quotas, fable: $0)) }
            ?? encoder.encode(quotas)
        var path = Array(folder.appendingPathComponent(".agent-meter-quota.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let temporary = String(cString: path)
        defer { unlink(temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: bytes)
        try file.close()
        let destination = folder.appendingPathComponent(fileName).path
        guard rename(temporary, destination) == 0 else { throw POSIXError(.EIO) }
    }

    static func readCodeFableQuota(_ url: URL, now: Date) -> Quota? {
        let maximumSize = 8 * 1024 * 1024
        guard let file = try? openLog(url), let bytes = try? file.read(upToCount: maximumSize + 1),
              bytes.count <= maximumSize,
              let state = try? JSONDecoder().decode(CodeState.self, from: bytes),
              let cache = state.cachedUsageUtilization, cache.accountUuid == state.oauthAccount?.accountUuid,
              cache.fetchedAtMs.isFinite, cache.fetchedAtMs > 0 else { return nil }
        let observedAt = Date(timeIntervalSince1970: cache.fetchedAtMs / 1000)
        guard observedAt <= now else { return nil }
        return cache.utilization.limits?.lazy.compactMap { limit -> Quota? in
            guard limit.group == "weekly" || limit.kind == "weekly_scoped",
                  limit.scope?.model?.displayName?.localizedCaseInsensitiveContains("fable") == true,
                  let percent = limit.percent else { return nil }
            return Quota(window: .sevenDays, used: percent, observedAt: observedAt,
                         resetEpoch: limit.resetsAt?.epoch)
        }.first
    }

    static func readDesktopHistory(_ url: URL, now: Date) -> [Quota] {
        let maximumSize = 1024 * 1024
        guard let file = try? openLog(url), let bytes = try? file.read(upToCount: maximumSize + 1),
              bytes.count <= maximumSize,
              let history = try? JSONDecoder().decode(DesktopHistory.self, from: bytes),
              [1, 2].contains(history.version) else { return [] }

        return history.samples.lazy.compactMap { sample -> [Quota]? in
            guard sample.time.isFinite, sample.time > 0 else { return nil }
            let date = Date(timeIntervalSince1970: sample.time / 1000)
            guard date <= now else { return nil }
            let usage = history.version == 2 ? sample.usage : sample.flatUsage
            guard let usage else { return nil }
            let quotas = [(QuotaWindow.fiveHours, usage.fiveHour), (.sevenDays, usage.sevenDay)].compactMap {
                window, used in used.flatMap { Quota(window: window, used: $0, observedAt: date, resetEpoch: nil) }
            }
            return quotas.isEmpty ? nil : quotas
        }.max { ($0.first?.observedAt ?? .distantPast) < ($1.first?.observedAt ?? .distantPast) } ?? []
    }

    static func readStatisticsFableQuota(_ url: URL, now: Date) -> Quota? {
        guard let (cache, observedAt) = readStatistics(url, now: now),
              let bucket = cache.data.buckets?.first(where: { $0.id == "claude-seven-day-fable" }) else { return nil }
        return Quota(window: .sevenDays, used: 100 - bucket.remaining, observedAt: observedAt,
                     resetEpoch: timestamp(bucket.resetsAt)?.timeIntervalSince1970)
    }

    static func readStatisticsModelQuotas(_ url: URL, now: Date) -> [ModelQuota] {
        guard let (cache, observedAt) = readStatistics(url, now: now) else { return [] }
        return [("Opus", cache.data.opus), ("Sonnet", cache.data.sonnet)].compactMap { name, window in
            guard let window, let used = window.utilization else { return nil }
            return ModelQuota(name: name, quota: Quota(window: .sevenDays, used: used, observedAt: observedAt,
                                                       resetEpoch: timestamp(window.resetsAt)?.timeIntervalSince1970))
        }
    }

    private static func readStatistics(_ url: URL, now: Date) -> (StatisticsCache, Date)? {
        let maximumSize = 64 * 1024
        guard let file = try? openLog(url), let bytes = try? file.read(upToCount: maximumSize + 1),
              bytes.count <= maximumSize,
              let cache = try? JSONDecoder().decode(StatisticsCache.self, from: bytes),
              let fetchedAt = Double(cache.sources?.api?.fetchedAt ?? cache.fetchedAt),
              fetchedAt.isFinite, fetchedAt > 0 else { return nil }
        let observedAt = Date(timeIntervalSince1970: fetchedAt)
        return observedAt <= now ? (cache, observedAt) : nil
    }

    struct Snapshot: Codable {
        let quotas: [Quota]
        let fable: Quota?
    }

    static func read(in folder: URL, now: Date) -> Snapshot {
        let url = folder.appendingPathComponent(fileName)
        guard let file = try? openLog(url), let bytes = try? file.read(upToCount: 4097),
              bytes.count <= 4096 else { return Snapshot(quotas: [], fable: nil) }
        let decoder = JSONDecoder()
        let snapshot = (try? decoder.decode(Snapshot.self, from: bytes))
            ?? Snapshot(quotas: (try? decoder.decode([Quota].self, from: bytes)) ?? [], fable: nil)
        let quotas = QuotaWindow.allCases.compactMap { window in
            snapshot.quotas.filter { $0.window == window && (0...100).contains($0.used) }
                .max { $0.observedAt < $1.observedAt }
        }
        let fable = snapshot.fable.flatMap { quota in
            quota.window == .sevenDays && (0...100).contains(quota.used) && quota.observedAt <= now ? quota : nil
        }
        return Snapshot(quotas: quotas, fable: fable)
    }
}

private struct CodeState: Decodable {
    let oauthAccount: Account?
    let cachedUsageUtilization: Cache?

    struct Account: Decodable {
        let accountUuid: String?
    }

    struct Cache: Decodable {
        let accountUuid: String?
        let fetchedAtMs: Double
        let utilization: Usage
    }

    struct Usage: Decodable {
        let limits: [Limit]?
    }

    struct Limit: Decodable {
        let group: String?
        let kind: String?
        let percent: Double?
        let scope: Scope?
        let resetsAt: Reset?

        enum CodingKeys: String, CodingKey { case group, kind, percent, scope, resetsAt = "resets_at" }
    }

    struct Scope: Decodable {
        let model: Model?
    }

    struct Model: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    struct Reset: Decodable {
        let epoch: Double?

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            epoch = (try? value.decode(Double.self))
                ?? timestamp(try? value.decode(String.self))?.timeIntervalSince1970
        }
    }
}

private struct StatisticsCache: Decodable {
    let data: Usage
    let fetchedAt: String
    let sources: Sources?

    enum CodingKeys: String, CodingKey { case data, sources, fetchedAt = "fetched_at" }

    struct Sources: Decodable {
        let api: API?
    }

    struct API: Decodable {
        let fetchedAt: String

        enum CodingKeys: String, CodingKey { case fetchedAt = "fetched_at" }
    }

    struct Usage: Decodable {
        let buckets: [Bucket]?
        let opus: Window?
        let sonnet: Window?

        enum CodingKeys: String, CodingKey {
            case buckets = "provider_buckets", opus = "seven_day_opus", sonnet = "seven_day_sonnet"
        }
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey { case utilization, resetsAt = "resets_at" }
    }

    struct Bucket: Decodable {
        let id: String
        let remaining: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case id, remaining = "remaining_percentage", resetsAt = "resets_at"
        }
    }
}

private struct StatusLine: Decodable {
    let rateLimits: Limits?

    enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }

    struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour", sevenDay = "seven_day"
        }
    }

    struct Window: Decodable {
        let used: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case used = "used_percentage", resetsAt = "resets_at"
        }

        func quota(_ window: QuotaWindow, _ date: Date) -> Quota? {
            used.flatMap { Quota(window: window, used: $0, observedAt: date, resetEpoch: resetsAt) }
        }
    }
}


private struct DesktopHistory: Decodable {
    let version: Int
    let samples: [Sample]

    struct Sample: Decodable {
        let time: Double
        let usage: Usage?
        let flatUsage: Usage

        enum CodingKeys: String, CodingKey { case time = "t", usage = "u" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            time = try values.decode(Double.self, forKey: .time)
            usage = try values.decodeIfPresent(Usage.self, forKey: .usage)
            flatUsage = try Usage(from: decoder)
        }
    }

    struct Usage: Decodable {
        let fiveHour: Double?
        let sevenDay: Double?

        enum CodingKeys: String, CodingKey { case fiveHour = "fh", sevenDay = "sd" }
    }
}
