import AppKit
import Combine
import UsageCore

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var result = ScanResult()
    @Published private(set) var roots: [LogSource: URL] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var updatedAt: Date?
    let accounts = ServiceAccounts()
    let board = BoardLink()
    @Published private(set) var hiddenMenuItems = Set(UserDefaults.standard.stringArray(forKey: "menu-bar.hidden") ?? [])
    @Published var notchEnabled = UserDefaults.standard.object(forKey: "notch.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notchEnabled, forKey: "notch.enabled") }
    }
    @Published var alert: String?
    @Published private(set) var quotaHistory = MeterModel.loadHistory()
    @Published var days = 7 {
        didSet {
            guard oldValue != days else { return }
            var reset = result
            reset.sessions = []
            reset.dailyUsage = []
            reset.fableEstimateUSD = nil
            result = reset
            updatedAt = nil
            refresh()
        }
    }

    private let access = SourceAccess()
    private let scanner = UsageScanner()
    private var refreshPending = false
    private var generation = 0

    init() {
        loadSources()
        board.startIfEnabled()
    }

    func setMenuItem(_ id: String, visible: Bool) {
        if visible { hiddenMenuItems.remove(id) }
        else { hiddenMenuItems.insert(id) }
        UserDefaults.standard.set(hiddenMenuItems.sorted(), forKey: "menu-bar.hidden")
    }

    func choose(_ source: LogSource) {
        do {
            if try access.choose(source) { sourcesChanged() }
        } catch {
            alert = error.localizedDescription
        }
    }

    func remove(_ source: LogSource) {
        access.remove(source)
        sourcesChanged()
    }

    func refresh(force: Bool = false) {
        accounts.refresh(force: force)
        requestProcesses()
        guard !scanning else {
            refreshPending = true
            return
        }
        scanning = true
        let roots = roots
        let days = days
        let generation = generation
        let desktopHistory = access.desktopQuotaHistory
        let statisticsCache = access.statisticsUsageCache
        let liveQuota = access.claudeLiveQuota
        let grokUsage = access.grokUsage
        let codexUsage = access.codexUsage
        let agentProcesses = access.agentProcesses
        Task {
            let scoped = roots.filter { $0.value.startAccessingSecurityScopedResource() }
            var scan = await scanner.scan(scoped, days: days, desktopHistory: desktopHistory,
                                          statisticsCache: statisticsCache,
                                          liveQuota: liveQuota, grokUsage: grokUsage, codexUsage: codexUsage,
                                          agentProcesses: agentProcesses)
            for url in scoped.values { url.stopAccessingSecurityScopedResource() }
            scan.unreadable.formUnion(Set(roots.keys).subtracting(scoped.keys))
            if self.generation == generation && self.days == days {
                result = scan
                updatedAt = .now
                board.push(scan)
                let history = QuotaHistory.record(scan, into: quotaHistory)
                if history != quotaHistory {
                    quotaHistory = history
                    saveHistory()
                }
            }
            scanning = false
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    private var processesRequestedAt = Date.distantPast

    func requestProcesses() {
        guard Date.now.timeIntervalSince(processesRequestedAt) > 10, let url = access.agentProcessesRequest,
              FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
        processesRequestedAt = .now
        try? Data().write(to: url)
    }

    func processSetupCommand() -> String? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentMeterRefresh")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            alert = String(localized: "Open the packaged app to list background agent processes.")
            return nil
        }
        return quote(helper.path) + " --install-processes"
    }

    func refreshSetupCommand() -> String? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentMeterRefresh")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            alert = String(localized: "Open the packaged app to refresh Codex and Grok limits automatically.")
            return nil
        }
        return quote(helper.path) + " --install"
    }

    func copyClaudeSetup() {
        guard let folder = roots[.claudeProjects] else { return }
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentMeterStatus")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AccessError.helperMissing }
            let command = "\(quote(helper.path)) --projects \(quote(folder.path))"
            let settings = ["statusLine": ["type": "command", "command": command]]
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            copy(String(decoding: data, as: UTF8.self))
            alert = String(localized: "Status line configuration copied. Merge statusLine into Claude Code settings. Use your existing command in a wrapper if you want to keep its display.")
        } catch {
            alert = error.localizedDescription
        }
    }

    func openSession(_ session: SessionUsage) {
        if let url = session.provider.sessionURL(session.sessionID), NSWorkspace.shared.open(url) { return }
        Task {
            switch await SessionFocus.open(NotchActivity.recent(session)) {
            case .opened: break
            case .copied: alert = String(localized: "Resume command copied.")
            case .failed(let message): alert = message
            }
        }
    }

    func openCodexPlugin(_ text: String) {
        guard let url = Provider.codexPluginURL(text) else {
            alert = String(localized: "Enter a Codex plugin detail link in the form codex://plugins/<id>.")
            return
        }
        if !NSWorkspace.shared.open(url) { alert = String(localized: "macOS could not open the Codex link.") }
    }

    func copyResume(_ session: SessionUsage) {
        copy(session.provider.resumeCommand(session.sessionID))
        alert = String(localized: "Resume command copied.")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var historyURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Agent Meter/quota-history.json")
    }

    private static func loadHistory() -> [QuotaSample] {
        guard let url = historyURL, let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024 else { return [] }
        return (try? JSONDecoder().decode([QuotaSample].self, from: data)) ?? []
    }

    private func saveHistory() {
        guard let url = Self.historyURL, let data = try? JSONEncoder().encode(quotaHistory) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }

    private func loadSources() {
        for source in LogSource.allCases {
            do {
                roots[source] = try access.url(for: source)
            } catch {
                alert = String(localized: "Reconnect the \(source.folder) folder to restore read access.")
            }
        }
    }

    private func sourcesChanged() {
        generation += 1
        result = ScanResult()
        updatedAt = nil
        loadSources()
        refresh()
    }
}
