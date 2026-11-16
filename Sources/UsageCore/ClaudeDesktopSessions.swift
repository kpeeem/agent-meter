import Darwin
import Foundation

public enum ClaudeDesktopSessions {
    public static let relativePath = "Library/Application Support/Claude/claude-code-sessions"

    private struct Record: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let lastActivityAt: Double?
    }

    public static func sessionID(for cliSession: UUID, home: URL) -> String? {
        let root = home.appendingPathComponent(relativePath, isDirectory: true)
        let target = cliSession.uuidString.lowercased()
        var best: (id: String, activity: Double)?
        for folder in folders(in: root) {
            let direct = folder.appendingPathComponent("local_\(target).json")
            if let record = read(direct), valid(record.sessionId) { return record.sessionId }
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                guard let record = read(file), record.cliSessionId?.lowercased() == target, valid(record.sessionId) else { continue }
                let activity = record.lastActivityAt ?? 0
                if best.map({ activity > $0.activity }) ?? true { best = (record.sessionId, activity) }
            }
        }
        return best?.id
    }

    public static func url(for sessionID: String) -> URL? {
        guard valid(sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }

    static func valid(_ id: String) -> Bool {
        id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
    }

    private static func folders(in root: URL) -> [URL] {
        let manager = FileManager.default
        let accounts = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return accounts.prefix(16).flatMap { account in
            ((try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .prefix(16)
        }
    }

    private static func read(_ url: URL) -> Record? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= 2 * 1024 * 1024, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}
