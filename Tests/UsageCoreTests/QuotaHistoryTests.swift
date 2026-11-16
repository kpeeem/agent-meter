import Foundation
import XCTest
@testable import UsageCore

final class QuotaHistoryTests: XCTestCase {
    func testRecordsChangesAndThinsRepeatsAndDropsOldSamples() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func result(_ used: Double, at date: Date) throws -> ScanResult {
            var result = ScanResult()
            result.claudeQuotas = [try XCTUnwrap(Quota(window: .fiveHours, used: used, observedAt: date,
                                                       resetEpoch: now.timeIntervalSince1970 + 3600))]
            return result
        }
        let old = QuotaSample(series: .codexWeek, used: 5, at: now.addingTimeInterval(-15 * 86_400))
        var history = QuotaHistory.record(try result(10, at: now.addingTimeInterval(-900)), into: [old], now: now)
        XCTAssertEqual(history.map(\.used), [10])
        history = QuotaHistory.record(try result(10.4, at: now.addingTimeInterval(-600)), into: history, now: now)
        XCTAssertEqual(history.count, 1)
        history = QuotaHistory.record(try result(12, at: now.addingTimeInterval(-300)), into: history, now: now)
        history = QuotaHistory.record(try result(12, at: now.addingTimeInterval(-300)), into: history, now: now)
        XCTAssertEqual(history.map(\.used), [10, 12])
        XCTAssertEqual(history.last?.series, .claudeFiveHours)
    }
}
