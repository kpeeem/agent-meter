import XCTest
@testable import UsageCore

final class GrokUsageTests: XCTestCase {
    func testParsesWeeklyIncludedUsage() throws {
        let now = Date(timeIntervalSince1970: 1_794_500_000)
        let usage = GrokUsage.parse(Data("""
        {"usagePercent":21.7,"nextResetTimestampUtc":"2026-11-17T10:00:00Z","currentPeriodStart":"2026-11-10T10:00:00Z",
         "hasNonZeroIncludedLimit":true,"hasAvailableUsage":true,"grokPlanLabel":"Grok Bot Plan",
         "onDemandSettings":{"dashboardUrl":"https://example.invalid/account"}}
        """.utf8), now: now)
        XCTAssertEqual(usage.status, .ready)
        XCTAssertEqual(usage.plan, "Grok Bot Plan")
        XCTAssertEqual(usage.quota?.used ?? 0, 21.7, accuracy: 0.001)
        XCTAssertEqual(usage.quota?.window, .sevenDays)
        XCTAssertEqual(usage.quota?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z"))
        let saved = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        XCTAssertFalse(saved.contains("example.invalid"))
    }

    func testOmittedZeroAndMissingPlan() {
        let fresh = GrokUsage.parse(Data(#"{"hasNonZeroIncludedLimit":true}"#.utf8))
        XCTAssertEqual(fresh.status, .ready)
        XCTAssertEqual(fresh.quota?.used, 0)
        XCTAssertEqual(GrokUsage.parse(Data(#"{"usagePercent":0}"#.utf8)).status, .noPlan)
        XCTAssertEqual(GrokUsage.parse(Data(#"{"hasNonZeroIncludedLimit":true,"usagePercent":140}"#.utf8)).status, .unavailable)
        XCTAssertEqual(GrokUsage.parse(Data("[]".utf8)).status, .unavailable)
    }

    func testScannerReadsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grok-usage.json")
        let usage = GrokUsage.parse(Data(#"{"hasNonZeroIncludedLimit":true,"usagePercent":40}"#.utf8))
        try JSONEncoder().encode(usage).write(to: file)
        let result = await UsageScanner().scan([:], days: 7, grokUsage: file)
        XCTAssertEqual(result.grok?.quota?.used, 40)
    }
}
