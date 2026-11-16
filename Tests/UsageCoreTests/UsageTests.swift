import Foundation
import XCTest
@testable import UsageCore

final class UsageTests: XCTestCase {
    func testClaudeKeepsOneUsageSnapshotPerMessageAndSkipsSymlinks() async throws {
        let folder = try temporaryFolder(.claudeProjects)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let session = "f3e20301-8e34-4be3-aa52-79396d725025"
        let log = folder.appendingPathComponent("\(session).jsonl")
        func record(id: String, at time: String, output: Int) -> String {
            """
            {"type":"assistant","timestamp":"\(time)","sessionId":"\(session)","cwd":"/work/local","message":{"id":"\(id)","usage":{"input_tokens":20,"cache_read_input_tokens":40,"cache_creation_input_tokens":10,"output_tokens":\(output)}}}
            """
        }
        let current = "2026-11-10T09:10:00Z"
        let content = [record(id: "old", at: "2026-11-01T09:10:00Z", output: 8),
                       record(id: "same", at: current, output: 3),
                       record(id: "same", at: current, output: 9),
                       record(id: "another", at: current, output: 5),
                       record(id: "prior", at: "2026-11-09T09:10:00Z", output: 7),
                       "{incomplete"].joined(separator: "\n")
        try Data(content.utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: try date("2026-11-10T09:30:00Z")],
                                              ofItemAtPath: log.path)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("untrusted.jsonl"), withDestinationURL: log)

        let result = await UsageScanner().scan([.claudeProjects: folder], days: 7,
                                               now: try date("2026-11-10T10:00:00Z"))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.tokens, Tokens(input: 60, cached: 120, cacheWrite: 30, output: 21))
        let daily = result.dailyUsage.sorted { $0.date < $1.date }
        XCTAssertEqual(daily.map { $0.tokens.total }, [77, 154])
        XCTAssertEqual(daily.map(\.sessions), [1, 1])
        XCTAssertEqual(result.projects(for: .claude).first?.path, "/work/local")
        XCTAssertEqual(result.skippedFiles, 0)
    }

    func testCodexCountsDeltasAndKeepsQuotaOnlyUpdates() async throws {
        let folder = try temporaryFolder(.codexSessions)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let log = folder.appendingPathComponent("rollout-sample.jsonl")
        let content = """
        {"type":"session_meta","payload":{"id":"4086eaf5-24b8-435a-9b7e-00044f635522","cwd":"/work/shared"}}
        {"type":"event_msg","timestamp":"2026-11-01T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":5}}}}
        {"type":"event_msg","timestamp":"2026-11-10T09:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":50,"output_tokens":15}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":33,"window_minutes":300,"resets_at":1794312000},"secondary":{"used_percent":78,"window_minutes":10080}}}}
        {"type":"event_msg","timestamp":"2026-11-10T09:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":50,"output_tokens":15}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":34,"window_minutes":300,"resets_at":1794312000}}}}
        {"type":"event_msg","timestamp":"2026-11-10T09:08:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"other","primary":{"used_percent":100,"window_minutes":300}}}}
        """
        try Data(content.utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: try date("2026-11-10T09:30:00Z")],
                                              ofItemAtPath: log.path)

        let result = await UsageScanner().scan([.codexSessions: folder], days: 7,
                                               now: try date("2026-11-10T10:00:00Z"))
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.tokens, Tokens(input: 30, cached: 20, output: 10))
        XCTAssertEqual(result.codexQuotas.map(\.used), [34, 78])
        XCTAssertEqual(session.provider.sessionURL(session.sessionID)?.absoluteString,
                       "codex://threads/4086eaf5-24b8-435a-9b7e-00044f635522")
    }

    func testForkedCodexThreadDoesNotRecountTheParentTotal() async throws {
        let folder = try temporaryFolder(.codexSessions)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let log = folder.appendingPathComponent("rollout-fork.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"5086eaf5-24b8-435a-9b7e-00044f635522","cwd":"/work/fork"}}
        {"type":"event_msg","timestamp":"2026-11-10T09:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"output_tokens":900},"last_token_usage":{"input_tokens":120,"cached_input_tokens":100,"output_tokens":7}}}}
        {"type":"event_msg","timestamp":"2026-11-10T09:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10200,"cached_input_tokens":8150,"output_tokens":910},"last_token_usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":10}}}}
        """.utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: try date("2026-11-10T09:30:00Z")], ofItemAtPath: log.path)
        let result = await UsageScanner().scan([.codexSessions: folder], days: 7, now: try date("2026-11-10T10:00:00Z"))
        XCTAssertEqual(result.sessions.first?.tokens, Tokens(input: 70, cached: 250, output: 17))
    }

    func testClaudeQuotaCapturePersistsOnlyQuotaFields() async throws {
        let folder = try temporaryFolder(.claudeProjects)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let now = try date("2026-11-10T10:00:00Z")
        let input = Data("""
        {"session_id":"sensitive-id","workspace":{"current_dir":"/private/work"},
         "rate_limits":{"five_hour":{"used_percentage":77,"resets_at":1794312000},"seven_day":{"used_percentage":89}}}
        """.utf8)
        let quotas = try ClaudeQuota.capture(input, at: now)
        try ClaudeQuota.store(quotas, in: folder)
        let output = try Data(contentsOf: folder.appendingPathComponent(ClaudeQuota.fileName))
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("sensitive-id"))
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("/private/work"))
        let snapshot = ClaudeQuota.read(in: folder, now: now)
        XCTAssertEqual(snapshot.quotas.map(\.used), [77, 89])
        XCTAssertNil(snapshot.fable)
        XCTAssertTrue(quotas[0].isStale(at: now.addingTimeInterval(7 * 3600)))
        XCTAssertEqual(try ClaudeQuota.capture(Data("{}".utf8)), [])
    }

    func testDesktopQuotaUsesLatestLocalSampleAndDefersToStatusLine() async throws {
        let folder = try temporaryFolder(.claudeProjects)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let now = try date("2026-11-10T10:00:00Z")
        let history = folder.deletingLastPathComponent().appendingPathComponent("plan-usage-history.json")
        let milliseconds = now.timeIntervalSince1970 * 1000
        let content = """
        {"version":2,"samples":[
          {"t":\(milliseconds - 4000),"u":{"fh":70,"sd":30}},
          {"t":\(milliseconds + 2000),"u":{"fh":99,"sd":99}},
          {"t":\(milliseconds - 1000),"u":{"fh":80,"sd":35}}
        ]}
        """
        try Data(content.utf8).write(to: history)
        let scanner = UsageScanner()
        let desktop = await scanner.scan([.claudeProjects: folder], days: 7, now: now, desktopHistory: history)
        XCTAssertTrue(desktop.claudeQuotasFromDesktop)
        XCTAssertEqual(desktop.claudeQuotas.map(\.used), [80, 35])
        XCTAssertTrue(desktop.claudeQuotas.allSatisfy { $0.resetsAt == nil })

        let snapshot = try ClaudeQuota.capture(Data("""
        {"rate_limits":{"five_hour":{"used_percentage":44}}}
        """.utf8), at: now)
        try ClaudeQuota.store(snapshot, in: folder)
        let status = await scanner.scan([.claudeProjects: folder], days: 7, now: now, desktopHistory: history)
        XCTAssertFalse(status.claudeQuotasFromDesktop)
        XCTAssertEqual(status.claudeQuotas.map(\.used), [44])
    }

    func testFableEstimateUsesDeduplicatedUsageInTheSelectedPeriod() async throws {
        let folder = try temporaryFolder(.claudeProjects)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let session = "f3e20301-8e34-4be3-aa52-79396d725025"
        let log = folder.appendingPathComponent("\(session).jsonl")
        func record(_ id: String, _ model: String, _ usage: String,
                    at time: String = "2026-11-10T09:00:00Z") -> String {
            let fields = usage.replacingOccurrences(of: "\n", with: "")
            return """
            {"type":"assistant","timestamp":"\(time)","sessionId":"\(session)","message":{"id":"\(id)","model":"\(model)","usage":\(fields)}}
            """
        }
        let content = [
            record("fable", "claude-fable-5", #"{"input_tokens":1000000,"output_tokens":1}"#),
            record("fable", "claude-fable-5", """
            {"input_tokens":1000000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":1000000,
             "cache_creation":{"ephemeral_1h_input_tokens":400000},"output_tokens":100000,
             "iterations":[{"type":"message","model":"claude-fable-5","output_tokens":100000}]}
            """),
            record("fast", "claude-fable-5-2", #"{"input_tokens":1000000,"speed":"fast","inference_geo":"us"}"#),
            record("fallback", "claude-opus-4-8", """
            {"input_tokens":1000000,"iterations":[
             {"type":"message","model":"claude-fable-5","output_tokens":100000},
             {"type":"fallback_message","model":"claude-opus-4-8","input_tokens":1000000},
             {"type":"advisor_message","model":"claude-fable-5-1","cache_read_input_tokens":1000000}]}
            """),
            record("older", "claude-fable-5-1", #"{"cache_read_input_tokens":1000000}"#, at: "2026-11-01T09:00:00Z"),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: log)
        let now = try date("2026-11-10T10:00:00Z")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)
        let scanner = UsageScanner()
        let weekly = await scanner.scan([.claudeProjects: folder], days: 7, now: now)
        XCTAssertEqual(try XCTUnwrap(weekly.fableEstimateUSD), 54.35, accuracy: 0.000_001)
        XCTAssertEqual(weekly.sessions.first?.tokens.output, 100_000)
        let monthly = await scanner.scan([.claudeProjects: folder], days: 30, now: now)
        XCTAssertEqual(try XCTUnwrap(monthly.fableEstimateUSD), 54.60, accuracy: 0.000_001)
    }

    func testClaudeStatisticsFableQuotaIsSeparateAndDated() async throws {
        let folder = try temporaryFolder(.claudeProjects)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let cache = folder.appendingPathComponent("usage-cache.json")
        let observed = try date("2026-11-10T08:00:00Z")
        let now = try date("2026-11-10T10:00:00Z")
        let resets = "2026-11-12T22:00:00+00:00"
        let content = """
        {"fetched_at":"\(now.timeIntervalSince1970)",
         "sources":{"api":{"fetched_at":"\(observed.timeIntervalSince1970)"}},"data":{"provider_buckets":[
          {"id":"another-weekly-limit","remaining_percentage":2},
          {"id":"claude-seven-day-fable","remaining_percentage":71.5,"resets_at":"\(resets)"}
        ]}}
        """
        try Data(content.utf8).write(to: cache)
        let result = await UsageScanner().scan([:], days: 7, now: now, statisticsCache: cache)
        let quota = try XCTUnwrap(result.claudeFableQuota)
        XCTAssertEqual(quota.used, 28.5)
        XCTAssertEqual(quota.observedAt, observed)
        XCTAssertEqual(quota.resetsAt, try date(resets))
        XCTAssertTrue(quota.isStale(at: try date(resets)))
        XCTAssertTrue(result.quotas(for: .claude).isEmpty)
        XCTAssertNil(result.fableEstimateUSD)
        XCTAssertNil(ClaudeQuota.readStatisticsFableQuota(cache, now: observed.addingTimeInterval(-1)))

        let alias = folder.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cache)
        XCTAssertNil(ClaudeQuota.readStatisticsFableQuota(alias, now: now))
    }

    func testClaudeCodeFableSnapshotKeepsOnlyQuotaAndMatchesAccount() async throws {
        let folder = try temporaryFolder(.claudeProjects)
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent(".claude.json")
        let oldCache = root.appendingPathComponent("usage-cache.json")
        let observed = try date("2026-11-10T08:00:00Z")
        let now = try date("2026-11-10T08:10:00Z")
        let resets = try date("2026-11-12T22:00:00Z")
        func writeState(cachedAccount: String, at date: Date, used: Double) throws {
            let content = """
            {"oauthAccount":{"accountUuid":"active-account","profile":"ignored-field"},
             "cachedUsageUtilization":{"accountUuid":"\(cachedAccount)","fetchedAtMs":\(date.timeIntervalSince1970 * 1000),
             "utilization":{"limits":[
              {"group":"weekly","percent":82,"scope":{"model":{"display_name":"Sonnet"}}},
              {"group":"daily","percent":90,"scope":{"model":{"display_name":"Fable"}}},
              {"kind":"weekly_scoped","group":"weekly","percent":\(used),"resets_at":\(resets.timeIntervalSince1970),
               "scope":{"model":{"id":null,"display_name":"Fable"}}}
             ]}}}
            """
            try Data(content.utf8).write(to: state)
        }
        try writeState(cachedAccount: "another-account", at: observed, used: 57)
        XCTAssertNil(ClaudeQuota.readCodeFableQuota(state, now: now))

        try writeState(cachedAccount: "active-account", at: observed, used: 57)
        XCTAssertNil(ClaudeQuota.readCodeFableQuota(state, now: observed.addingTimeInterval(-1)))
        let fable = try XCTUnwrap(ClaudeQuota.readCodeFableQuota(state, now: now))
        XCTAssertEqual(fable.used, 57)
        XCTAssertEqual(fable.observedAt, observed)
        XCTAssertEqual(fable.resetsAt, resets)
        let general = try ClaudeQuota.capture(Data("""
        {"rate_limits":{"seven_day":{"used_percentage":82}}}
        """.utf8), at: now)
        try ClaudeQuota.store(general, in: folder, fable: fable)
        let saved = try String(contentsOf: folder.appendingPathComponent(ClaudeQuota.fileName), encoding: .utf8)
        XCTAssertFalse(saved.contains("active-account"))
        XCTAssertFalse(saved.contains("ignored-field"))

        try Data("""
        {"fetched_at":"\(observed.timeIntervalSince1970 - 60)","data":{"provider_buckets":[
         {"id":"claude-seven-day-fable","remaining_percentage":100}
        ]}}
        """.utf8).write(to: oldCache)
        let scanner = UsageScanner()
        let first = await scanner.scan([.claudeProjects: folder], days: 7, now: now, statisticsCache: oldCache)
        XCTAssertEqual(first.claudeQuotas.map(\.used), [82])
        XCTAssertEqual(first.claudeFableQuota, fable)
        XCTAssertTrue(first.claudeFableQuotaFromCode)

        try writeState(cachedAccount: "active-account", at: now, used: 63)
        let updated = try XCTUnwrap(ClaudeQuota.readCodeFableQuota(state, now: now))
        try ClaudeQuota.store(general, in: folder, fable: updated)
        let second = await scanner.scan([.claudeProjects: folder], days: 7, now: now)
        XCTAssertEqual(second.claudeFableQuota?.used, 63)
        XCTAssertEqual(second.claudeFableQuota?.observedAt, now)
    }

    func testScannerRejectsProviderAccountRoot() async throws {
        let folder = try temporaryFolder(.codexSessions)
        let parent = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let result = await UsageScanner().scan([.codexSessions: parent], days: 7)
        XCTAssertEqual(result.unreadable, [.codexSessions])
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testCodexPluginLinksOnlyOpenDetailPages() {
        XCTAssertEqual(Provider.codexPluginURL("codex://plugins/example@openai-curated")?.absoluteString,
                       "codex://plugins/example@openai-curated")
        for invalid in ["https://plugins/example", "codex://plugins/install/example?marketplace=demo",
                        "codex://plugins/example?marketplacePath=/tmp", "codex://plugins/%2E%2E"] {
            XCTAssertNil(Provider.codexPluginURL(invalid))
        }
    }

    private func date(_ value: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(value)
    }

    private func temporaryFolder(_ source: LogSource) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(source.folder)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}
