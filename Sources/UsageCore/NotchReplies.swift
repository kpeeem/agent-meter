import Darwin
import Foundation

public struct NotchRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case approval, question }

    public struct Option: Codable, Sendable, Equatable {
        public let label: String
        public let detail: String?
    }

    public struct Question: Codable, Sendable, Equatable {
        public let header: String?
        public let question: String
        public let options: [Option]
        public let multiSelect: Bool
    }

    public let id: String
    public let kind: Kind
    public let tool: String?
    public let detail: String?
    public let questions: [Question]

    public init(id: String = UUID().uuidString, kind: Kind, tool: String?, detail: String?, questions: [Question] = []) {
        self.id = id
        self.kind = kind
        self.tool = tool
        self.detail = detail
        self.questions = questions
    }

    public static let detailLimit = 2000

    public static func make(event: String, payload: [String: Any]) -> NotchRequest? {
        let tool = payload["tool_name"] as? String
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        if event == "PreToolUse", tool?.lowercased() == "askuserquestion" {
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> Question? in
                guard let text = NotchText.clean(item["question"] as? String, limit: 600, singleLine: false) else { return nil }
                let options = (item["options"] as? [[String: Any]] ?? []).prefix(8).compactMap { option -> Option? in
                    guard let label = NotchText.clean(option["label"] as? String, limit: 120, singleLine: true) else { return nil }
                    return Option(label: label, detail: NotchText.clean(option["description"] as? String, limit: 200,
                                                                         singleLine: true))
                }
                guard !options.isEmpty else { return nil }
                return Question(header: NotchText.clean(item["header"] as? String, limit: 60, singleLine: true),
                                question: text, options: Array(options), multiSelect: item["multiSelect"] as? Bool ?? false)
            }
            guard !questions.isEmpty, questions.count <= 4 else { return nil }
            return NotchRequest(kind: .question, tool: tool, detail: nil, questions: questions)
        }
        guard event == "PermissionRequest" else { return nil }
        return NotchRequest(kind: .approval, tool: tool, detail: approvalDetail(tool: tool, input: input,
                                                                                 raw: payload["tool_input"]))
    }

    static func approvalDetail(tool: String?, input: [String: Any], raw: Any?) -> String? {
        if let command = raw as? String { return NotchText.clean(command, limit: detailLimit, singleLine: false) }
        for key in ["command", "cmd"] {
            if let text = input[key] as? String { return NotchText.clean(text, limit: detailLimit, singleLine: false) }
            if let parts = input[key] as? [String] {
                return NotchText.clean(parts.joined(separator: " "), limit: detailLimit, singleLine: false)
            }
        }
        var lines: [String] = []
        for key in ["file_path", "notebook_path", "path", "url", "pattern", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty { lines.append(value) }
        }
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            lines.append("- " + old.replacingOccurrences(of: "\n", with: "\n- "))
            lines.append("+ " + new.replacingOccurrences(of: "\n", with: "\n+ "))
        } else if let content = input["content"] as? String {
            lines.append(content)
        }
        if lines.isEmpty, !input.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) {
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return NotchText.clean(lines.joined(separator: "\n"), limit: detailLimit, singleLine: false)
    }
}

public struct NotchReply: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case allow, deny, pass }

    public let decision: Decision
    public let answers: [String: String]?

    public init(decision: Decision, answers: [String: String]? = nil) {
        self.decision = decision
        self.answers = answers
    }

    public func output(event: String, payload: [String: Any]) -> Data? {
        let body: [String: Any]
        switch (event, decision) {
        case (_, .pass):
            return nil
        case ("PreToolUse", .allow):
            guard let answers, !answers.isEmpty else { return nil }
            var input = payload["tool_input"] as? [String: Any] ?? [:]
            input["answers"] = answers
            body = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                           "updatedInput": input]]
        case ("PreToolUse", .deny):
            body = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                           "permissionDecisionReason": "Declined in Agent Meter"]]
        case ("PermissionRequest", .allow):
            body = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        case ("PermissionRequest", .deny):
            body = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                           "decision": ["behavior": "deny", "message": "Denied in Agent Meter"]]]
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

public enum NotchReplyChannel {
    public static let relativePath = "Library/Application Support/Agent Meter/replies"
    public static let waitLimit: TimeInterval = 280
    static let heartbeatName = "app.json"

    struct Heartbeat: Codable {
        let pid: Int32
        let updatedAt: Date
    }

    public static func directory(home: URL) -> URL {
        home.appendingPathComponent(relativePath, isDirectory: true)
    }

    public static func prepare(home: URL) throws -> URL {
        let folder = directory(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else { throw CocoaError(.fileWriteNoPermission) }
        return folder
    }

    public static func writeHeartbeat(home: URL, pid: Int32 = getpid(), now: Date = .now) throws {
        let folder = try prepare(home: home)
        try write(JSONEncoder().encode(Heartbeat(pid: pid, updatedAt: now)), to: folder.appendingPathComponent(heartbeatName))
    }

    public static func removeHeartbeat(home: URL) {
        try? FileManager.default.removeItem(at: directory(home: home).appendingPathComponent(heartbeatName))
    }

    public static func appIsListening(home: URL, now: Date = .now) -> Bool {
        let url = directory(home: home).appendingPathComponent(heartbeatName)
        guard let data = readOwned(url), let beat = try? JSONDecoder().decode(Heartbeat.self, from: data),
              abs(now.timeIntervalSince(beat.updatedAt)) < 6, beat.pid > 0 else { return false }
        return kill(beat.pid, 0) == 0 || errno == EPERM
    }

    public static func send(_ reply: NotchReply, for requestID: String, home: URL) throws {
        guard UUID(uuidString: requestID) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = try prepare(home: home)
        try write(JSONEncoder().encode(reply), to: folder.appendingPathComponent(requestID + ".json"))
    }

    public static func take(requestID: String, home: URL) -> NotchReply? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        let url = directory(home: home).appendingPathComponent(requestID + ".json")
        guard let data = readOwned(url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(NotchReply.self, from: data)
    }

    public static func discard(requestID: String, home: URL) {
        guard UUID(uuidString: requestID) != nil else { return }
        try? FileManager.default.removeItem(at: directory(home: home).appendingPathComponent(requestID + ".json"))
    }

    public static func wait(for requestID: String, home: URL, limit: TimeInterval = waitLimit,
                            superseded: () -> Bool) -> NotchReply? {
        let deadline = Date.now.addingTimeInterval(limit)
        var checks = 0
        while Date.now < deadline {
            if let reply = take(requestID: requestID, home: home) { return reply }
            checks += 1
            if checks % 5 == 0 {
                if superseded() || !appIsListening(home: home) { return nil }
            }
            usleep(100_000)
        }
        return nil
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readOwned(_ url: URL) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= 64 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
}
