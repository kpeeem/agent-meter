import Foundation

public struct AgentProcessGroup: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case remote, ephemeral, scripted, session, mcp, helper, app
    }

    public let kind: Kind
    public let provider: Provider?
    public let owner: String
    public let title: String
    public var count: Int
    public var idle: Int
    public var memoryMB: Int
    public var startedAt: Date?
    public var cwd: String?
    public var pid: Int32?

    public var id: String { [kind.rawValue, owner, title, pid.map(String.init) ?? ""].joined(separator: "/") }

    public var origin: WorkOrigin? {
        guard kind == .scripted || kind == .ephemeral else { return nil }
        return provider == .codex ? .codexScripted : .claudeScripted
    }
}

public struct AgentProcessSnapshot: Codable, Sendable, Equatable {
    public static let relativePath = "Library/Application Support/Agent Meter/agent-processes.json"
    public static let requestPath = "Library/Application Support/Agent Meter/agent-processes-request"
    public static let interval: TimeInterval = 30

    public static let ghostRetention: TimeInterval = 7 * 86_400

    public let capturedAt: Date
    public var groups: [AgentProcessGroup]
    public var remoteFolders: [String]
    public var seen: [GhostRun]?

    public init(capturedAt: Date, groups: [AgentProcessGroup], remoteFolders: [String], seen: [GhostRun]? = nil) {
        self.capturedAt = capturedAt
        self.groups = groups
        self.remoteFolders = remoteFolders
        self.seen = seen
    }

    public func remembering(_ old: Self?) -> Self {
        var runs = Dictionary((old?.seen ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in ghosts {
            guard let pid = group.pid, let started = group.startedAt else { continue }
            let id = "\(pid)-\(Int(started.timeIntervalSince1970))"
            runs[id] = GhostRun(id: id, provider: group.provider ?? .claude, owner: group.owner, title: group.title,
                                cwd: group.cwd, startedAt: started, lastSeen: capturedAt)
        }
        var copy = self
        copy.seen = runs.values.filter { capturedAt.timeIntervalSince($0.lastSeen) < Self.ghostRetention }
            .sorted { $0.startedAt > $1.startedAt }.prefix(1000).map { $0 }
        return copy
    }

    public func isFresh(at now: Date = .now) -> Bool {
        capturedAt <= now.addingTimeInterval(60) && now.timeIntervalSince(capturedAt) < 4 * Self.interval
    }

    public var ghosts: [AgentProcessGroup] { groups.filter { $0.origin != nil } }

    public func notchActivities() -> [NotchActivity] {
        ghosts.compactMap { group in
            guard let pid = group.pid, let started = group.startedAt else { return nil }
            var bytes = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: UInt32(bitPattern: pid).bigEndian) { bytes.replaceSubrange(0..<4, with: $0) }
            withUnsafeBytes(of: UInt64(started.timeIntervalSince1970).bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
            bytes[6] = bytes[6] & 0x0F | 0x40
            bytes[8] = bytes[8] & 0x3F | 0x80
            bytes[12...15] = [0x61, 0x6D, 0x70, 0x73]
            let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            let note = group.kind == .ephemeral ? "Runs without a transcript. Started by \(group.owner)."
                : "Started by \(group.owner)."
            return NotchActivity(provider: group.provider ?? .claude, session: id, phase: .running, cwd: group.cwd,
                                 host: nil, terminalID: nil, updatedAt: capturedAt, message: note, startedAt: started,
                                 pid: pid, origin: group.origin)
        }
    }

    public static func read(_ url: URL) -> Self? {
        guard let file = try? openLog(url), let data = try? file.read(upToCount: 256 * 1024 + 1),
              data.count <= 256 * 1024, let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.groups.count <= 200,
              snapshot.groups.allSatisfy({ $0.count >= 0 && $0.idle >= 0 && $0.memoryMB >= 0 }) else { return nil }
        return snapshot
    }
}

public struct GhostRun: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: Provider
    public let owner: String
    public let title: String
    public let cwd: String?
    public let startedAt: Date
    public let lastSeen: Date
}

public struct RawProcess: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let path: String
    public let arguments: [String]
    public let memoryMB: Int
    public let startedAt: Date
    public let cwd: String?

    public init(pid: Int32, ppid: Int32, path: String, arguments: [String], memoryMB: Int, startedAt: Date,
                cwd: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        self.arguments = arguments
        self.memoryMB = memoryMB
        self.startedAt = startedAt
        self.cwd = cwd
    }

    var name: String { (path as NSString).lastPathComponent }
    var label: String {
        let interpreters = ["node", "bash", "zsh", "sh", "ruby", "perl", "bun", "deno", "uv", "osascript"]
        guard interpreters.contains(name) || name.hasPrefix("python"),
              let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return name }
        return (script as NSString).lastPathComponent
    }
    var isClaudeCode: Bool {
        name == "claude" || arguments.contains { $0.hasSuffix("@anthropic-ai/claude-code/cli.js") }
    }
    var isCodexCLI: Bool { name == "codex" }

    var codexCommand: String? {
        let valued: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-C", "--cd",
                                   "-s", "--sandbox", "-a", "--ask-for-approval", "-i", "--image"]
        var skip = false
        for argument in arguments.dropFirst() {
            if skip { skip = false; continue }
            if valued.contains(argument) { skip = true; continue }
            if argument.hasPrefix("-") { continue }
            return argument
        }
        return nil
    }
}

public struct ClaudeSessionRecord: Sendable {
    public let status: String?
    public let kind: String?

    public init(status: String?, kind: String?) {
        self.status = status
        self.kind = kind
    }
}

extension AgentProcessSnapshot {
    public static func classify(_ processes: [RawProcess], claudeSessions: [Int32: ClaudeSessionRecord] = [:],
                                now: Date = .now) -> [AgentProcessGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        func ancestors(_ process: RawProcess) -> [RawProcess] {
            var chain: [RawProcess] = []
            var current = byPID[process.ppid]
            while let next = current, chain.count < 16, next.pid > 1 {
                chain.append(next)
                current = next.ppid == next.pid ? nil : byPID[next.ppid]
            }
            return chain
        }

        func host(_ process: RawProcess) -> String {
            for parent in ancestors(process) {
                let path = parent.path
                if path.contains("AgentMeter") || path.contains("Agent Meter.app") { return "Agent Meter" }
                if path.contains("SkyComputerUse") { return "Codex computer use" }
                if path.contains("/Claude.app/") { return "Claude Desktop" }
                if path.contains("/Codex.app/") { return "Codex app" }
                if path.contains("Visual Studio Code") || path.contains("/Code Helper") { return "VS Code" }
                if path.contains("/Cursor.app/") { return "Cursor" }
                if path.contains("/Terminal.app/") { return "Terminal" }
                if path.contains("/iTerm.app/") { return "iTerm" }
                if path.contains("/Ghostty.app/") { return "Ghostty" }
                if path.contains("/Warp.app/") { return "Warp" }
                if path.contains("/WezTerm.app/") { return "WezTerm" }
                if path.contains("/kitty.app/") { return "kitty" }
                if parent.isClaudeCode { return "Claude Code" }
                if parent.isCodexCLI { return "Codex" }
            }
            let root = ancestors(process).last ?? process
            guard root.ppid <= 1 else { return "other" }
            return root.pid == process.pid ? "launchd" : "launchd · " + root.label
        }

        func agentOwner(_ process: RawProcess) -> Provider? {
            let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "login"]
            guard !shells.contains(process.name) else { return nil }
            for parent in ancestors(process).prefix(2) {
                if parent.isClaudeCode { return .claude }
                if parent.isCodexCLI { return .codex }
                if shells.contains(parent.name) { return nil }
            }
            return nil
        }

        func mcpName(_ process: RawProcess) -> String? {
            let title = process.arguments.first.map { !$0.hasPrefix("/") && $0.contains(" ") } == true
                ? process.arguments[0].split(separator: " ").map(String.init) : []
            let tokens = (title + process.arguments.dropFirst()).filter { !$0.isEmpty && $0 != process.path }
            guard (tokens + [process.path]).contains(where: { $0.range(of: "mcp", options: .caseInsensitive) != nil })
            else { return nil }
            for token in tokens {
                let parts = token.split(separator: "/").map(String.init)
                if let bin = parts.firstIndex(of: ".bin"), bin + 1 < parts.count { return parts[bin + 1] }
                if parts.contains("plugins"), let cache = parts.firstIndex(of: "cache"), cache + 2 < parts.count {
                    return parts[cache + 2]
                }
                if let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count {
                    let package = parts[modules + 1]
                    return package.hasPrefix("@") && modules + 2 < parts.count ? package + "/" + parts[modules + 2] : package
                }
                if token.hasPrefix("@"), parts.count == 2 {
                    let name = parts[1].split(separator: "@").first.map(String.init) ?? parts[1]
                    return name == "mcp" ? String(parts[0].dropFirst()) + "-mcp" : name
                }
            }
            if let named = tokens.first(where: {
                !$0.hasPrefix("-") && ($0 as NSString).lastPathComponent.lowercased().contains("mcp")
                    && ($0 as NSString).lastPathComponent.lowercased() != "mcp"
            }) ?? (process.name.lowercased().contains("mcp") ? process.path : nil) {
                return (named as NSString).lastPathComponent
            }
            guard let script = tokens.first(where: {
                !$0.hasPrefix("-") && ($0 as NSString).lastPathComponent != process.name
            }) else { return process.name }
            let generic: Set<String> = ["dist", "build", "src", "lib", "bin", "out", "scripts", "server"]
            var url = URL(fileURLWithPath: script)
            if url.pathExtension.isEmpty { return url.lastPathComponent }
            url.deleteLastPathComponent()
            while generic.contains(url.lastPathComponent), url.pathComponents.count > 2 { url.deleteLastPathComponent() }
            return url.lastPathComponent.isEmpty ? (script as NSString).lastPathComponent : url.lastPathComponent
        }

        var groups: [String: AgentProcessGroup] = [:]
        func add(_ kind: AgentProcessGroup.Kind, _ provider: Provider?, owner: String, title: String,
                 process: RawProcess, idle: Bool = false, single: Bool = false) {
            let key = [kind.rawValue, owner, title, single ? String(process.pid) : ""].joined(separator: "/")
            var group = groups[key] ?? AgentProcessGroup(kind: kind, provider: provider, owner: owner, title: title,
                                                         count: 0, idle: 0, memoryMB: 0, startedAt: nil,
                                                         cwd: single ? process.cwd : nil, pid: single ? process.pid : nil)
            group.count += 1
            group.idle += idle ? 1 : 0
            group.memoryMB += process.memoryMB
            group.startedAt = min(group.startedAt ?? process.startedAt, process.startedAt)
            groups[key] = group
        }

        for process in processes where process.pid > 1 {
            let path = process.path
            if process.isClaudeCode {
                let owner = host(process)
                let printing = process.arguments.contains("-p") || process.arguments.contains("--print")
                if printing {
                    let ephemeral = process.arguments.contains("--no-session-persistence")
                    add(ephemeral ? .ephemeral : .scripted, .claude, owner: owner,
                        title: ephemeral ? "claude -p · no transcript" : "claude -p", process: process, single: true)
                } else {
                    let record = claudeSessions[process.pid]
                    add(.session, .claude, owner: owner, title: "Claude Code sessions", process: process,
                        idle: record?.status == "idle")
                }
            } else if process.isCodexCLI {
                let owner = host(process)
                switch process.codexCommand {
                case "app-server": add(.helper, .codex, owner: owner, title: "Codex app server", process: process)
                case "exec-server" where process.arguments.contains("--remote"):
                    add(.remote, .codex, owner: owner, title: "Codex cloud environment", process: process)
                case "exec-server": add(.helper, .codex, owner: owner, title: "Codex exec server", process: process)
                case "exec", "e":
                    let ephemeral = process.arguments.contains("--ephemeral")
                    let source = process.arguments.firstIndex(of: "--thread-source").flatMap {
                        process.arguments.indices.contains($0 + 1) ? process.arguments[$0 + 1] : nil
                    }
                    let title = ["codex exec", source?.replacingOccurrences(of: "_", with: " "),
                                 ephemeral ? "no transcript" : nil].compactMap { $0 }.joined(separator: " · ")
                    add(ephemeral ? .ephemeral : .scripted, .codex, owner: owner, title: title, process: process,
                        single: true)
                case "mcp-server", "mcp": add(.helper, .codex, owner: owner, title: "Codex MCP server", process: process)
                case nil, "resume", "fork": add(.session, .codex, owner: owner, title: "Codex CLI sessions", process: process)
                case let command?: add(.helper, .codex, owner: owner, title: "codex " + command, process: process)
                }
            } else if let provider = agentOwner(process), let name = mcpName(process),
                      !path.contains("/Claude.app/"), !path.contains("/Codex.app/Contents/Frameworks/") {
                add(.mcp, provider, owner: provider == .claude ? "Claude" : "Codex", title: name, process: process)
            } else if path.contains("/Codex.app/Contents/Resources/") || path.contains("/.codex/") {
                let title: String
                switch process.name {
                case "node_repl": title = "Codex JavaScript REPL"
                case "codex-code-mode-host": title = "Codex code mode"
                case let name where name.hasPrefix("SkyComputerUse"): title = "Codex computer use"
                default: title = process.label
                }
                add(.helper, .codex, owner: "Codex app", title: title, process: process)
            } else if path.contains("/Library/Application Support/Codex/") {
                add(.helper, .codex, owner: "Codex app", title: "Codex artifacts", process: process)
            } else if path.contains("/Claude.app/"), process.name != "disclaimer" {
                add(.app, .claude, owner: "Claude Desktop", title: "Claude Desktop app", process: process)
            } else if path.contains("/Codex.app/") {
                add(.app, .codex, owner: "Codex app", title: "Codex app", process: process)
            }
        }
        let order = AgentProcessGroup.Kind.allCases
        return groups.values.sorted {
            let left = order.firstIndex(of: $0.kind) ?? 0, right = order.firstIndex(of: $1.kind) ?? 0
            return left == right ? $0.memoryMB > $1.memoryMB : left < right
        }.prefix(120).map { $0 }
    }
}
