import Darwin
import Foundation
import UsageCore

enum ProcessScanner {
    static func snapshot(home: URL) -> AgentProcessSnapshot {
        AgentProcessSnapshot(capturedAt: .now, groups: AgentProcessSnapshot.classify(list(), claudeSessions: sessions(home)),
                             remoteFolders: remoteFolders(home))
    }

    private static func list() -> [RawProcess] {
        var pids = [pid_t](repeating: 0, count: 16384)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let user = getuid()
        return pids.prefix(Int(count)).compactMap { pid -> RawProcess? in
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == user else { return nil }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let path = String(cString: buffer)
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let memory = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
                ? Int(task.pti_resident_size / 1_048_576) : 0
            let name = (path as NSString).lastPathComponent
            return RawProcess(pid: pid, ppid: Int32(info.pbi_ppid), path: path, arguments: arguments(pid),
                              memoryMB: memory, startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
                              cwd: name == "claude" || name == "codex" ? directory(pid) : nil)
        }
    }

    private static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= 1 << 20 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while index < size, result.count < min(Int(argc), 64) {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<min(index, start + 1024)], as: UTF8.self))
            index += 1
        }
        return result
    }

    private static func directory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    private static func sessions(_ home: URL) -> [Int32: ClaudeSessionRecord] {
        let folder = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "json" }.prefix(400)
        var records: [Int32: ClaudeSessionRecord] = [:]
        for file in files {
            guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ ($0 ?? .max) <= 64 * 1024 }) == true,
                  let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = object["pid"] as? Int, pid > 1, pid < Int(Int32.max) else { continue }
            records[Int32(pid)] = ClaudeSessionRecord(status: object["status"] as? String, kind: object["kind"] as? String)
        }
        return records
    }

    private static func remoteFolders(_ home: URL) -> [String] {
        let url = home.appendingPathComponent("Library/Application Support/Claude/remote-control-state.json")
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ ($0 ?? .max) <= 1024 * 1024 }) == true,
              let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identities = state["identities"] as? [String: Any] else { return [] }
        let folders = identities.values.compactMap { $0 as? [String: Any] }
            .filter { $0["serve"] as? String == "on" }
            .flatMap { (($0["folders"] as? [String: Any]) ?? [:]).keys }
        return Set(folders).sorted().prefix(20).map { ($0 as NSString).abbreviatingWithTildeInPath }
    }
}
