import Foundation
import XCTest
@testable import UsageCore

final class AgentProcessesTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_794_900_000)

    func process(_ pid: Int32, _ ppid: Int32, _ path: String, _ arguments: [String] = [], memory: Int = 10,
                 cwd: String? = nil) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, path: path, arguments: [path] + arguments, memoryMB: memory,
                   startedAt: start, cwd: cwd)
    }

    func testFindsGhostRunsRemoteChannelsAndMCPServers() throws {
        let claude = "/Users/me/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude"
        let codex = "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let processes = [
            process(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude", memory: 400),
            process(11, 10, "/Applications/Claude.app/Contents/Helpers/disclaimer", ["--pgroup", "--", claude]),
            process(12, 11, claude, ["--output-format", "stream-json", "--input-format", "stream-json"], memory: 150),
            process(13, 12, "/opt/homebrew/bin/node", ["/Users/me/Dev/mcp/yoomoney-mcp/dist/index.js"]),
            process(14, 12, "/bin/zsh", ["-c", "grep mcp file"]),
            process(15, 14, "/usr/bin/grep", ["mcp", "file"]),
            process(20, 1, "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3", ["-I", "/Users/me/Dev/brain/scripts/nightly.py"]),
            process(21, 20, "/Users/me/.local/bin/claude", ["-p", "--no-session-persistence", "label"], cwd: "/Users/me/Dev/brain"),
            process(30, 1, "/Applications/Codex.app/Contents/MacOS/ChatGPT", memory: 300),
            process(31, 30, codex, ["-c", "features.x=true", "app-server", "--analytics-default-enabled"], memory: 600),
            process(32, 31, "/usr/local/bin/npm", ["exec", "@playwright/mcp@latest"]),
            process(33, 30, "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"),
            process(34, 33, codex, ["exec", "--json", "--ephemeral", "--thread-source", "computer_history"], cwd: "/"),
            process(35, 30, codex, ["-c", "forced_login_method=\"chatgpt\"", "exec-server", "--remote", "https://example"]),
        ]
        let groups = AgentProcessSnapshot.classify(processes, claudeSessions: [12: ClaudeSessionRecord(status: "idle", kind: "interactive")])
        func group(_ title: String) -> AgentProcessGroup? { groups.first { $0.title == title } }

        XCTAssertEqual(groups.first?.kind, .remote)
        XCTAssertEqual(group("Claude Code sessions")?.owner, "Claude Desktop")
        XCTAssertEqual(group("Claude Code sessions")?.idle, 1)
        XCTAssertEqual(group("yoomoney-mcp")?.provider, .claude)
        XCTAssertNil(groups.first { $0.title.contains("grep") || $0.title == "file" })
        let nightly = try XCTUnwrap(group("claude -p · no transcript"))
        XCTAssertEqual(nightly.owner, "launchd · nightly.py")
        XCTAssertEqual(nightly.kind, .ephemeral)
        XCTAssertEqual(nightly.cwd, "/Users/me/Dev/brain")
        let history = try XCTUnwrap(group("codex exec · computer history · no transcript"))
        XCTAssertEqual(history.owner, "Codex computer use")
        XCTAssertEqual(history.origin, .codexScripted)
        XCTAssertEqual(group("Codex app server")?.kind, .helper)
        XCTAssertEqual(group("playwright-mcp")?.provider, .codex)
        XCTAssertEqual(group("Codex cloud environment")?.kind, .remote)
        XCTAssertEqual(group("Claude Desktop app")?.count, 1)

        let snapshot = AgentProcessSnapshot(capturedAt: start.addingTimeInterval(30), groups: groups, remoteFolders: [])
        XCTAssertEqual(snapshot.notchActivities().compactMap(\.origin).sorted { $0.rawValue < $1.rawValue },
                       [.claudeScripted, .codexScripted])
        let remembered = snapshot.remembering(nil)
        XCTAssertEqual(remembered.seen?.count, 2)
        let later = AgentProcessSnapshot(capturedAt: start.addingTimeInterval(8 * 86_400), groups: [], remoteFolders: [])
            .remembering(remembered)
        XCTAssertEqual(later.seen?.count, 0)
    }
}
