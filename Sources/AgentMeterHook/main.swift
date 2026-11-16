import Darwin
import Foundation
import UsageCore

umask(0o077)
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, let provider = Provider(rawValue: args[1]) else {
    print("Usage: AgentMeterHook --install|--remove claude|codex")
    exit(64)
}
let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser

switch args[0] {
case "--event", "--reply":
    var data = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: 16 * 1024), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= 1024 * 1024 else { exit(0) }
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let tty: String?
    if proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size,
       let device = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR)) {
        tty = "/dev/" + String(cString: device)
    } else {
        tty = nil
    }
    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let name = payload["hook_event_name"] as? String ?? ""
    let asksQuestion = name == "PreToolUse" && (payload["tool_name"] as? String)?.lowercased() == "askuserquestion"
    if args[0] == "--event" && asksQuestion && provider == .claude { exit(0) }
    guard let event = NotchActivity.parseEvent(data, provider: provider, environment: environment, tty: tty,
                                               pid: getppid(), reader: .files(home: home)) else { exit(0) }
    let store = home.appendingPathComponent(NotchActivityStore.relativePath)
    let activity = event.activity
    let interactive = args[0] == "--reply" && activity.canReply
        && (provider == .claude || activity.phase == .permission)
    if interactive, let request = NotchRequest.make(event: name, payload: payload),
       NotchReplyChannel.appIsListening(home: home) {
        let pending = activity.with(phase: request.kind == .question ? .question : .permission, request: request,
                                    at: .now)
        try? NotchActivityStore.record(pending, at: store)
        var superseded = false
        let reply = NotchReplyChannel.wait(for: request.id, home: home) {
            superseded = NotchActivityStore.read(store).first { $0.id == pending.id }?.request?.id != request.id
            return superseded
        }
        NotchReplyChannel.discard(requestID: request.id, home: home)
        if !superseded {
            let decided = reply.map { $0.decision != .pass } ?? false
            let next = pending.with(phase: decided ? .running : pending.phase, request: nil, at: .now)
            try? NotchActivityStore.record(next, at: store)
        }
        if let output = reply?.output(event: name, payload: payload) {
            FileHandle.standardOutput.write(output)
        }
        exit(0)
    }
    try? NotchActivityStore.record(event, at: store)
case "--install", "--remove":
    do {
        let backup = try HookSetup.update(provider, install: args[0] == "--install", home: home,
                                          environment: environment, executable: CommandLine.arguments[0])
        if let backup { print("Backup: " + backup.path) }
        if args[0] == "--install" {
            print(provider.title + " notch hooks configured.")
            if provider == .codex { print("Review and trust the AgentMeterHook entries in Codex /hooks.") }
        } else {
            print(provider.title + " notch hooks removed.")
        }
    } catch {
        FileHandle.standardError.write(Data(("Agent Meter could not update hooks: " + error.localizedDescription + "\n").utf8))
        exit(1)
    }
default:
    exit(64)
}
