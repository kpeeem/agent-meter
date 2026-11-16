import Foundation
import XCTest
@testable import UsageCore

final class ClaudeLiveQuotaTests: XCTestCase {
    private func write(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("quota-live.json")
        try Data(body.utf8).write(to: url)
        return url
    }

    func testReadsBothWindowsFromHeaderSnapshot() throws {
        let url = try write("""
        {"version":1,"observedAt":"2026-11-16T06:25:05.801Z","sessionId":"abc",
         "fiveHour":{"percentUsed":51,"resetsAt":"2026-11-16T09:50:00.000Z"},
         "sevenDay":{"percentUsed":20,"resetsAt":"2026-11-19T22:00:00.000Z"}}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_794_817_000)
        let quotas = ClaudeQuota.readLiveQuota(url, now: now)
        XCTAssertEqual(quotas.map(\.window), [.fiveHours, .sevenDays])
        XCTAssertEqual(quotas.first?.used, 51)
        XCTAssertEqual(quotas.first?.observedAt.timeIntervalSince1970 ?? 0, 1_794_810_305.801, accuracy: 0.01)
        XCTAssertEqual(quotas.first?.resetsAt, Date(timeIntervalSince1970: 1_794_822_600))
        XCTAssertEqual(quotas.last?.used, 20)
    }

    func testSkipsFutureReadingsUnknownVersionsAndMissingWindows() throws {
        let now = Date(timeIntervalSince1970: 1_794_817_000)
        let ahead = try write("""
        {"version":1,"observedAt":"2026-11-17T06:25:05.801Z","fiveHour":{"percentUsed":51}}
        """)
        let newer = try write("""
        {"version":2,"observedAt":"2026-11-16T06:25:05.801Z","fiveHour":{"percentUsed":51}}
        """)
        let partial = try write("""
        {"version":1,"observedAt":"2026-11-16T06:25:05.801Z","sevenDay":{"percentUsed":20}}
        """)
        defer {
            for url in [ahead, newer, partial] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        XCTAssertTrue(ClaudeQuota.readLiveQuota(ahead, now: now).isEmpty)
        XCTAssertTrue(ClaudeQuota.readLiveQuota(newer, now: now).isEmpty)
        let quotas = ClaudeQuota.readLiveQuota(partial, now: now)
        XCTAssertEqual(quotas.map(\.window), [.sevenDays])
        XCTAssertNil(quotas.first?.resetsAt)
    }

    func testScannerPrefersTheNewerReading() async throws {
        let now = Date.now
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let url = try write("""
        {"version":1,"observedAt":"\(stamp.string(from: now.addingTimeInterval(-30)))",
         "fiveHour":{"percentUsed":51},"sevenDay":{"percentUsed":20}}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects.deletingLastPathComponent()) }
        let old = try XCTUnwrap(Quota(window: .fiveHours, used: 3, observedAt: now.addingTimeInterval(-3600),
                                      resetEpoch: now.addingTimeInterval(3600).timeIntervalSince1970))
        try ClaudeQuota.store([old], in: projects)

        let result = await UsageScanner().scan([.claudeProjects: projects], days: 1, now: now, liveQuota: url)
        XCTAssertTrue(result.claudeQuotasLive)
        XCTAssertEqual(result.claudeQuotas.first { $0.window == .fiveHours }?.used, 51)
        XCTAssertEqual(result.claudeQuotas.first { $0.window == .sevenDays }?.used, 20)
    }
}
