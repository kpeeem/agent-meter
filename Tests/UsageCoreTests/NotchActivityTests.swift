import Foundation
import XCTest
@testable import UsageCore

final class NotchActivityTests: XCTestCase {
    func testHookPayloadKeepsBoundedSummaryWithoutTranscriptPath() throws {
        let session = UUID()
        let terminal = UUID()
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": session.uuidString,
            "cwd": "/tmp/Project",
            "tool_name": "Bash",
            "tool_input": ["command": "swift build\n  --configuration release"],
            "tool_response": "never-copy-this",
            "transcript_path": "/tmp/private-transcript.jsonl",
        ]
        let event = try XCTUnwrap(NotchActivity.parse(try JSONSerialization.data(withJSONObject: payload),
            provider: .claude, environment: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:" + terminal.uuidString]))
        XCTAssertEqual(event.phase, .running, "Claude asks the host first; only permission_prompt means a person waits")
        XCTAssertEqual(event.project, "Project")
        XCTAssertEqual(event.action, "Run swift build --configuration release")
        XCTAssertEqual(event.terminalID, terminal.uuidString)
        XCTAssertEqual(NotchActivity.sessionID(from: try XCTUnwrap(event.link)), event.id)
        XCTAssertNil(NotchActivity.sessionID(from: try XCTUnwrap(URL(string: event.link!.absoluteString + "?command=run"))))
        let saved = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(saved.contains("never-copy-this"))
        XCTAssertFalse(saved.contains("private-transcript"))
    }

    func testApprovalCardsOnlyWhenAPersonIsAsked() throws {
        let session = UUID().uuidString
        func parse(_ provider: Provider, _ payload: [String: Any],
                   approval: NotchTranscript.CodexApproval? = nil) throws -> NotchActivity {
            var body = payload
            body["session_id"] = session
            body["transcript_path"] = "/tmp/rollout.jsonl"
            return try XCTUnwrap(NotchActivity.parse(try JSONSerialization.data(withJSONObject: body),
                provider: provider, environment: [:], reader: .init(codexApproval: { _ in approval })))
        }
        let request: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                      "tool_input": ["command": "curl example.com"]]
        XCTAssertEqual(try parse(.codex, request, approval: .init(policy: "on-request", reviewer: "auto_review")).phase, .running)
        XCTAssertEqual(try parse(.codex, request, approval: .init(policy: "never", reviewer: "user")).phase, .running)
        XCTAssertEqual(try parse(.codex, request).phase, .running)
        let asked = try parse(.codex, request, approval: .init(policy: "on-request", reviewer: "user"))
        XCTAssertEqual(asked.phase, .permission)
        XCTAssertFalse(asked.needsApproval(at: asked.updatedAt.addingTimeInterval(1)))
        XCTAssertTrue(asked.needsApproval(at: asked.updatedAt.addingTimeInterval(3)))
        let prompt = try parse(.claude, ["hook_event_name": "Notification", "notification_type": "permission_prompt",
                                         "message": "Claude needs your permission to use Bash"])
        XCTAssertEqual(prompt.phase, .permission)
        XCTAssertTrue(prompt.needsApproval(at: prompt.updatedAt))
    }

    func testCodexApprovalReadsLatestTurnContext() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"user"}}"#,
            #"{"type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"auto_review"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let approval = try XCTUnwrap(NotchTranscript.codexApproval(path: file.path, home: folder.deletingLastPathComponent()))
        XCTAssertEqual(approval.reviewer, "auto_review")
        XCTAssertFalse(approval.asksUser)
    }

    func testCodexServiceThreadsAreHidden() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.deletingLastPathComponent()
        func rollout(_ meta: String) throws -> String {
            let file = folder.appendingPathComponent(UUID().uuidString + ".jsonl")
            try Data((meta + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"#).utf8).write(to: file)
            return file.path
        }
        let guardian = try rollout(#"{"type":"session_meta","payload":{"source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review"}}"#)
        let spawned = try rollout(#"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{}}}}}"#)
        let user = try rollout(#"{"type":"session_meta","payload":{"source":"vscode","thread_source":"user"}}"#)
        let legacy = try rollout(#"{"type":"session_meta","payload":{"source":"cli"}}"#)
        XCTAssertEqual(NotchTranscript.codexThreadVisible(path: guardian, home: home), false)
        XCTAssertEqual(NotchTranscript.codexThreadVisible(path: spawned, home: home), false)
        XCTAssertEqual(NotchTranscript.codexThreadVisible(path: user, home: home), true)
        XCTAssertEqual(NotchTranscript.codexThreadVisible(path: legacy, home: home), true)
        let stop = ["hook_event_name": "Stop", "session_id": UUID().uuidString, "transcript_path": guardian,
                    "last_assistant_message": #"{"outcome":"allow"}"#]
        let data = try JSONSerialization.data(withJSONObject: stop)
        XCTAssertNil(NotchActivity.parse(data, provider: .codex, environment: [:], reader: .files(home: home)))
        XCTAssertNotNil(NotchActivity.parse(data, provider: .codex, environment: [:]))
    }

    func testScannerKeepsServiceTokensAndMarksTheThread() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date.now
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5))
        func write(_ meta: String) throws -> UUID {
            let id = UUID()
            let lines = [
                "{\"timestamp\":\"\(stamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id.uuidString)\",\"cwd\":\"/tmp/p\",\(meta)}}",
                "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}",
                "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"output_tokens\":10}}}}",
            ]
            try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("rollout-\(id.uuidString).jsonl"))
            return id
        }
        let user = try write(#""source":"vscode","thread_source":"user""#)
        let guardian = try write(#""source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review""#)
        let result = await UsageScanner().scan([.codexSessions: folder], days: 7, now: now)
        XCTAssertEqual(Set(result.sessions.map(\.sessionID)), [user, guardian])
        XCTAssertEqual(result.sessions.first { $0.sessionID == guardian }?.isService, true)
        XCTAssertEqual(Set(result.notchActivities.map(\.session)), [user, guardian])
        XCTAssertNil(result.notchActivities.first { $0.session == user }?.origin)
        XCTAssertEqual(result.notchActivities.first { $0.session == guardian }?.origin, .codexGuardian)
        XCTAssertEqual(result.dailyUsage.reduce(0) { $0 + $1.sessions }, 1)
    }

    func testCodexDropsWindowsTheProviderStoppedReporting() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date.now
        func line(_ date: Date, _ limits: String) -> String {
            "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":\(limits)}}"
        }
        let reset = Int(now.addingTimeInterval(86_400).timeIntervalSince1970)
        let old = line(now.addingTimeInterval(-2 * 86_400), "{\"primary\":{\"used_percent\":10,\"window_minutes\":300,\"resets_at\":\(reset)},\"secondary\":{\"used_percent\":50,\"window_minutes\":10080,\"resets_at\":\(reset)}}")
        let fresh = line(now.addingTimeInterval(-60), "{\"primary\":{\"used_percent\":97,\"window_minutes\":10080,\"resets_at\":\(reset)},\"secondary\":null}")
        try Data((old + "\n" + fresh).utf8).write(to: folder.appendingPathComponent("rollout-\(UUID().uuidString).jsonl"))
        let result = await UsageScanner().scan([.codexSessions: folder], days: 7, now: now)
        XCTAssertEqual(result.codexQuotas.map(\.window), [.sevenDays])
        XCTAssertEqual(result.codexQuotas.first?.used, 97)
    }

    func testToolSummaries() {
        XCTAssertEqual(NotchText.action(tool: "Edit", input: ["file_path": "/a/b/NotchController.swift"]),
                       "Edit NotchController.swift")
        XCTAssertEqual(NotchText.action(tool: "Read", input: ["file_path": "/a/README.md"]), "Read README.md")
        XCTAssertEqual(NotchText.action(tool: "Grep", input: ["pattern": "TODO"]), "Search TODO")
        XCTAssertEqual(NotchText.action(tool: "mcp__plugin_playwright_playwright__browser_click", input: [:]),
                       "plugin_playwright_playwright · browser_click")
        XCTAssertEqual(NotchText.action(tool: "exec_command", input: ["cmd": ["git", "status"]]), "Run git status")
        XCTAssertEqual(NotchText.action(tool: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: Sources/A.swift\n"]),
                       "Patch A.swift")
        XCTAssertEqual(NotchText.action(tool: "Bash", input: "ls -la"), "Run ls -la")
        let long = NotchText.action(tool: "Bash", input: ["command": String(repeating: "x", count: 600)])
        XCTAssertEqual(long?.count, NotchActivity.actionLimit)
        XCTAssertNil(NotchText.action(tool: nil, input: nil))
    }

    func testCleanKeepsParagraphsAndDropsControls() {
        XCTAssertEqual(NotchText.clean("  a\u{7}b \n\n\n\n c  ", limit: 100, singleLine: false), "ab\n\n c")
        XCTAssertEqual(NotchText.clean("a \n\t b", limit: 100, singleLine: true), "a b")
        XCTAssertNil(NotchText.clean(" \n ", limit: 10, singleLine: true))
        XCTAssertEqual(NotchText.clean("abcdef", limit: 4, singleLine: true), "abc…")
    }

    func testTurnMergeKeepsPromptAndDropsStaleCommentary() throws {
        let session = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        func event(_ name: String, _ seconds: TimeInterval, extra: [String: Any] = [:],
                   excerpt: NotchTranscript.Excerpt? = nil) throws -> NotchHookEvent {
            var payload: [String: Any] = ["hook_event_name": name, "session_id": session.uuidString,
                                          "transcript_path": "/tmp/t.jsonl"]
            payload.merge(extra) { $1 }
            return try XCTUnwrap(NotchActivity.parseEvent(try JSONSerialization.data(withJSONObject: payload),
                provider: .claude, environment: [:], now: start.addingTimeInterval(seconds),
                reader: .init(lastAssistantText: { _ in excerpt })))
        }
        let prompt = try event("UserPromptSubmit", 0, extra: ["prompt": "Fix   the\nbuild"]).activity
        XCTAssertEqual(prompt.prompt, "Fix the build")
        let stale = try event("PreToolUse", 2, extra: ["tool_name": "Bash", "tool_input": ["command": "make"]],
                              excerpt: .init(text: "old reply", date: start.addingTimeInterval(-60)))
        let running = try XCTUnwrap(stale.activity.merged(onto: prompt))
        XCTAssertEqual(running.prompt, "Fix the build")
        XCTAssertEqual(running.action, "Run make")
        XCTAssertNil(running.message)
        XCTAssertEqual(running.startedAt, start)
        let fresh = try event("PostToolUse", 4, excerpt: .init(text: "Running make now", date: start.addingTimeInterval(3)))
        let progressed = try XCTUnwrap(fresh.activity.merged(onto: running))
        XCTAssertEqual(progressed.message, "Running make now")
        XCTAssertEqual(progressed.action, "Run make")
        let done = try XCTUnwrap(try event("Stop", 9, extra: ["last_assistant_message": "All green."]).activity
            .merged(onto: progressed))
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(done.message, "All green.")
        XCTAssertEqual(done.prompt, "Fix the build")
        let idle = try event("Notification", 70, extra: ["notification_type": "idle_prompt",
                                                         "message": "Claude is waiting for your input"])
        XCTAssertTrue(idle.idlePrompt)
        XCTAssertNil(idle.activity.merged(onto: done, idlePrompt: true))
        let next = try XCTUnwrap(try event("UserPromptSubmit", 90, extra: ["prompt": "Next"]).activity.merged(onto: done))
        XCTAssertNil(next.message)
        XCTAssertNil(next.action)
        XCTAssertEqual(next.startedAt, start.addingTimeInterval(90))
    }

    func testTranscriptScanStopsAtUserPrompt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("s.jsonl")
        let lines = [
            #"{"type":"assistant","timestamp":"2026-11-12T01:00:00.000Z","message":{"content":[{"type":"text","text":"Previous turn"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"New prompt"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        XCTAssertNil(NotchTranscript.lastAssistantText(path: file.path, home: folder.deletingLastPathComponent()))
        let more = lines + [#"{"type":"assistant","timestamp":"2026-11-12T01:00:05.250Z","message":{"content":[{"type":"text","text":"Tests pass"}]}}"#]
        try Data(more.joined(separator: "\n").utf8).write(to: file)
        let excerpt = try XCTUnwrap(NotchTranscript.lastAssistantText(path: file.path, home: folder.deletingLastPathComponent()))
        XCTAssertEqual(excerpt.text, "Tests pass")
        XCTAssertNotNil(excerpt.date)
        XCTAssertNil(NotchTranscript.lastAssistantText(path: file.path, home: URL(fileURLWithPath: "/nonexistent-home")))
        let codex = #"{"timestamp":"2026-11-12T01:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"Codex says hi"}}"#
        XCTAssertEqual(NotchTranscript.scan(Data(codex.utf8)), .text(.init(text: "Codex says hi",
            date: ISO8601DateFormatter().date(from: "2026-11-12T01:00:00Z"))))
    }

    func testLateHookDoesNotOverwriteNewerState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("activity.json")
        let session = UUID().uuidString
        let now = Date.now
        func event(_ name: String, _ seconds: TimeInterval) throws -> NotchActivity {
            let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": session])
            return try XCTUnwrap(NotchActivity.parse(data, provider: .codex, environment: [:],
                                                    now: now.addingTimeInterval(seconds)))
        }
        try NotchActivityStore.record(event("SessionEnd", 0), at: file)
        try NotchActivityStore.record(event("UserPromptSubmit", -1), at: file)
        XCTAssertEqual(NotchActivityStore.read(file, now: now).map(\.phase), [.ended])
        XCTAssertTrue(NotchActivityStore.read(file, now: now.addingTimeInterval(121)).isEmpty)
    }

    func testCodexTurnAppearsFromLocalLogsBeforeAnyTokenReport() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = UUID()
        let log = folder.appendingPathComponent("rollout-\(session.uuidString).jsonl")
        let now = Date.now
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
        let start = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        try Data(start.utf8).write(to: log)
        let scanner = UsageScanner()
        let running = await scanner.scan([.codexSessions: folder], days: 7, now: now)
        XCTAssertEqual(running.notchActivities.map(\.phase), [.running])
        XCTAssertEqual(running.notchActivities.first?.session, session)
        XCTAssertTrue(running.sessions.isEmpty)

        let prompt = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Ship it\"}}\n"
        let end = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"Shipped.\"}}\n"
        try Data((start + prompt + end).utf8).write(to: log)
        let finished = await scanner.scan([.codexSessions: folder], days: 7, now: now)
        XCTAssertEqual(finished.notchActivities.map(\.phase), [.done])
        XCTAssertEqual(finished.notchActivities.first?.prompt, "Ship it")
        XCTAssertEqual(finished.notchActivities.first?.message, "Shipped.")
    }

    func testClaudeHostComesFromEntrypointBeforeBundle() throws {
        func host(_ environment: [String: String]) throws -> NotchActivity.Host? {
            let payload: [String: Any] = ["hook_event_name": "Stop", "session_id": UUID().uuidString, "cwd": "/tmp/Project"]
            return try XCTUnwrap(NotchActivity.parse(try JSONSerialization.data(withJSONObject: payload),
                                                     provider: .claude, environment: environment)).host
        }
        XCTAssertEqual(try host(["CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                                 "__CFBundleIdentifier": "local.claude.amsterdam-launcher"]), .claudeApp)
        XCTAssertEqual(try host(["CLAUDE_CODE_ENTRYPOINT": "claude-vscode",
                                 "__CFBundleIdentifier": "com.microsoft.VSCode"]), .vscodeChat)
        XCTAssertEqual(try host(["CLAUDE_CODE_ENTRYPOINT": "claude-vscode",
                                 "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"]), .cursorChat)
        XCTAssertEqual(try host(["CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "vscode",
                                 "__CFBundleIdentifier": "com.microsoft.VSCode"]), .vscode)
        XCTAssertEqual(try host(["__CFBundleIdentifier": "com.mitchellh.ghostty"]), .ghostty)
        XCTAssertNil(try host(["__CFBundleIdentifier": "local.claude.amsterdam-launcher"]))
    }

    func testLogOnlyRowsKeepTheirEntrypointHost() {
        var session = SessionUsage(sessionID: UUID(), provider: .claude, project: "/tmp/Project",
                                   tokens: Tokens(), lastActivity: .now)
        session.entrypoint = "claude-vscode"
        XCTAssertEqual(NotchActivity.recent(session).host, .vscodeChat)
        XCTAssertEqual(NotchActivity.recent(session).canReply, false)
        session.entrypoint = "claude-desktop"
        XCTAssertEqual(NotchActivity.recent(session).host, .claudeApp)
    }

    func testRowsDisappearWhenTheAgentProcessIsGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        func row(_ phase: NotchActivity.Phase, pid: Int32?, age: TimeInterval) -> NotchActivity {
            NotchActivity(provider: .claude, session: UUID(), phase: phase, cwd: "/tmp/P", host: nil, terminalID: nil,
                          updatedAt: now.addingTimeInterval(-age), pid: pid)
        }
        let rows = [row(.running, pid: 4242, age: 60), row(.running, pid: 4242, age: 2),
                    row(.done, pid: 4242, age: 60), row(.running, pid: nil, age: 60), row(.waiting, pid: 7, age: 60)]
        let url = root.appendingPathComponent("notch.json")
        try JSONEncoder().encode(rows).write(to: url)
        let kept = NotchActivityStore.read(url, now: now) { pid, _ in pid == 7 }
        XCTAssertEqual(Set(kept.map(\.id)), Set([rows[1], rows[2], rows[3], rows[4]].map(\.id)))
        XCTAssertFalse(NotchActivity.processAlive(Int32.max))
        XCTAssertTrue(NotchActivity.processAlive(getpid()))
        XCTAssertTrue(NotchActivity.processAlive(getpid(), startedBy: now))
        XCTAssertFalse(NotchActivity.processAlive(getpid(), startedBy: now.addingTimeInterval(-86400 * 365)))
    }
}
