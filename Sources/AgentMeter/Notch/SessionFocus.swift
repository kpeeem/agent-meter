import AppKit
import UsageCore

@MainActor
enum SessionFocus {
    enum Outcome: Equatable {
        case opened
        case copied(String)
        case failed(String)
    }

    static let copyResumeKey = "notch.copy-resume"

    static var copiesResume: Bool { UserDefaults.standard.bool(forKey: copyResumeKey) }

    static func open(_ activity: NotchActivity) async -> Outcome {
        let codexLink = activity.provider == .codex ? activity.provider.sessionURL(activity.session) : nil
        if let codexLink, activity.host == nil || activity.host == .codexApp, NSWorkspace.shared.open(codexLink) {
            return .opened
        }
        switch activity.host {
        case .claudeApp?:
            if await openInClaudeDesktop(activity.session) || activate(NotchActivity.Host.claudeApp.bundleID) {
                return .opened
            }
        case let host? where host == .vscodeChat || host == .cursorChat:
            if await openInEditor(activity, cursor: host == .cursorChat) { return .opened }
        case let host?:
            if let locator = locator(for: activity, host: host),
               let script = Bundle.main.url(forResource: host.rawValue, withExtension: "applescript",
                                            subdirectory: "TerminalFocus"),
               await focus(script: script, locator: locator) { return .opened }
            if activate(host.bundleID) { return .opened }
        case nil:
            if activity.provider == .claude, await openInClaudeDesktop(activity.session) { return .opened }
        }
        if let codexLink, NSWorkspace.shared.open(codexLink) { return .opened }
        if activity.provider == .claude, copiesResume {
            let command = "claude --resume " + activity.session.uuidString.lowercased()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return .copied(command)
        }
        return .failed(String(localized: "Agent Meter could not find where this chat runs."))
    }

    private static func locator(for activity: NotchActivity, host: NotchActivity.Host) -> String? {
        switch host {
        case .ghostty: activity.cwd
        case .iterm, .terminal: activity.terminalID
        default: nil
        }
    }

    private static func activate(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate(options: []) == true
    }

    static func openInEditor(_ activity: NotchActivity, cursor: Bool) async -> Bool {
        let running = { (host: NotchActivity.Host) in
            !NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).isEmpty
        }
        let scheme = cursor || (!running(.vscode) && running(.cursor)) ? "cursor" : "vscode"
        if let cwd = activity.cwd {
            var folder = URLComponents()
            folder.scheme = scheme
            folder.host = "file"
            folder.path = cwd
            if let url = folder.url, NSWorkspace.shared.open(url) {
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        var chat = URLComponents()
        chat.scheme = scheme
        chat.host = "anthropic.claude-code"
        chat.path = "/open"
        chat.queryItems = [URLQueryItem(name: "session", value: activity.session.uuidString.lowercased())]
        return chat.url.map { NSWorkspace.shared.open($0) } ?? false
    }

    static func openInClaudeDesktop(_ session: UUID) async -> Bool {
        guard let home = realHome else { return false }
        let id = await Task.detached { ClaudeDesktopSessions.sessionID(for: session, home: home) }.value
        guard let id, let url = ClaudeDesktopSessions.url(for: id) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static var realHome: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    private nonisolated static func focus(script: URL, locator: String) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [script.path, locator]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
