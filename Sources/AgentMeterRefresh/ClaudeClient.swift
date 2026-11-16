import Darwin
import Foundation
import Security
import UsageCore

enum ClaudeClient {
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)) ?? [])
            .filter { $0.lastPathComponent.allSatisfy { $0.isNumber || $0 == "." } }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for version in versions.prefix(5) {
            let builds = (try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil,
                                                                      options: .skipsHiddenFiles)) ?? []
            candidates += builds.map { $0.appendingPathComponent("claude.app/Contents/MacOS/claude") }
        }
        return candidates.map { $0.resolvingSymlinksInPath() }.first(where: isOfficial)
    }

    private static func isOfficial(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any] else { return false }
        return fields[kSecCodeInfoTeamIdentifier as String] as? String == "Q6L2SF6YDW"
            && fields[kSecCodeInfoIdentifier as String] as? String == "com.anthropic.claude-code"
    }

    static let configPath = "Library/Application Support/Agent Meter/claude-code"

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(configPath, isDirectory: true)
    }

    static var hasSeparateSignIn: Bool {
        let url = configDirectory.appendingPathComponent(".claude.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= 4 * 1024 * 1024,
              let bytes = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let account = state["oauthAccount"] as? [String: Any] else { return false }
        return !account.isEmpty
    }

    static func process(_ binary: URL, arguments: [String], separate: Bool) -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment(separate: separate)
        return process
    }

    static func login(_ binary: URL) throws -> Never {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var arguments = [binary.path, "auth", "login"].map { strdup($0) } + [nil]
        var loginEnvironment = environment(separate: true)
        loginEnvironment["BROWSER"] = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        loginEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        var variables = loginEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        _ = binary.path.withCString { execve($0, &arguments, &variables) }
        let code = errno
        arguments.forEach { free($0) }
        variables.forEach { free($0) }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func environment(separate: Bool) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TERM", "COLORTERM", "CLAUDE_CONFIG_DIR"] {
            if let value = getenv(key) { environment[key] = String(cString: value) }
        }
        if separate { environment["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        if let account = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_name) }) {
            environment["USER"] = account
            environment["LOGNAME"] = account
        }
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_FEEDBACK_COMMAND"] = "1"
        environment["CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY"] = "1"
        environment["CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL"] = "1"
        return environment
    }

    static func fetch() -> ClaudeLiveUsage {
        guard let binary = locate() else { return ClaudeLiveUsage(status: .clientMissing) }
        let separate = hasSeparateSignIn
        var usage = fetch(binary, separate: separate)
        usage.separateSignIn = separate
        return usage
    }

    private static func fetch(_ binary: URL, separate: Bool) -> ClaudeLiveUsage {
        let process = process(binary, arguments: ["--print", "--verbose", "--safe-mode", "--no-session-persistence",
                                                "--setting-sources", "", "--input-format", "stream-json",
                                                "--output-format", "stream-json"], separate: separate)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let directory = configDirectory.deletingLastPathComponent().appendingPathComponent("claude-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        process.currentDirectoryURL = directory
        let queue = DispatchQueue(label: "local.agentmeter.claude-reader")
        let finished = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
            finished.signal()
        }
        do { try process.run() } catch { return ClaudeLiveUsage(status: .unavailable) }
        let source = DispatchSource.makeReadSource(fileDescriptor: output.fileHandleForReading.fileDescriptor, queue: queue)
        var pending = Data()
        var totalBytes = 0
        var result: ClaudeLiveUsage?
        func send(_ id: String, request: [String: Any]) throws {
            let payload: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        source.setEventHandler {
            guard result == nil else { return }
            let data = output.fileHandleForReading.availableData
            totalBytes += data.count
            guard !data.isEmpty, totalBytes <= 4 * 1024 * 1024 else { finished.signal(); return }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]
                defer { pending.removeSubrange(...end) }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "control_response",
                      let response = object["response"] as? [String: Any],
                      let id = response["request_id"] as? String else { continue }
                guard response["subtype"] as? String == "success" else {
                    result = ClaudeLiveUsage(status: .unavailable)
                    finished.signal()
                    return
                }
                if id == "meter-initialize" {
                    do { try send("meter-usage", request: ["subtype": "get_usage", "skip_behaviors": true]) }
                    catch { finished.signal() }
                } else if id == "meter-usage", let usage = response["response"] as? [String: Any],
                          let bytes = try? JSONSerialization.data(withJSONObject: usage) {
                    result = ClaudeLiveUsage.parse(bytes)
                    finished.signal()
                    return
                }
            }
        }
        source.resume()
        do { try send("meter-initialize", request: ["subtype": "initialize", "hooks": [:]]) }
        catch { finished.signal() }
        let timedOut = finished.wait(timeout: .now() + 35) == .timedOut
        let reading = queue.sync { () -> ClaudeLiveUsage in
            source.cancel()
            return result ?? ClaudeLiveUsage(status: timedOut ? .timedOut : .unavailable)
        }
        try? input.fileHandleForWriting.close()
        if terminated.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }
        try? output.fileHandleForReading.close()
        return reading
    }
}
