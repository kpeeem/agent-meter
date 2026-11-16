import Foundation
import UsageCore

enum HookSetup {
    static func update(_ provider: Provider, install: Bool, home: URL,
                       environment: [String: String], executable: String) throws -> URL? {
        let key = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let fallback = provider == .claude ? ".claude" : ".codex"
        let folder: URL
        if let path = environment[key], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw CocoaError(.fileWriteInvalidFileName) }
            folder = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            folder = home.appendingPathComponent(fallback, isDirectory: true)
        }
        let url = folder.appendingPathComponent(provider == .claude ? "settings.json" : "hooks.json")
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        if !exists && !install { return nil }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        let original = exists ? try Data(contentsOf: url) : nil
        var document: [String: Any] = [:]
        if let original {
            guard let decoded = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            document = decoded
        }
        if let hooks = document["hooks"], !(hooks is [String: Any]) { throw CocoaError(.fileReadCorruptFile) }
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        let path = URL(fileURLWithPath: executable).standardizedFileURL.path
        let suffix = " # agent-meter-notch"
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        func command(_ mode: String) -> String { quoted + " --" + mode + " " + provider.rawValue + suffix }
        func owned(_ value: String) -> Bool {
            value.hasSuffix(suffix) && value.contains("/Contents/Helpers/AgentMeterHook'")
                && (value.contains(" --event " + provider.rawValue + suffix)
                    || value.contains(" --reply " + provider.rawValue + suffix))
        }
        var desired = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop",
                       "SessionEnd"]
        desired += provider == .claude ? ["PostToolUseFailure", "Notification", "StopFailure"] : ["Interrupt"]
        func groups(for name: String) -> [[String: Any]] {
            func entry(_ mode: String, wait: Bool) -> [String: Any] {
                var value: [String: Any] = ["type": "command", "command": command(mode), "timeout": wait ? 300 : 3]
                if provider == .claude && !wait { value["async"] = true }
                return value
            }
            switch name {
            case "PermissionRequest":
                return [["hooks": [entry("reply", wait: true)]]]
            case "PreToolUse" where provider == .claude:
                return [["hooks": [entry("event", wait: false)]],
                        ["matcher": "AskUserQuestion", "hooks": [entry("reply", wait: true)]]]
            default:
                return [["hooks": [entry("event", wait: false)]]]
            }
        }
        let names = install ? Set(hooks.keys).union(desired) : Set(hooks.keys)
        for name in names {
            guard let existing = hooks[name] as? [[String: Any]] ?? (hooks[name] == nil ? [] : nil) else {
                if install && desired.contains(name) { throw CocoaError(.fileReadCorruptFile) }
                continue
            }
            var cleaned = existing.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let kept = entries.filter {
                    guard $0["type"] as? String == "command", let value = $0["command"] as? String else { return true }
                    return !owned(value)
                }
                if kept.count == entries.count { return group }
                if kept.isEmpty && Set(group.keys).isSubset(of: ["hooks", "matcher"]) { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            if install && desired.contains(name) { cleaned += groups(for: name) }
            if !cleaned.isEmpty || !existing.isEmpty {
                hooks[name] = cleaned.isEmpty ? nil : cleaned
            }
        }
        document["hooks"] = hooks.isEmpty && document["hooks"] == nil ? nil : hooks
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let original, let before = try JSONSerialization.jsonObject(with: original) as? NSDictionary,
           let after = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary,
           before.isEqual(after) { return nil }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? Data(contentsOf: url)) == original else { throw CocoaError(.fileLocking) }
        let backup = original.map { _ in url.appendingPathExtension("agent-meter-" + UUID().uuidString + ".bak") }
        if let original, let backup { try original.write(to: backup, options: [.atomic]) }
        let mode = (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        try bytes.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return backup
    }
}
