import Foundation
import XCTest
@testable import UsageCore

final class ServiceUsageTests: XCTestCase {
    func testZaiSeparatesCodingWindowsFromMCPAndUsesCounts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let input = Data("""
        {"code":200,"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":42,"nextResetTime":1800036000000},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":0,"usage":1000,"currentValue":125},
          {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":0,"usage":1000,"remaining":750},
          {"type":"UNKNOWN_LIMIT","percentage":90}
        ]}}
        """.utf8)
        let result = try ServiceUsageParser.parse(input, account: .zai, now: now)
        XCTAssertEqual(result.windows.map(\.title), ["5-hour rolling", "7-day rolling", "MCP"])
        XCTAssertEqual(result.windows.map(\.usedPercent), [42, 12.5, 25])
        XCTAssertNil(result.windows[0].resetsAt)
        XCTAssertThrowsError(try ServiceUsageParser.parse(Data(#"{"code":200,"data":{"limits":[]}}"#.utf8), account: .zai))
        XCTAssertThrowsError(try ServiceUsageParser.parse(Data(#"{"code":401,"data":{"limits":[]}}"#.utf8), account: .zai))
    }

    func testKimiRatioPoolsTakePrecedenceAndMonthlyCodeIsABreakdown() throws {
        let input = Data("""
        {"usages":{
           "limit_5h":{"used_ratio":0.25,"reset_time":"2026-11-11T12:00:00.716839300Z"},
           "limit_7d":{"used_ratio":0,"reset_time":"2026-11-14T12:00:00Z"},
           "limit_month_total":{"used_ratio":0.8},
           "limit_month_code":{"used_ratio":0.5}},
         "usage":{"limit":"1000","used":"450"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"200","used":"139"}}]}
        """.utf8)
        let result = try ServiceUsageParser.parse(input, account: .kimi)
        XCTAssertEqual(result.windows.map(\.usedPercent), [25, 0, 80])
        XCTAssertEqual(result.windows.map(\.title), ["5-hour rolling", "7-day rolling", "Monthly total"])
        XCTAssertNotNil(result.windows[0].resetsAt)
    }

    func testKimiLegacyCountsAndMissingQuotas() throws {
        let input = Data("""
        {"usage":{"limit":"1000","used":"214","resetTime":"2026-11-14T12:00:00Z"},
         "limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},
                    "detail":{"limit":"200","remaining":"61"}}]}
        """.utf8)
        let result = try ServiceUsageParser.parse(input, account: .kimi)
        XCTAssertEqual(result.windows.map(\.title), ["5-hour rolling", "7-day rolling"])
        XCTAssertEqual(result.windows[0].usedPercent, 69.5, accuracy: 0.0001)
        XCTAssertEqual(result.windows[1].usedPercent, 21.4, accuracy: 0.0001)
        let mixed = Data("""
        {"usages":{"limit_7d":{"used_ratio":0,"reset_time":"2026-11-14T12:00:00Z"}},
         "usage":{"limit":"1000","used":"214","resetTime":"2026-11-14T12:00:00Z"}}
        """.utf8)
        let corrected = try ServiceUsageParser.parse(mixed, account: .kimi)
        XCTAssertEqual(corrected.windows[0].usedPercent, 21.4, accuracy: 0.0001)
        XCTAssertThrowsError(try ServiceUsageParser.parse(Data("{}".utf8), account: .kimi))
        XCTAssertThrowsError(try ServiceUsageParser.parse(Data(#"{"usage":{"limit":"0","used":"0"}}"#.utf8), account: .kimi))
    }

    func testClaudeLiveUsageSanitizesTheControlResponse() throws {
        let input = Data("""
        {"rate_limits_available":true,"session":{"private":"fixture-account-data"},
         "rate_limits":{"five_hour":{"utilization":31,"resets_at":"2026-11-11T22:00:00Z"},
          "seven_day":{"utilization":82},"model_scoped":[
           {"display_name":"Fable","utilization":57,"resets_at":"2026-11-13T22:00:00Z"}]}}
        """.utf8)
        let usage = ClaudeLiveUsage.parse(input)
        XCTAssertEqual(usage.status, .ready)
        XCTAssertEqual(usage.quotas.map(\.used), [31, 82])
        XCTAssertEqual(usage.fable?.used, 57)
        let saved = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        XCTAssertFalse(saved.contains("fixture-account-data"))
        XCTAssertEqual(ClaudeLiveUsage.parse(Data(#"{"rate_limits_available":false}"#.utf8)).status, .needsLogin)
    }

    func testClaudeLiveUsageReadsSeparateModelWindows() throws {
        let input = Data("""
        {"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":10},"seven_day":{"utilization":40},
         "seven_day_opus":{"utilization":12,"resets_at":"2026-11-13T22:00:00Z"},
         "seven_day_sonnet":{"utilization":64,"resets_at":"2026-11-13T22:00:00Z"},
         "model_scoped":[{"display_name":"Fable","utilization":57},{"display_name":"Sonnet","utilization":64},
          {"display_name":"Haiku","utilization":null}]}}
        """.utf8)
        let usage = ClaudeLiveUsage.parse(input)
        XCTAssertEqual(usage.models?.map(\.name), ["Opus", "Sonnet"])
        XCTAssertEqual(usage.models?.map(\.quota.used), [12, 64])
        XCTAssertEqual(usage.fable?.used, 57)

        let plain = ClaudeLiveUsage.parse(Data("""
        {"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":10},"seven_day":{"utilization":40},
         "seven_day_opus":null,"seven_day_sonnet":null}}
        """.utf8))
        XCTAssertEqual(plain.status, .ready)
        XCTAssertEqual(plain.models, [])
    }

    func testClaudeLiveUsageReportsThrottledLimitsRequest() throws {
        let usage = ClaudeLiveUsage.parse(Data(#"{"rate_limits_available":true,"rate_limits":null}"#.utf8))
        XCTAssertEqual(usage.status, .throttled)
        XCTAssertTrue(usage.message().contains("Sign in for Agent Meter"))
        var separate = usage
        separate.separateSignIn = true
        XCTAssertTrue(separate.message().hasPrefix("Claude rate-limited the limits request (429). Next try at"))
        let old = Data(#"{"quotas":[],"attemptedAt":816179526,"status":"unavailable"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ClaudeLiveUsage.self, from: old).models)
    }

    func testThrottledRefreshWaitsAnHourAndKeepsTheLastLimits() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = Quota(window: .fiveHours, used: 40, observedAt: start, resetEpoch: start.timeIntervalSince1970 + 3600)!
        let ready = ClaudeLiveUsage(status: .ready, attemptedAt: start, quotas: [quota], separateSignIn: true)
        var first = ClaudeLiveUsage(status: .throttled, attemptedAt: start.addingTimeInterval(300), separateSignIn: true)
        first.keep(ready)
        XCTAssertEqual(first.quotas, [quota])
        XCTAssertEqual(first.retryAt, start.addingTimeInterval(300 + 3600))
        XCTAssertTrue(first.waiting(at: start.addingTimeInterval(600)))
        XCTAssertFalse(first.waiting(at: start.addingTimeInterval(3901)))
        XCTAssertFalse(first.message(at: start.addingTimeInterval(600)).contains("sign in"))
        XCTAssertTrue(first.message(at: start.addingTimeInterval(600))
            .contains("Showing limits from " + start.formatted(.dateTime.hour().minute())))

        var later = ClaudeLiveUsage(status: .throttled, attemptedAt: start.addingTimeInterval(7500), separateSignIn: true)
        later.keep(first)
        XCTAssertEqual(later.throttledSince, start.addingTimeInterval(300))
        XCTAssertTrue(later.message(at: start.addingTimeInterval(7500)).contains("sign in for Agent Meter again"))

        var expired = ClaudeLiveUsage(status: .needsLogin, attemptedAt: start.addingTimeInterval(7800), separateSignIn: true)
        expired.keep(later)
        XCTAssertEqual(expired.quotas, [quota])
        XCTAssertNil(expired.retryAt)
        XCTAssertFalse(expired.waiting(at: start.addingTimeInterval(7900)))
        XCTAssertTrue(expired.message().contains("sign-in expired"))
    }

    func testModelWindowsMergeNewestAndSkipTheStatisticsFable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let cache = root.appendingPathComponent("usage-cache.json")
        try Data("""
        {"fetched_at":"\(Int(now.timeIntervalSince1970) - 600)","data":{"seven_day_opus":{"utilization":20},
         "seven_day_sonnet":{"utilization":30,"resets_at":"2026-11-13T22:00:00Z"}}}
        """.utf8).write(to: cache)
        let input = Data("""
        {"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":40},
         "seven_day_sonnet":{"utilization":35}}}
        """.utf8)
        let file = root.appendingPathComponent("claude-usage.json")
        try JSONEncoder().encode(ClaudeLiveUsage.parse(input, now: now.addingTimeInterval(-60))).write(to: file)
        let result = await UsageScanner().scan([:], days: 7, now: now, statisticsCache: cache, automaticClaude: file)
        XCTAssertEqual(result.claudeModelQuotas.map(\.name), ["Opus", "Sonnet"])
        XCTAssertEqual(result.claudeModelQuotas.map(\.quota.used), [20, 35])
        XCTAssertNil(result.claudeFableQuota)
    }

    func testAutomaticClaudeSnapshotReplacesOlderLocalQuotas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let old = try ClaudeQuota.capture(Data(#"{"rate_limits":{"five_hour":{"used_percentage":90}}}"#.utf8),
                                          at: now.addingTimeInterval(-3600))
        try ClaudeQuota.store(old, in: projects)
        let input = Data("""
        {"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":31},
         "seven_day":{"utilization":82},"model_scoped":[{"display_name":"Fable","utilization":57}]}}
        """.utf8)
        let live = ClaudeLiveUsage.parse(input, now: now)
        let file = root.appendingPathComponent("claude-usage.json")
        try JSONEncoder().encode(live).write(to: file)
        let result = await UsageScanner().scan([.claudeProjects: projects], days: 7, now: now, automaticClaude: file)
        XCTAssertEqual(result.claudeQuotas.map(\.used), [31, 82])
        XCTAssertEqual(result.claudeFableQuota?.used, 57)
        XCTAssertTrue(result.claudeQuotasAutomatic)
        XCTAssertTrue(result.claudeFableQuotaAutomatic)
    }

    func testFresherDesktopCacheKeepsAutomaticResetTimes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let fiveReset = Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970)
        let weekReset = Int(now.addingTimeInterval(13 * 3600).timeIntervalSince1970)
        let input = Data("""
        {"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":2,"resets_at":"\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(fiveReset))))"},
         "seven_day":{"utilization":97,"resets_at":"\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(weekReset))))"}}}
        """.utf8)
        let live = ClaudeLiveUsage.parse(input, now: now.addingTimeInterval(-60))
        let file = root.appendingPathComponent("claude-usage.json")
        try JSONEncoder().encode(live).write(to: file)
        let history = root.appendingPathComponent("plan-usage-history.json")
        let milliseconds = now.timeIntervalSince1970 * 1000
        try Data(#"{"version":2,"samples":[{"t":\#(milliseconds - 1000),"u":{"fh":3,"sd":97}}]}"#.utf8).write(to: history)

        let result = await UsageScanner().scan([.claudeProjects: projects], days: 7, now: now,
                                               desktopHistory: history, automaticClaude: file)
        XCTAssertEqual(result.claudeQuotas.map(\.used), [2, 97])
        XCTAssertEqual(result.claudeQuotas.compactMap(\.resetsAt).map { Int($0.timeIntervalSince1970) },
                       [fiveReset, weekReset])
        XCTAssertTrue(result.claudeQuotasAutomatic)
        XCTAssertFalse(result.claudeQuotasFromDesktop)

        let stale = ClaudeLiveUsage.parse(input, now: now.addingTimeInterval(-40 * 60))
        try JSONEncoder().encode(stale).write(to: file)
        let carried = await UsageScanner().scan([.claudeProjects: projects], days: 7, now: now,
                                                desktopHistory: history, automaticClaude: file)
        XCTAssertEqual(carried.claudeQuotas.map(\.used), [3, 97])
        XCTAssertTrue(carried.claudeQuotasFromDesktop)
        XCTAssertEqual(carried.claudeQuotas.compactMap(\.resetsAt).count, 2)
    }

    func testExhaustionProjectionMatchesLinearRate() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fast = try XCTUnwrap(Quota(window: .fiveHours, used: 60, observedAt: now,
                                       resetEpoch: now.addingTimeInterval(3 * 3600).timeIntervalSince1970))
        let exhaustion = try XCTUnwrap(fast.projectedExhaustion(at: now))
        XCTAssertEqual(exhaustion.timeIntervalSince(now), 4800, accuracy: 1)
        let slow = try XCTUnwrap(Quota(window: .fiveHours, used: 20, observedAt: now,
                                       resetEpoch: now.addingTimeInterval(3 * 3600).timeIntervalSince1970))
        XCTAssertNil(slow.projectedExhaustion(at: now))
        let early = try XCTUnwrap(Quota(window: .sevenDays, used: 40, observedAt: now,
                                        resetEpoch: now.addingTimeInterval(6.5 * 86_400).timeIntervalSince1970))
        XCTAssertNil(early.projectedExhaustion(at: now), "Weekly projection waits for a full day of data")
        let week = try XCTUnwrap(Quota(window: .sevenDays, used: 97, observedAt: now,
                                       resetEpoch: now.addingTimeInterval(3 * 86_400).timeIntervalSince1970))
        XCTAssertNotNil(week.projectedExhaustion(at: now))
        let codex = try XCTUnwrap(Quota(window: .sevenDays, used: 98, observedAt: now,
                                        resetEpoch: now.addingTimeInterval(2.75 * 86_400).timeIntervalSince1970))
        XCTAssertNotNil(codex.projectedExhaustion(at: now))
        XCTAssertNil(codex.projectedExhaustion(at: now.addingTimeInterval(2.5 * 3600)),
                     "An old observation must not claim the limit runs out right now")
    }
}
