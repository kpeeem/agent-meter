import Foundation
import XCTest
@testable import UsageCore

final class BackgroundWorkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ lines: [String]) throws -> (URL, Int) {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: url)
        return (url, data.count)
    }

    private func codex(_ name: String, source: String, thread: String? = nil, turn: String = "t1",
                       tokens: Int = 500) throws -> ParsedLog? {
        let id = UUID().uuidString.lowercased()
        let threadField = thread.map { #","thread_source":"\#($0)""# } ?? ""
        let (url, size) = try write(name, [
            #"{"timestamp":"2026-11-17T04:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/P","source":\#(source)\#(threadField)}}"#,
            #"{"timestamp":"2026-11-17T04:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turn)"}}"#,
            #"{"timestamp":"2026-11-17T04:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(tokens),"output_tokens":10}}}}"#,
            #"{"timestamp":"2026-11-17T04:00:03.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ])
        return try Parsers.codex(url, size: size)
    }

    func testCodexThreadsAreSortedByWhoStartedThem() throws {
        XCTAssertEqual(try codex("a.jsonl", source: #""vscode""#, thread: "user")?.origin, .interactive)
        let guardian = try codex("b.jsonl", source: #"{"subagent":{"other":"guardian"}}"#, thread: "guardian_review")
        XCTAssertEqual(guardian?.origin, .codexGuardian)
        XCTAssertEqual(guardian?.isService, true)
        XCTAssertEqual(guardian?.notchActivity?.origin, .codexGuardian)
        let spawn = #"{"subagent":{"thread_spawn":{"parent_thread_id":"x","depth":1}}}"#
        XCTAssertEqual(try codex("c.jsonl", source: spawn, thread: "subagent")?.origin, .codexSubagent)
        XCTAssertEqual(try codex("d.jsonl", source: #""exec""#)?.origin, .codexScripted)
        XCTAssertEqual(try codex("e.jsonl", source: #""mcp""#)?.origin, .codexService)
    }

    func testImportedClaudeTranscriptsShowAsOneNotchRow() throws {
        let imported = try codex("f.jsonl", source: #""vscode""#, turn: "external-import-turn-1", tokens: 0)
        XCTAssertEqual(imported?.origin, .codexImported)
        XCTAssertEqual(imported?.isService, true)
        XCTAssertNil(imported?.notchActivity)
        XCTAssertNotNil(imported?.lastActivity)
    }

    func testScannerShowsGhostThreadsAndOneImportRow() async throws {
        let sessions = root.appendingPathComponent("sessions")
        let now = Date.now
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        for (index, source) in [#""vscode""#, #""vscode""#, #"{"subagent":{"other":"guardian"}}"#].enumerated() {
            let id = UUID().uuidString.lowercased()
            let turn = index < 2 ? "external-import-turn-1" : "t1"
            let thread = index == 2 ? #","thread_source":"guardian_review""# : ""
            let lines = [
                #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/P","source":\#(source)\#(thread)}}"#,
                #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turn)"}}"#,
                #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(index < 2 ? 0 : 900),"output_tokens":0}}}}"#,
            ]
            _ = try write("sessions/2026/11/17/rollout-\(index)-\(id).jsonl", lines)
        }
        let result = await UsageScanner().scan([.codexSessions: sessions], days: 7, now: now)
        let origins = result.notchActivities.compactMap(\.origin).sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(origins, [.codexGuardian, .codexImported])
        XCTAssertEqual(result.notchActivities.first { $0.origin == .codexImported }?.message,
                       "Imported 2 Claude Code sessions into Codex")
        XCTAssertEqual(Set(result.background.map(\.origin)), [.codexGuardian, .codexImported])
    }

    func testClaudeSubagentsAndScriptedRunsAreCountedSeparately() throws {
        func claude(_ name: String, entrypoint: String) throws -> ParsedLog? {
            let (url, size) = try write(name, [
                #"{"type":"assistant","timestamp":"2026-11-17T04:00:00.000Z","sessionId":"6f1c2a52-0d3e-4e3a-9a57-1f6f1b8f3d11","cwd":"/tmp/P","entrypoint":"\#(entrypoint)","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":20}}}"#,
            ])
            return try Parsers.claude(url, size: size)
        }
        XCTAssertEqual(try claude("s/6f1c2a52-0d3e-4e3a-9a57-1f6f1b8f3d11.jsonl", entrypoint: "claude-desktop")?.origin, .interactive)
        XCTAssertEqual(try claude("s/x/subagents/agent-1.jsonl", entrypoint: "claude-desktop")?.origin, .claudeSubagent)
        let scripted = try claude("t/run.jsonl", entrypoint: "sdk-cli")
        XCTAssertEqual(scripted?.origin, .claudeScripted)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-17T05:00:00Z"))
        let guardian = try XCTUnwrap(try codex("g.jsonl", source: #""x""#, thread: "guardian_review"))
        let usage = BackgroundUsage.collect([try XCTUnwrap(scripted), guardian, guardian],
                                            from: now.addingTimeInterval(-86_400), to: now)
        XCTAssertEqual(usage.map(\.origin), [.codexGuardian, .claudeScripted])
        XCTAssertEqual(usage.first?.runs, 2)
        XCTAssertEqual(usage.first?.tokens.total, 1020)
    }
}
