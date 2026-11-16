import AppKit
import Darwin
import UsageCore

@MainActor
final class SourceAccess {
    private let defaults = UserDefaults.standard

    func url(for source: LogSource) throws -> URL? {
        guard let bookmark = defaults.data(forKey: key(source)) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.lastPathComponent == source.folder else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            try save(url, for: source)
        }
        return url
    }

    func choose(_ source: LogSource) throws -> Bool {
        let panel = NSOpenPanel()
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "Connect \(source.provider.title) logs"
        panel.message = "Choose the \(source.folder) folder to grant read-only access."
        panel.prompt = "Connect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.showsHiddenFiles = true
        panel.directoryURL = suggestedFolder(for: source)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.lastPathComponent == source.folder,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AccessError.wrongFolder(source.folder)
        }
        try save(url, for: source)
        return true
    }

    func remove(_ source: LogSource) {
        defaults.removeObject(forKey: key(source))
    }

    var desktopQuotaHistory: URL? {
        homeDirectory?.appendingPathComponent(ClaudeQuota.desktopHistoryPath)
    }

    var statisticsUsageCache: URL? {
        homeDirectory?.appendingPathComponent(ClaudeQuota.statisticsCachePath)
    }

    var automaticClaudeUsage: URL? {
        homeDirectory?.appendingPathComponent(ClaudeLiveUsage.relativePath)
    }

    var claudeRefreshRequest: URL? {
        homeDirectory?.appendingPathComponent(ClaudeLiveUsage.refreshRequestPath)
    }

    var codexUsage: URL? {
        homeDirectory?.appendingPathComponent(CodexLiveUsage.relativePath)
    }

    var grokUsage: URL? {
        homeDirectory?.appendingPathComponent(GrokUsage.relativePath)
    }

    private var homeDirectory: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    private func suggestedFolder(for source: LogSource) -> URL? {
        guard let root = homeDirectory else { return nil }
        let config = root.appendingPathComponent(source.provider == .claude ? ".claude" : ".codex", isDirectory: true)
        return config.appendingPathComponent(source.folder, isDirectory: true)
    }

    private func save(_ url: URL, for source: LogSource) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: key(source))
    }

    private func key(_ source: LogSource) -> String { "read-only-folder.\(source.rawValue)" }
}

enum AccessError: LocalizedError {
    case wrongFolder(String)
    case helperMissing

    var errorDescription: String? {
        switch self {
        case .wrongFolder(let folder): "Choose the \(folder) folder itself."
        case .helperMissing: "Build and open the packaged app to use the status line helper."
        }
    }
}
