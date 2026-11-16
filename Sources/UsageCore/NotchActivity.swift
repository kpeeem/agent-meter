import Darwin
import Foundation

public struct NotchActivity: Codable, Identifiable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case ready, running, permission, question, waiting, done, failed, interrupted, ended, recent

        public var needsAttention: Bool { self == .permission || self == .question || self == .waiting }
        public var needsProcess: Bool { self == .ready || self == .running || needsAttention }
        public var isActive: Bool { self == .ready || self == .running || needsAttention }
        public var isFinished: Bool { self == .done || self == .failed || self == .interrupted }

        var lifetime: TimeInterval {
            switch self {
            case .ended: 120
            case .done, .failed, .interrupted: 900
            case .ready, .running, .permission, .question, .waiting, .recent: 4 * 3600
            }
        }
    }

    public enum Host: String, Codable, Sendable {
        case ghostty, iterm, terminal, warp, wezterm, vscode, cursor, codexApp, claudeApp, vscodeChat, cursorChat

        public static func claudeEntry(_ entrypoint: String?, bundle: String?) -> Host? {
            switch entrypoint {
            case "claude-desktop": .claudeApp
            case "claude-vscode": bundle == Host.cursor.bundleID ? .cursorChat : .vscodeChat
            default: nil
            }
        }

        public var bundleID: String {
            switch self {
            case .ghostty: "com.mitchellh.ghostty"
            case .iterm: "com.googlecode.iterm2"
            case .terminal: "com.apple.Terminal"
            case .warp: "dev.warp.Warp-Stable"
            case .wezterm: "com.github.wez.wezterm"
            case .vscode, .vscodeChat: "com.microsoft.VSCode"
            case .cursor, .cursorChat: "com.todesktop.230313mzl4w4u92"
            case .codexApp: "com.openai.codex"
            case .claudeApp: "com.anthropic.claudefordesktop"
            }
        }

        public var title: String {
            switch self {
            case .ghostty: "Ghostty"
            case .iterm: "iTerm"
            case .terminal: "Terminal"
            case .warp: "Warp"
            case .wezterm: "WezTerm"
            case .vscode, .vscodeChat: "VS Code"
            case .cursor, .cursorChat: "Cursor"
            case .codexApp: "Codex"
            case .claudeApp: "Claude"
            }
        }
    }

    public static let promptLimit = 280

    public var approvalGrace: TimeInterval { provider == .claude ? 0 : 2 }

    public func needsApproval(at now: Date) -> Bool {
        phase == .permission && (request != nil || now.timeIntervalSince(updatedAt) >= approvalGrace)
    }
    public static let actionLimit = 240
    public static let messageLimit = 1200

    public let provider: Provider
    public let session: UUID
    public let phase: Phase
    public let cwd: String?
    public let host: Host?
    public let terminalID: String?
    public let updatedAt: Date
    public let action: String?
    public let prompt: String?
    public let message: String?
    public let messageAt: Date?
    public let startedAt: Date?
    public let request: NotchRequest?
    public let pid: Int32?

    public init(provider: Provider, session: UUID, phase: Phase, cwd: String?, host: Host?,
                terminalID: String?, updatedAt: Date, action: String? = nil, prompt: String? = nil,
                message: String? = nil, messageAt: Date? = nil, startedAt: Date? = nil,
                request: NotchRequest? = nil, pid: Int32? = nil) {
        self.provider = provider
        self.session = session
        self.phase = phase
        self.cwd = cwd
        self.host = host
        self.terminalID = terminalID
        self.updatedAt = updatedAt
        self.action = action
        self.prompt = prompt
        self.message = message
        self.messageAt = messageAt
        self.startedAt = startedAt
        self.request = request
        self.pid = pid
    }

    public static func processAlive(_ pid: Int32, startedBy date: Date = .distantFuture) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return TimeInterval(info.pbi_start_tvsec) <= date.timeIntervalSince1970 + 1
        }
        return getpgid(pid) >= 0 || errno != ESRCH
    }

    public var id: String { provider.rawValue + "/" + session.uuidString.lowercased() }
    public var project: String {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? provider.title
    }

    public var link: URL? { URL(string: "agentmeter://session/" + id) }

    public func with(phase: Phase, request: NotchRequest?, at date: Date) -> Self {
        Self(provider: provider, session: session, phase: phase, cwd: cwd, host: host, terminalID: terminalID,
             updatedAt: date, action: action, prompt: prompt, message: message, messageAt: messageAt,
             startedAt: startedAt, request: request, pid: pid)
    }

    public var canReply: Bool {
        switch provider {
        case .claude: [.ghostty, .iterm, .terminal, .warp, .wezterm, .vscode, .cursor].contains(host)
        case .codex: true
        }
    }

    public func filling(from event: Self) -> Self {
        let sameTurn = startedAt == nil || event.startedAt == nil || startedAt == event.startedAt
        return Self(provider: provider, session: session, phase: phase, cwd: cwd ?? event.cwd,
                    host: host ?? event.host, terminalID: terminalID ?? event.terminalID, updatedAt: updatedAt,
                    action: action ?? (sameTurn ? event.action : nil), prompt: prompt ?? event.prompt,
                    message: message ?? (sameTurn ? event.message : nil),
                    messageAt: message == nil && sameTurn ? event.messageAt : messageAt,
                    startedAt: startedAt ?? event.startedAt, request: request ?? event.request,
                    pid: pid ?? event.pid)
    }

    public func merged(onto previous: Self?, idlePrompt: Bool = false) -> Self? {
        guard let previous, previous.id == id else { return idlePrompt ? nil : self }
        if idlePrompt && previous.phase != .running { return nil }
        let resets = startedAt != nil || phase == .ready
        let turnStart = startedAt ?? (resets ? nil : previous.startedAt)
        var text = resets ? nil : previous.message
        var textAt = resets ? nil : previous.messageAt
        if let message {
            if let messageAt {
                let fresh = turnStart.map { messageAt >= $0.addingTimeInterval(-1) } ?? true
                if fresh && messageAt >= (textAt ?? .distantPast) {
                    text = message
                    textAt = messageAt
                }
            } else {
                text = message
                textAt = nil
            }
        }
        return Self(provider: provider, session: session, phase: phase, cwd: cwd ?? previous.cwd,
                    host: host ?? previous.host, terminalID: terminalID ?? previous.terminalID, updatedAt: updatedAt,
                    action: action ?? (resets ? nil : previous.action),
                    prompt: prompt ?? (phase == .ready ? nil : previous.prompt),
                    message: text, messageAt: textAt, startedAt: turnStart,
                    request: request ?? (phase == previous.phase && phase.needsAttention ? previous.request : nil),
                    pid: pid ?? previous.pid)
    }

    public static func recent(_ session: SessionUsage) -> Self {
        Self(provider: session.provider, session: session.sessionID, phase: .recent,
             cwd: session.project.isEmpty ? nil : session.project,
             host: session.provider == .claude ? Host.claudeEntry(session.entrypoint, bundle: nil) : nil,
             terminalID: nil, updatedAt: session.lastActivity)
    }

    public static func sessionID(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "agentmeter", parts.host == "session",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, let provider = Provider(rawValue: String(path[1])),
              let id = UUID(uuidString: String(path[2])) else { return nil }
        return provider.rawValue + "/" + id.uuidString.lowercased()
    }

    public static func parse(_ data: Data, provider: Provider, environment: [String: String],
                             tty: String? = nil, now: Date = .now,
                             reader: NotchTranscript.Reader = .init()) -> NotchActivity? {
        parseEvent(data, provider: provider, environment: environment, tty: tty, now: now, reader: reader)?.activity
    }

    public static func parseEvent(_ data: Data, provider: Provider, environment: [String: String],
                                  tty: String? = nil, pid: Int32? = nil, now: Date = .now,
                                  reader: NotchTranscript.Reader = .init()) -> NotchHookEvent? {
        guard data.count <= 1024 * 1024,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = payload["session_id"] as? String, let session = UUID(uuidString: rawID),
              let event = payload["hook_event_name"] as? String else { return nil }
        let toolAction = { NotchText.action(tool: payload["tool_name"] as? String,
                                            input: payload["tool_input"] ?? payload["command"]) }
        let transcriptPath = payload["transcript_path"] as? String
        if provider == .codex, let transcriptPath, reader.codexThreadVisible(transcriptPath) == false { return nil }
        let commentary = { () -> NotchTranscript.Excerpt? in
            transcriptPath.flatMap(reader.lastAssistantText)
        }
        let phase: Phase
        var action: String?
        var prompt: String?
        var message: String?
        var messageAt: Date?
        var startedAt: Date?
        var idlePrompt = false
        switch event {
        case "SessionStart":
            phase = .ready
        case "UserPromptSubmit":
            phase = .running
            prompt = NotchText.clean(payload["prompt"] as? String, limit: promptLimit, singleLine: true)
            startedAt = now
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            phase = .running
            action = toolAction()
            if let excerpt = commentary() {
                message = excerpt.text
                messageAt = excerpt.date ?? now
            }
        case "PermissionRequest":
            let asksUser = provider == .codex && transcriptPath.flatMap(reader.codexApproval)?.asksUser == true
            phase = asksUser ? .permission : .running
            action = toolAction()
        case "Stop":
            phase = .done
            if let text = NotchText.firstText(payload, keys: ["last_assistant_message", "message", "summary"]) {
                message = NotchText.clean(text, limit: messageLimit, singleLine: false)
            } else if let excerpt = commentary() {
                message = excerpt.text
                messageAt = excerpt.date ?? now
            }
        case "StopFailure":
            phase = .failed
            message = NotchText.clean(NotchText.firstText(payload, keys: ["error", "message", "reason"]),
                                      limit: messageLimit, singleLine: false)
        case "Interrupt":
            phase = .interrupted
        case "SessionEnd":
            phase = .ended
        case "Notification":
            message = NotchText.clean(payload["message"] as? String, limit: messageLimit, singleLine: false)
            switch payload["notification_type"] as? String {
            case "permission_prompt": phase = .permission
            case "idle_prompt":
                phase = .waiting
                idlePrompt = true
            case "elicitation_dialog": phase = .waiting
            default: return nil
            }
        default:
            return nil
        }
        let cwd = (payload["cwd"] as? String).flatMap { path in
            path.hasPrefix("/") && path.utf8.count <= 4096
                && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? path : nil
        }
        let terminal: (Host?, String?)
        let bundle = environment["__CFBundleIdentifier"]
        if provider == .claude, let host = Host.claudeEntry(environment["CLAUDE_CODE_ENTRYPOINT"], bundle: bundle) {
            terminal = (host, nil)
        } else {
        switch environment["TERM_PROGRAM"]?.lowercased() {
        case "ghostty": terminal = (.ghostty, nil)
        case "iterm.app":
            let token = environment["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init)
            terminal = (.iterm, token.flatMap(UUID.init(uuidString:))?.uuidString)
        case "apple_terminal":
            let device = tty.flatMap { $0.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) == nil ? nil : $0 }
            terminal = (.terminal, device)
        case "warpterminal": terminal = (.warp, nil)
        case "wezterm": terminal = (.wezterm, nil)
        case "vscode":
            terminal = (environment["__CFBundleIdentifier"] == Host.cursor.bundleID ? .cursor : .vscode, nil)
        default:
            let hosts: [Host] = [.ghostty, .iterm, .terminal, .warp, .wezterm, .vscode, .cursor,
                                 provider == .codex ? .codexApp : .claudeApp]
            terminal = (hosts.first { $0.bundleID == bundle }, nil)
        }
        }
        let activity = NotchActivity(provider: provider, session: session, phase: phase, cwd: cwd,
                                     host: terminal.0, terminalID: terminal.1, updatedAt: now, action: action,
                                     prompt: prompt, message: message, messageAt: messageAt, startedAt: startedAt,
                                     pid: pid.flatMap { $0 > 1 ? $0 : nil })
        return NotchHookEvent(activity: activity, idlePrompt: idlePrompt)
    }
}

public struct NotchHookEvent: Sendable, Equatable {
    public let activity: NotchActivity
    public let idlePrompt: Bool
}

public enum NotchText {
    public static func clean(_ text: String?, limit: Int, singleLine: Bool) -> String? {
        guard let text else { return nil }
        let controls = CharacterSet.controlCharacters
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let visible = String(String.UnicodeScalarView(line.unicodeScalars.compactMap { scalar in
                    scalar == "\t" ? " " : controls.contains(scalar) ? nil : scalar
                }))
                guard let last = visible.lastIndex(where: { $0 != " " }) else { return "" }
                return String(visible[...last])
            }
        let joined: String
        if singleLine {
            joined = lines.joined(separator: " ").split(separator: " ").joined(separator: " ")
        } else {
            var kept: [String] = []
            for line in lines where !(line.isEmpty && kept.last?.isEmpty != false) { kept.append(line) }
            joined = kept.joined(separator: "\n")
        }
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func firstText(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = payload[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    public static func action(tool rawTool: String?, input rawInput: Any?) -> String? {
        guard let tool = clean(rawTool, limit: 80, singleLine: true) else { return nil }
        var fields = rawInput as? [String: Any] ?? [:]
        if let command = rawInput as? String { fields["command"] = command }
        func text(_ keys: String...) -> String? {
            for key in keys {
                if let value = fields[key] as? String, let cleaned = clean(value, limit: NotchActivity.actionLimit,
                                                                           singleLine: true) { return cleaned }
                if let parts = fields[key] as? [String], let cleaned = clean(parts.joined(separator: " "),
                                                                             limit: NotchActivity.actionLimit,
                                                                             singleLine: true) { return cleaned }
            }
            return nil
        }
        func file(_ keys: String...) -> String? {
            for key in keys {
                if let value = fields[key] as? String, !value.isEmpty {
                    let name = URL(fileURLWithPath: value).lastPathComponent
                    return clean(name.isEmpty ? value : name, limit: 120, singleLine: true)
                }
            }
            return nil
        }
        let summary: (verb: String, detail: String?)
        switch tool.lowercased() {
        case "bash", "shell", "exec_command", "local_shell", "unified_exec", "container.exec":
            summary = ("Run", text("command", "cmd"))
        case "read", "notebookread", "view_image":
            summary = ("Read", file("file_path", "notebook_path", "path"))
        case "edit", "multiedit", "notebookedit":
            summary = ("Edit", file("file_path", "notebook_path", "path"))
        case "write":
            summary = ("Write", file("file_path", "path"))
        case "apply_patch":
            summary = ("Patch", patchTarget(text("input", "patch", "command")))
        case "grep":
            summary = ("Search", text("pattern"))
        case "glob":
            summary = ("Find", text("pattern"))
        case "webfetch":
            summary = ("Fetch", text("url").flatMap { URL(string: $0)?.host } ?? text("url"))
        case "websearch", "web_search":
            summary = ("Search web", text("query"))
        case "task", "agent":
            summary = ("Agent", text("description", "prompt"))
        case "todowrite", "taskcreate", "taskupdate", "update_plan":
            summary = ("Update plan", nil)
        case "askuserquestion":
            summary = ("Question", nil)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                let server = parts.count > 2 ? parts[1] : "MCP"
                summary = (server + " · " + (parts.last ?? tool), nil)
            } else {
                summary = (tool, nil)
            }
        }
        return clean(summary.detail.map { summary.verb + " " + $0 } ?? summary.verb,
                     limit: NotchActivity.actionLimit, singleLine: true)
    }

    private static func patchTarget(_ patch: String?) -> String? {
        guard let patch else { return nil }
        for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
            if let range = patch.range(of: marker) {
                let rest = patch[range.upperBound...]
                let path = rest.prefix { $0 != " " && $0 != "*" && $0 != "\n" }
                let name = URL(fileURLWithPath: String(path)).lastPathComponent
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}

public enum NotchTranscript {
    public struct Excerpt: Sendable, Equatable {
        public let text: String
        public let date: Date?
    }

    public struct Reader {
        public var lastAssistantText: (String) -> Excerpt?
        public var codexApproval: (String) -> CodexApproval?
        public var codexThreadVisible: (String) -> Bool?

        public init(lastAssistantText: @escaping (String) -> Excerpt? = { _ in nil },
                    codexApproval: @escaping (String) -> CodexApproval? = { _ in nil },
                    codexThreadVisible: @escaping (String) -> Bool? = { _ in nil }) {
            self.lastAssistantText = lastAssistantText
            self.codexApproval = codexApproval
            self.codexThreadVisible = codexThreadVisible
        }

        public static func files(home: URL) -> Self {
            Self(lastAssistantText: { NotchTranscript.lastAssistantText(path: $0, home: home) },
                 codexApproval: { NotchTranscript.codexApproval(path: $0, home: home) },
                 codexThreadVisible: { NotchTranscript.codexThreadVisible(path: $0, home: home) })
        }
    }

    public static func codexThreadVisible(path: String, home: URL) -> Bool? {
        guard let handle = open(path: path, home: home) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024),
              let end = head.firstIndex(of: UInt8(ascii: "\n")) ?? (head.count < 512 * 1024 ? head.endIndex : nil),
              let object = try? JSONSerialization.jsonObject(with: head[..<end]) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return CodexThread.isUserVisible(source: payload["source"], threadSource: payload["thread_source"] as? String)
    }

    private static func open(path: String, home: URL) -> FileHandle? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let root = home.standardizedFileURL.path
        guard url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/"), url.pathExtension == "jsonl" else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        return try? FileHandle(forReadingFrom: url)
    }

    public struct CodexApproval: Sendable, Equatable {
        public let policy: String?
        public let reviewer: String?

        public var asksUser: Bool { policy != "never" && (reviewer == nil || reviewer == "user") }
    }

    public static func lastAssistantText(path: String, home: URL) -> Excerpt? {
        tail(path: path, home: home) { line in
            switch scan(line) {
            case .text(let excerpt): .found(excerpt)
            case .boundary: .stop
            case .skip: .next
            }
        }
    }

    public static func codexApproval(path: String, home: URL) -> CodexApproval? {
        let marker = Data("\"turn_context\"".utf8)
        return tail(path: path, home: home) { line in
            guard line.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else { return .next }
            return .found(CodexApproval(policy: payload["approval_policy"] as? String,
                                        reviewer: payload["approvals_reviewer"] as? String))
        }
    }

    enum Step<Value> {
        case found(Value)
        case stop
        case next
    }

    static func tail<Value>(path: String, home: URL, _ visit: (Data) -> Step<Value>) -> Value? {
        guard let handle = open(path: path, home: home) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > 0 else { return nil }
        var window: UInt64 = 64 * 1024
        let cap: UInt64 = 1024 * 1024
        while true {
            let size = min(window, total)
            guard (try? handle.seek(toOffset: total - size)) != nil,
                  let data = try? handle.readToEnd() else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if size < total, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                switch visit(Data(line)) {
                case .found(let value): return value
                case .stop: return nil
                case .next: continue
                }
            }
            if size >= total || window >= cap { return nil }
            window = min(window * 2, cap)
        }
    }

    enum Line: Equatable {
        case text(Excerpt)
        case boundary
        case skip
    }

    static func scan(_ line: Data) -> Line {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return .skip }
        let date = (object["timestamp"] as? String).flatMap(parseDate)
        func excerpt(_ parts: [String]) -> Line {
            guard let text = NotchText.clean(parts.joined(separator: "\n"), limit: NotchActivity.messageLimit,
                                             singleLine: false) else { return .skip }
            return .text(Excerpt(text: text, date: date))
        }
        switch type {
        case "assistant":
            guard object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return .skip }
            return excerpt(content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil })
        case "user":
            guard object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { return .skip }
            if message["content"] is String { return .boundary }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let kinds = Set(blocks.compactMap { $0["type"] as? String })
            return kinds.contains("text") && !kinds.contains("tool_result") ? .boundary : .skip
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any] else { return .skip }
            switch payload["type"] as? String {
            case "agent_message": return excerpt([payload["message"] as? String].compactMap { $0 })
            case "user_message", "task_started": return .boundary
            default: return .skip
            }
        case "response_item":
            guard let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
                  payload["role"] as? String == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { return .skip }
            return excerpt(content.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil })
        default:
            return .skip
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public enum CodexThread {
    public static func isUserVisible(source: Any?, threadSource: String?) -> Bool {
        if let thread = threadSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !thread.isEmpty {
            return thread == "user"
        }
        guard let source else { return true }
        guard let name = source as? String else { return false }
        return ["cli", "vscode"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

public enum NotchActivityStore {
    public static let relativePath = "Library/Application Support/Agent Meter/notch-activity.json"
    private static let maxBytes = 512 * 1024

    public static func read(_ url: URL, now: Date = .now,
                            alive: (Int32, Date) -> Bool = NotchActivity.processAlive) -> [NotchActivity] {
        guard let file = try? openLog(url), let data = try? file.read(upToCount: maxBytes + 1),
              data.count <= maxBytes, let events = try? JSONDecoder().decode([NotchActivity].self, from: data) else { return [] }
        return events.filter {
            guard $0.updatedAt <= now.addingTimeInterval(5), now.timeIntervalSince($0.updatedAt) < $0.phase.lifetime else {
                return false
            }
            guard $0.phase.needsProcess, let pid = $0.pid, now.timeIntervalSince($0.updatedAt) > 10 else { return true }
            return alive(pid, $0.updatedAt)
        }
    }

    public static func record(_ event: NotchActivity, at url: URL) throws {
        try record(NotchHookEvent(activity: event, idlePrompt: false), at: url)
    }

    public static func record(_ event: NotchHookEvent, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let lockURL = directory.appendingPathComponent("notch-activity.lock")
        let fd = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
        let activity = event.activity
        let previous = read(url)
        let current = previous.first { $0.id == activity.id }
        if let current, current.updatedAt > activity.updatedAt { return }
        guard let merged = activity.merged(onto: current, idlePrompt: event.idlePrompt) else { return }
        let next = ([merged] + previous.filter { $0.id != activity.id })
            .sorted { $0.updatedAt > $1.updatedAt }.prefix(64)
        let data = try JSONEncoder().encode(Array(next))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
