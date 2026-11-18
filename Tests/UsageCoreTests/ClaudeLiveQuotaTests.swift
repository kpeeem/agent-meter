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
        let quotas = ClaudeQuota.readLiveQuota(url, now: now).quotas
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
        XCTAssertTrue(ClaudeQuota.readLiveQuota(ahead, now: now).quotas.isEmpty)
        XCTAssertTrue(ClaudeQuota.readLiveQuota(newer, now: now).quotas.isEmpty)
        let quotas = ClaudeQuota.readLiveQuota(partial, now: now).quotas
        XCTAssertEqual(quotas.map(\.window), [.sevenDays])
        XCTAssertNil(quotas.first?.resetsAt)
    }

    func testReadsFableWithTheTimeItWasSeen() throws {
        let url = try write("""
        {"version":1,"observedAt":"2026-11-16T06:25:05.801Z",
         "sevenDay":{"percentUsed":20,"resetsAt":"2026-11-19T22:00:00.000Z"},
         "fable":{"percentUsed":17,"resetsAt":"2026-11-19T22:00:00.000Z","observedAt":"2026-11-16T04:00:00.000Z"}}
        """)
        let unstamped = try write("""
        {"version":1,"observedAt":"2026-11-16T06:25:05.801Z","fable":{"percentUsed":17}}
        """)
        defer {
            for url in [url, unstamped] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        let now = Date(timeIntervalSince1970: 1_794_817_000)
        let fable = try XCTUnwrap(ClaudeQuota.readLiveQuota(url, now: now).fable)
        XCTAssertEqual(fable.window, .sevenDays)
        XCTAssertEqual(fable.used, 17)
        XCTAssertEqual(fable.observedAt, Date(timeIntervalSince1970: 1_794_801_600))
        XCTAssertEqual(fable.resetsAt, Date(timeIntervalSince1970: 1_795_125_600))
        XCTAssertEqual(ClaudeQuota.readLiveQuota(unstamped, now: now).fable?.observedAt.timeIntervalSince1970 ?? 0,
                       1_794_810_305.801, accuracy: 0.01)
    }

    func testScannerShowsFableFromHeadersOverAnOlderCache() async throws {
        let now = Date.now
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let url = try write("""
        {"version":1,"observedAt":"\(stamp.string(from: now.addingTimeInterval(-30)))",
         "sevenDay":{"percentUsed":44},
         "fable":{"percentUsed":17,"resetsAt":"\(stamp.string(from: now.addingTimeInterval(86_400)))",
                  "observedAt":"\(stamp.string(from: now.addingTimeInterval(-7200)))"}}
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects.deletingLastPathComponent()) }
        let cached = try XCTUnwrap(Quota(window: .sevenDays, used: 0, observedAt: now.addingTimeInterval(-86_400),
                                         resetEpoch: now.addingTimeInterval(86_400).timeIntervalSince1970))
        try ClaudeQuota.store([], in: projects, fable: cached)

        let result = await UsageScanner().scan([.claudeProjects: projects], days: 1, now: now, liveQuota: url)
        XCTAssertEqual(result.claudeFableQuota?.used, 17)
        XCTAssertTrue(result.claudeFableQuotaLive)
        XCTAssertFalse(result.claudeFableQuotaFromCode)
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
