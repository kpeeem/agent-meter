import AppKit
import Charts
import Combine
import SwiftUI
import UsageCore

@MainActor
final class StatsViewController: PreferencePaneViewController {
    private let model: MeterModel
    private var provider: Provider?
    private let tiles = verticalStack([], spacing: Spacing.s)
    private let heatmap = YearHeatmapView()
    private let heatmapCaption = NSTextField(labelWithString: "")
    private let composition = SegmentedCompositionView()
    private let compositionTotal = NSTextField(labelWithString: "")
    private let topProjects = verticalStack([], spacing: Spacing.xxs)
    private let projects = ProjectsOutlineView()
    private var selectedDay: YearHeatmapView.Day?
    private let history = NSHostingView(rootView: QuotaHistoryChart(samples: []))
    private let background = verticalStack([], spacing: 7)
    private var updates = Set<AnyCancellable>()

    init(model: MeterModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        addFullWidth(tiles)
        buildHeatmap()
        history.translatesAutoresizingMaskIntoConstraints = false
        history.heightAnchor.constraint(equalToConstant: 200).isActive = true
        addSection(title: "Limits history", subtitle: "Share of each limit used over the last 7 days. Dashed lines are 5-hour windows.",
                   symbol: "chart.xyaxis.line", body: history)
        addSection(title: "Background", subtitle: "Agents and helpers that run without a window of their own, including runs that keep no transcript.",
                   symbol: "eye", body: background)
        buildBottomGrid()
        projects.onOpenSession = { [weak model] in model?.openSession($0) }
        projects.onCopyResume = { [weak model] in model?.copyResume($0) }
        addSection(title: "Projects", subtitle: "Expand a project to see its sessions.",
                   symbol: "folder", body: projects)
        model.$result.sink { [weak self] result in self?.render(result) }.store(in: &updates)
        model.$quotaHistory.sink { [weak self] _ in self?.renderHistory() }.store(in: &updates)
    }

    private func buildHeader() {
        let title = NSTextField(labelWithString: "Activity")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Claude Code and Codex sessions on this Mac")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = Palette.secondaryText
        let heading = verticalStack([title, subtitle], spacing: 2, alignment: .leading)
        let providers = PillSegmentedControl(options: ["Both", "Claude", "Codex"]) { [weak self] index in
            guard let self else { return }
            provider = index == 0 ? nil : Provider.allCases[index - 1]
            render(model.result)
            renderHistory()
        }
        let ranges = PillSegmentedControl(options: ["30d", "7d"], selectedIndex: model.days == 7 ? 1 : 0) {
            [weak model] index in model?.days = index == 0 ? 30 : 7
        }
        let controls = horizontalStack([providers, ranges], spacing: Spacing.xs)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        addFullWidth(horizontalStack([heading, flexibleSpacer(), controls], spacing: Spacing.s))
    }

    private func buildHeatmap() {
        heatmap.onHoverDay = { [weak self] day in self?.updateHeatmapCaption(day) }
        heatmap.onSelectDay = { [weak self] day in
            guard let self else { return }
            selectedDay = day
            heatmap.selectedDate = day.date
            updateHeatmapCaption(day)
        }
        heatmapCaption.font = Typography.mono(11, weight: .medium)
        heatmapCaption.textColor = Palette.secondaryText
        let stack = verticalStack([heatmap, heatmapCaption], alignment: .leading)
        heatmap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addSection(title: "Activity calendar", subtitle: "Each cell is one day. The selected range supplies the totals.",
                   symbol: "square.grid.3x3", body: stack)
    }

    private func buildBottomGrid() {
        compositionTotal.font = Typography.mono(11)
        compositionTotal.textColor = Palette.secondaryText
        let compositionHeader = horizontalStack([Typography.caption("Token composition"), flexibleSpacer(), compositionTotal],
                                                alignment: .firstBaseline)
        let compositionCard = MenubarCardView(content: verticalStack([compositionHeader, composition], spacing: Spacing.s),
                                              horizontal: Spacing.m, vertical: Spacing.m)
        let projectStack = verticalStack([Typography.caption("Top projects"), topProjects],
                                         spacing: Spacing.s, alignment: .leading)
        topProjects.widthAnchor.constraint(equalTo: projectStack.widthAnchor).isActive = true
        let projectCard = MenubarCardView(content: projectStack, horizontal: Spacing.m, vertical: Spacing.m)
        let grid = horizontalStack([compositionCard, projectCard], spacing: Spacing.m, alignment: .top)
        compositionCard.widthAnchor.constraint(equalTo: projectCard.widthAnchor, multiplier: 1.35).isActive = true
        addFullWidth(grid)
    }

    private func render(_ result: ScanResult) {
        let rows = result.projects(for: provider)
        let totals = rows.reduce(Tokens()) { $0 + $1.tokens }
        let sessions = rows.reduce(0) { $0 + $1.sessions.filter { !$0.isService }.count }
        let daily = result.dailyUsage.filter { provider == nil || provider == $0.provider }
        let activeDays = Set(daily.map(\.date)).count
        let numbers = [
            ("Sessions", sessions.formatted()),
            ("Tokens (in + out)", compact(totals.total)),
            ("Active days", "\(activeDays)/\(model.days)"),
            ("Projects", rows.count.formatted()),
            ("Cached input", compact(totals.cached)),
            ("Output tokens", compact(totals.output)),
        ]
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for offset in stride(from: 0, to: numbers.count, by: 3) {
            let cards = numbers[offset..<(offset + 3)].map { StatTileView(caption: $0.0, value: $0.1) }
            let row = horizontalStack(cards, spacing: Spacing.s, alignment: .top)
            row.distribution = .fillEqually
            tiles.addArrangedSubview(row)
        }

        renderCalendar(daily)
        renderBackground(result)
        compositionTotal.stringValue = compact(totals.total) + " total"
        composition.segments = [
            .init(label: "Input", value: UInt64(totals.input), color: Palette.accent),
            .init(label: "Output", value: UInt64(totals.output), color: Palette.accent.withAlphaComponent(0.73)),
            .init(label: "Cache read", value: UInt64(totals.cached), color: Palette.accent.withAlphaComponent(0.45)),
            .init(label: "Cache write", value: UInt64(totals.cacheWrite), color: Palette.accent.withAlphaComponent(0.26)),
        ]

        topProjects.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let first = rows.first {
            for project in rows.prefix(5) {
                topProjects.addArrangedSubview(ProjectBarRow(
                    name: project.name, fraction: CGFloat(project.tokens.total) / CGFloat(max(1, first.tokens.total)),
                    value: compact(project.tokens.total)
                ))
            }
        } else {
            let empty = NSTextField(labelWithString: "No usage in this period")
            empty.textColor = Palette.secondaryText
            topProjects.addArrangedSubview(empty)
        }
        projects.update(rows)
    }

    private func renderCalendar(_ daily: [DailyUsage]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let usageByDate = Dictionary(grouping: daily, by: \.date)
        heatmap.values = (0..<365).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            guard offset < model.days else { return .init(date: date, tokens: nil, sessions: 0) }
            let usage = usageByDate[date] ?? []
            return .init(date: date,
                         tokens: usage.reduce(Tokens()) { $0 + $1.tokens }.total,
                         sessions: usage.reduce(0) { $0 + $1.sessions })
        }
        if let date = selectedDay?.date {
            selectedDay = heatmap.values.first { $0.date == date }
        }
        heatmap.selectedDate = selectedDay?.date
        updateHeatmapCaption(nil)
    }

    private func updateHeatmapCaption(_ hover: YearHeatmapView.Day?) {
        guard let day = hover ?? selectedDay else {
            heatmapCaption.stringValue = "Hover or select a day · \(model.days) days in scope"
            return
        }
        let date = day.date.formatted(.dateTime.month(.abbreviated).day().year())
        if let tokens = day.tokens {
            heatmapCaption.stringValue = "\(date) · \(compact(tokens)) tokens · \(day.sessions) sessions"
        } else {
            heatmapCaption.stringValue = "\(date) · Outside the selected period"
        }
    }

    private func renderBackground(_ result: ScanResult) {
        background.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let now = Date.now
        let snapshot = result.agentProcesses
        let time = Date.FormatStyle().hour().minute()
        background.addArrangedSubview(heading("Running now", trailing: snapshot.map { "Checked " + $0.capturedAt.formatted(time) }))
        if snapshot == nil {
            background.addArrangedSubview(caption("Turn on Settings → Background agents to list running agent processes."))
        } else if snapshot?.isFresh(at: now) == false {
            background.addArrangedSubview(caption("This list is out of date. The background helper may be off: Settings → Background agents.",
                                                  color: Palette.urgencyAmber))
        }
        if let folders = snapshot?.remoteFolders, !folders.isEmpty, provider != .codex {
            background.addArrangedSubview(row("Claude Remote Control",
                                              detail: "Sessions can start from claude.ai or the phone in " + folders.joined(separator: ", "),
                                              value: "On", tint: Palette.accent))
        }
        for group in snapshot?.groups ?? [] where provider == nil || group.provider == provider {
            background.addArrangedSubview(row(group.title, detail: describe(group, now: now),
                                              value: (group.count > 1 ? "\(group.count) × " : "") + memory(group.memoryMB),
                                              tint: group.kind == .remote || group.kind == .ephemeral ? Palette.accent : nil))
        }

        let day = now.addingTimeInterval(-86_400)
        let seen = Dictionary(grouping: (snapshot?.seen ?? []).filter {
            $0.startedAt >= day && (provider == nil || $0.provider == provider)
        }, by: { $0.title + " · " + $0.owner })
        if !seen.isEmpty {
            background.addArrangedSubview(DividerView())
            background.addArrangedSubview(heading("Seen in the last 24 hours", trailing: "Checked every 30 s"))
            for (title, runs) in seen.sorted(by: { $0.value.count > $1.value.count }) {
                let last = runs.map(\.lastSeen).max() ?? now
                let folders = Set(runs.compactMap { $0.cwd.map { ($0 as NSString).lastPathComponent } }).sorted()
                background.addArrangedSubview(row(title, detail: (["last " + last.formatted(time)] + folders.prefix(3)).joined(separator: " · "),
                                                  value: "\(runs.count) run\(runs.count == 1 ? "" : "s")"))
            }
        }

        let hidden = result.background.filter { provider == nil || $0.origin.provider == provider }
        background.addArrangedSubview(DividerView())
        background.addArrangedSubview(heading("Hidden work · \(model.days)d", trailing: "Already in the totals above"))
        if hidden.isEmpty {
            background.addArrangedSubview(caption("No background sessions in this period."))
        }
        for usage in hidden {
            let tokens = usage.tokens.total > 0 ? " · " + compact(usage.tokens.total) + " tokens" : ""
            background.addArrangedSubview(row(usage.origin.title,
                                              detail: usage.origin.detail + " · last " + usage.lastActivity.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                                              value: "\(usage.runs) run\(usage.runs == 1 ? "" : "s")" + tokens))
        }
    }

    private func describe(_ group: AgentProcessGroup, now: Date) -> String {
        let running = group.startedAt.map { "running " + QuotaPopoverController.countdown(now.timeIntervalSince($0)) }
        let folder = group.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let parts: [String?]
        switch group.kind {
        case .remote: parts = ["Cloud tasks can run commands on this Mac", running]
        case .ephemeral: parts = ["Keeps no transcript", "started by " + group.owner, running, folder]
        case .scripted: parts = ["Started by " + group.owner, running, folder]
        case .session: parts = [group.owner, group.idle > 0 ? "\(group.idle) idle" : nil]
        case .mcp: parts = ["MCP server for " + group.owner, group.count > 1 ? "one copy per session" : nil]
        case .helper, .app: parts = [group.owner]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func memory(_ megabytes: Int) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", Double(megabytes) / 1024) : "\(megabytes) MB"
    }

    private func heading(_ text: String, trailing: String?) -> NSView {
        let title = Typography.caption(text)
        guard let trailing else { return horizontalStack([title, flexibleSpacer()]) }
        let detail = NSTextField(labelWithString: trailing)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = Palette.secondaryText
        return horizontalStack([title, flexibleSpacer(), detail], alignment: .firstBaseline)
    }

    private func caption(_ text: String, color: NSColor = Palette.secondaryText) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = color
        return label
    }

    private func row(_ title: String, detail: String, value: String, tint: NSColor? = nil) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let number = NSTextField(labelWithString: value)
        number.font = Typography.mono(11, weight: .semibold)
        number.textColor = tint ?? Palette.primaryText
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        let note = NSTextField(labelWithString: detail)
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = Palette.secondaryText
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.toolTip = detail
        return verticalStack([horizontalStack([name, flexibleSpacer(), number], alignment: .firstBaseline),
                              horizontalStack([note, flexibleSpacer()])], spacing: 1)
    }

    private func renderHistory() {
        let start = Date.now.addingTimeInterval(-7 * 86_400)
        history.rootView = QuotaHistoryChart(samples: model.quotaHistory.filter {
            $0.at >= start && (provider == nil || $0.series.provider == provider)
        })
    }

    private func compact(_ value: Int64) -> String { value.formatted(.number.notation(.compactName)) }
}

private struct QuotaHistoryChart: View {
    let samples: [QuotaSample]

    var body: some View {
        let series = QuotaSeries.allCases.filter { item in samples.contains { $0.series == item } }
        if samples.isEmpty {
            Text("History fills in while Agent Meter runs.")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Palette.secondaryText))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(samples.indices, id: \.self) { index in
                let sample = samples[index]
                LineMark(x: .value("Time", sample.at), y: .value("Used", sample.used),
                         series: .value("Limit", sample.series.title))
                    .foregroundStyle(by: .value("Limit", sample.series.title))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: sample.series.shortWindow ? [3, 2] : []))
            }
            .chartForegroundStyleScale(domain: series.map(\.title), range: series.map { item in
                switch item.provider {
                case .claude: Color(nsColor: Palette.accent)
                case .codex: Color(nsColor: Palette.primaryText)
                case nil: Color(nsColor: Palette.secondaryText)
                }
            })
            .chartYScale(domain: 0...100)
            .chartXScale(domain: Date.now.addingTimeInterval(-7 * 86_400)...Date.now)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .chartLegend(position: .top, alignment: .leading)
        }
    }
}
