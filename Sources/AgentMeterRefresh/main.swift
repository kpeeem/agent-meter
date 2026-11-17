import AppKit
import Darwin
import Foundation
import UsageCore

let manager = FileManager.default
let userHome = manager.homeDirectoryForCurrentUser
let snapshotURL = userHome.appendingPathComponent(ClaudeLiveUsage.relativePath)
let requestURL = userHome.appendingPathComponent(ClaudeLiveUsage.refreshRequestPath)
let agentURL = userHome.appendingPathComponent("Library/LaunchAgents/local.agentmeter.refresh.plist")
let label = "local.agentmeter.refresh"
let processLabel = "local.agentmeter.processes"
let processAgentURL = userHome.appendingPathComponent("Library/LaunchAgents/local.agentmeter.processes.plist")
let processRequestURL = userHome.appendingPathComponent(AgentProcessSnapshot.requestPath)
umask(0o077)

func launchctl(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func install(label: String, at url: URL, argument: String, interval: Int, watch: URL) throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    guard executable.lastPathComponent == "AgentMeterRefresh",
          executable.deletingLastPathComponent().lastPathComponent == "Helpers" else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    if manager.fileExists(atPath: url.path) {
        let existing = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        guard existing?["Label"] as? String == label,
              let arguments = existing?["ProgramArguments"] as? [String],
              arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "AgentMeterRefresh" else {
            throw CocoaError(.fileWriteFileExists)
        }
    }
    let plist: [String: Any] = [
        "Label": label, "ProgramArguments": [executable.path, argument],
        "RunAtLoad": true, "StartInterval": interval, "ProcessType": "Background", "WatchPaths": [watch.path],
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
    ]
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
    try data.write(to: url, options: .atomic)
    guard try launchctl(["bootstrap", "gui/\(getuid())", url.path]) == 0 else { throw CocoaError(.executableLoad) }
}

func refresh(background: Bool) throws {
    let old = ClaudeLiveUsage.read(snapshotURL)
    let requestedAt = (try? requestURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    let requested = requestedAt.map { $0 > (old?.attemptedAt ?? .distantPast) } ?? false
    if background, !requested, let old, old.waiting() {
        print(old.message())
    } else {
        var usage = ClaudeClient.fetch()
        usage.keep(old)
        let folder = snapshotURL.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(usage)
        try bytes.write(to: snapshotURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        print(usage.message())
    }
    let codexURL = userHome.appendingPathComponent(CodexLiveUsage.relativePath)
    let oldCodex = CodexLiveUsage.read(codexURL)
    if !(background && oldCodex?.waiting() == true), var codex = CodexClient.fetch(home: userHome) {
        codex.keep(oldCodex)
        try JSONEncoder().encode(codex).write(to: codexURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codexURL.path)
        print(codex.status.message)
    }
    guard var grok = GrokBot.fetch(home: userHome) else { return }
    let grokURL = userHome.appendingPathComponent(GrokUsage.relativePath)
    if grok.status != .ready, let old = GrokUsage.read(grokURL) {
        grok.quota = old.quota
        grok.plan = grok.plan ?? old.plan
    }
    try JSONEncoder().encode(grok).write(to: grokURL, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: grokURL.path)
    print(grok.status.message)
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["--install"]:
        try install(label: label, at: agentURL, argument: "--background", interval: 300, watch: requestURL)
        print("Automatic Claude refresh enabled. Runs every 5 minutes while Agent Meter is open.")
    case ["--install-processes"]:
        try install(label: processLabel, at: processAgentURL, argument: "--processes",
                    interval: Int(AgentProcessSnapshot.interval), watch: processRequestURL)
        print("Agent Meter now lists running agent processes every 30 seconds while it is open.")
    case ["--uninstall-processes"]:
        _ = try launchctl(["bootout", "gui/\(getuid())/\(processLabel)"])
        if manager.fileExists(atPath: processAgentURL.path) { try manager.removeItem(at: processAgentURL) }
        print("Process list disabled.")
    case ["--processes"]:
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "local.agentmeter.mac").isEmpty {
            let url = userHome.appendingPathComponent(AgentProcessSnapshot.relativePath)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let snapshot = ProcessScanner.snapshot(home: userHome).remembering(AgentProcessSnapshot.read(url))
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    case ["--uninstall"]:
        _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if manager.fileExists(atPath: agentURL.path) { try manager.removeItem(at: agentURL) }
        print("Automatic Claude refresh disabled.")
    case ["--login"]:
        guard let binary = ClaudeClient.locate() else {
            print("Install the official Claude Code client first.")
            exit(1)
        }
        try ClaudeClient.login(binary)
    case ["--background"]:
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "local.agentmeter.mac").isEmpty {
            try refresh(background: true)
        }
    case ["--refresh"]:
        try refresh(background: false)
    case let arguments where arguments.count == 1 && arguments[0].hasPrefix("https://"):
        guard let url = URL(string: arguments[0]) else { exit(64) }
        let workspace = NSWorkspace.shared
        if let firefox = workspace.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") {
            let done = DispatchSemaphore(value: 0)
            workspace.open([url], withApplicationAt: firefox, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                done.signal()
            }
            _ = done.wait(timeout: .now() + 10)
        } else if !workspace.open(url) {
            exit(1)
        }
    default:
        print("Usage: AgentMeterRefresh --install | --uninstall | --login | --refresh | --install-processes | --uninstall-processes")
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("Agent Meter could not complete the refresh setup.\n".utf8))
    exit(1)
}
