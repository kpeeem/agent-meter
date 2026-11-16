import XCTest
@testable import UsageCore

final class ClaudeDesktopSessionsTests: XCTestCase {
    func testFindsDesktopSessionByCliSessionID() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent(ClaudeDesktopSessions.relativePath).appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let direct = UUID()
        let forked = UUID()
        try Data(#"{"sessionId":"local_\#(direct.uuidString.lowercased())","cliSessionId":"\#(direct.uuidString.lowercased())"}"#.utf8)
            .write(to: folder.appendingPathComponent("local_\(direct.uuidString.lowercased()).json"))
        try Data(#"{"sessionId":"local_old","cliSessionId":"\#(forked.uuidString.lowercased())","lastActivityAt":1}"#.utf8)
            .write(to: folder.appendingPathComponent("local_old.json"))
        try Data(#"{"sessionId":"local_new","cliSessionId":"\#(forked.uuidString.lowercased())","lastActivityAt":5}"#.utf8)
            .write(to: folder.appendingPathComponent("local_new.json"))
        try Data(#"{"sessionId":"../escape","cliSessionId":"\#(UUID().uuidString.lowercased())"}"#.utf8)
            .write(to: folder.appendingPathComponent("local_bad.json"))

        XCTAssertEqual(ClaudeDesktopSessions.sessionID(for: direct, home: home), "local_" + direct.uuidString.lowercased())
        XCTAssertEqual(ClaudeDesktopSessions.sessionID(for: forked, home: home), "local_new")
        XCTAssertNil(ClaudeDesktopSessions.sessionID(for: UUID(), home: home))
        XCTAssertEqual(ClaudeDesktopSessions.url(for: "local_new")?.absoluteString, "claude://code/continue?session=local_new")
        XCTAssertNil(ClaudeDesktopSessions.url(for: "local_a&b=c"))
    }
}
