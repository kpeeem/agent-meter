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

    func testModelWindowsComeFromTheStatisticsCacheWithoutItsFable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let cache = root.appendingPathComponent("usage-cache.json")
        try Data("""
        {"fetched_at":"\(Int(now.timeIntervalSince1970) - 600)","data":{"seven_day_sonnet":{"utilization":30},
         "seven_day_opus":{"utilization":20,"resets_at":"2026-11-13T22:00:00Z"}}}
        """.utf8).write(to: cache)
        let result = await UsageScanner().scan([:], days: 7, now: now, statisticsCache: cache)
        XCTAssertEqual(result.claudeModelQuotas.map(\.name), ["Opus", "Sonnet"])
        XCTAssertEqual(result.claudeModelQuotas.map(\.quota.used), [20, 30])
        XCTAssertNil(result.claudeFableQuota)
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
