import Foundation
import XCTest
@testable import UsageCore

final class CodexLiveUsageTests: XCTestCase {
    func testParsesWindowsByLengthAndKeepsLastLimitsWhenThrottled() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let usage = CodexLiveUsage.parse(Data("""
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":{"used_percent":99,"limit_window_seconds":604800,"reset_after_seconds":100,"reset_at":1794738121},
         "secondary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1794010000}},"credits":null,
         "rate_limit_reset_credits":{"available_count":1,"applicable_available_count":0}}
        """.utf8), now: now)
        XCTAssertEqual(usage.status, .ready)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.resets, 1)
        XCTAssertEqual(usage.usableResets, 0)
        XCTAssertEqual(usage.quotas.map(\.window), [.sevenDays, .fiveHours])
        XCTAssertEqual(usage.quotas.first?.resetsAt, Date(timeIntervalSince1970: 1_794_738_121))

        var throttled = CodexLiveUsage(status: .throttled, attemptedAt: now.addingTimeInterval(300))
        throttled.keep(usage)
        XCTAssertEqual(throttled.quotas, usage.quotas)
        XCTAssertEqual(throttled.resets, 1)
        XCTAssertTrue(throttled.waiting(at: now.addingTimeInterval(600)))
        XCTAssertFalse(throttled.waiting(at: now.addingTimeInterval(300 + 3600)))
        XCTAssertEqual(CodexLiveUsage.parse(Data(#"{"rate_limit":null}"#.utf8)).status, .unavailable)
    }

    func testScannerPrefersNewerLiveLimits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let quota = try XCTUnwrap(Quota(window: .sevenDays, used: 99, observedAt: now.addingTimeInterval(-60),
                                        resetEpoch: now.timeIntervalSince1970 + 86_400))
        let url = root.appendingPathComponent("codex-usage.json")
        try JSONEncoder().encode(CodexLiveUsage(status: .ready, attemptedAt: now.addingTimeInterval(-60),
                                                quotas: [quota], plan: "Pro")).write(to: url)
        let result = await UsageScanner().scan([:], days: 7, now: now, codexUsage: url)
        XCTAssertEqual(result.codexQuotas, [quota])
        XCTAssertTrue(result.codexQuotasLive)
        XCTAssertEqual(result.codexLive?.plan, "Pro")
    }
}
