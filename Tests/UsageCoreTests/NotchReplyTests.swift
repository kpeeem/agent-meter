import Foundation
import XCTest
@testable import UsageCore

final class NotchReplyTests: XCTestCase {
    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    func testApprovalRequestKeepsFullCommandAndPrintsDecisions() throws {
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                      "tool_input": ["command": "swift build\n  --configuration release"]]
        let request = try XCTUnwrap(NotchRequest.make(event: "PermissionRequest", payload: payload))
        XCTAssertEqual(request.kind, .approval)
        XCTAssertEqual(request.detail, "swift build\n  --configuration release")
        let allow = try object(NotchReply(decision: .allow).output(event: "PermissionRequest", payload: payload))
        let output = try XCTUnwrap(allow["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((output["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        let deny = try object(NotchReply(decision: .deny).output(event: "PermissionRequest", payload: payload))
        XCTAssertEqual(((deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String, "deny")
        XCTAssertNil(NotchReply(decision: .pass).output(event: "PermissionRequest", payload: payload))
    }

    func testQuestionAnswersAreMergedIntoToolInput() throws {
        let questions: [[String: Any]] = [[
            "question": "Which database?", "header": "Storage", "multiSelect": false,
            "options": [["label": "SQLite", "description": "Local file"], ["label": "Postgres"]],
        ]]
        let payload: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                                      "tool_input": ["questions": questions]]
        let request = try XCTUnwrap(NotchRequest.make(event: "PreToolUse", payload: payload))
        XCTAssertEqual(request.kind, .question)
        XCTAssertEqual(request.questions.first?.options.map(\.label), ["SQLite", "Postgres"])
        XCTAssertEqual(request.questions.first?.header, "Storage")
        let reply = NotchReply(decision: .allow, answers: ["Which database?": "SQLite"])
        let output = try XCTUnwrap(try object(reply.output(event: "PreToolUse", payload: payload))["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        let input = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String], ["Which database?": "SQLite"])
        XCTAssertNotNil(input["questions"])
        XCTAssertNil(NotchReply(decision: .allow).output(event: "PreToolUse", payload: payload))
        XCTAssertNil(NotchRequest.make(event: "PreToolUse", payload: ["tool_name": "Bash", "tool_input": [:]]))
    }

    func testChannelNeedsALiveAppAndDeliversReplies() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(NotchReplyChannel.appIsListening(home: home))
        try NotchReplyChannel.writeHeartbeat(home: home, now: .now.addingTimeInterval(-30))
        XCTAssertFalse(NotchReplyChannel.appIsListening(home: home))
        try NotchReplyChannel.writeHeartbeat(home: home)
        XCTAssertTrue(NotchReplyChannel.appIsListening(home: home))
        try NotchReplyChannel.writeHeartbeat(home: home, pid: 999_999)
        XCTAssertFalse(NotchReplyChannel.appIsListening(home: home))
        try NotchReplyChannel.writeHeartbeat(home: home)

        let id = UUID().uuidString
        XCTAssertNil(NotchReplyChannel.wait(for: id, home: home, limit: 0.3) { false })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try? NotchReplyChannel.send(NotchReply(decision: .deny), for: id, home: home)
        }
        XCTAssertEqual(NotchReplyChannel.wait(for: id, home: home, limit: 3) { false }?.decision, .deny)
        XCTAssertNil(NotchReplyChannel.take(requestID: id, home: home), "A reply is consumed once")
        XCTAssertNil(NotchReplyChannel.wait(for: UUID().uuidString, home: home, limit: 3) { true },
                     "Waiting stops when the agent moves on")
        XCTAssertThrowsError(try NotchReplyChannel.send(NotchReply(decision: .allow), for: "../escape", home: home))
        let mode = try FileManager.default.attributesOfItem(atPath: NotchReplyChannel.directory(home: home).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testRequestSurvivesTheMatchingNotificationButNotProgress() throws {
        let session = UUID()
        let request = NotchRequest(kind: .approval, tool: "Bash", detail: "rm -rf build")
        let pending = NotchActivity(provider: .claude, session: session, phase: .permission, cwd: "/tmp/p", host: .iterm,
                                    terminalID: nil, updatedAt: .now, action: "Run rm -rf build", request: request)
        let notice = NotchActivity(provider: .claude, session: session, phase: .permission, cwd: nil, host: nil,
                                   terminalID: nil, updatedAt: .now.addingTimeInterval(1), message: "Claude needs your permission")
        XCTAssertEqual(notice.merged(onto: pending)?.request, request)
        let progress = NotchActivity(provider: .claude, session: session, phase: .running, cwd: nil, host: nil,
                                     terminalID: nil, updatedAt: .now.addingTimeInterval(2))
        XCTAssertNil(progress.merged(onto: pending)?.request)
        XCTAssertTrue(pending.canReply)
        XCTAssertFalse(pending.with(phase: .permission, request: request, at: .now).filling(from: pending).canReply == false)
        let desktop = NotchActivity(provider: .claude, session: session, phase: .running, cwd: nil, host: .claudeApp,
                                    terminalID: nil, updatedAt: .now)
        XCTAssertFalse(desktop.canReply)
    }
}
