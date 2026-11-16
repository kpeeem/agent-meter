import Darwin
import Foundation
import UsageCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--quiet"),
      arguments[0] == "--projects", arguments[1].hasPrefix("/") else {
    FileHandle.standardError.write(Data("Usage: AgentMeterStatus --projects /path/to/projects [--quiet]\n".utf8))
    exit(64)
}

do {
    let maxInput = 1024 * 1024
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, maxInput + 1 - input.count)),
          !chunk.isEmpty {
        input.append(chunk)
        if input.count > maxInput { exit(65) }
    }
    let now = Date.now
    let projects = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let quotas = try ClaudeQuota.capture(input, at: now)
    let fable = ClaudeQuota.captureFable(in: projects, at: now)
    try ClaudeQuota.store(quotas, in: projects, fable: fable)
    if arguments.count == 2 {
        let status = quotas.map { "\($0.window.title) \(Int($0.used.rounded()))% used" }
        print(status.isEmpty ? "Claude Code" : "Claude · " + status.joined(separator: " · "))
    }
} catch {
    FileHandle.standardError.write(Data("Agent Meter could not capture the Claude Code limits.\n".utf8))
    exit(1)
}
