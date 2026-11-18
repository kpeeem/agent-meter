import AppKit
import Combine
import UsageCore

@MainActor
final class QuotaPopoverController: NSViewController {
    static let contentWidth: CGFloat = 360

    var onShowStats: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowActivity: (() -> Void)?
    var onSized: ((NSSize) -> Void)?

    private let model: MeterModel
    private let contentStack = NSStackView()
    private let footerStack = verticalStack([], spacing: 0)
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private var maxScrollHeight: CGFloat = 350
    private var footerHeight: CGFloat = 0
    private var chosenHeight = UserDefaults.standard.object(forKey: "popover.height") as? Double
    private var availableScreenHeight: CGFloat?
    private var updates = Set<AnyCancellable>()
    private weak var refreshButton: NSButton?

    init(model: MeterModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(material)

        contentStack.orientation = .vertical
        contentStack.spacing = Spacing.s
        contentStack.alignment = .notAnAttribute
        contentStack.edgeInsets = NSEdgeInsets(top: Spacing.xxs, left: 0, bottom: Spacing.xxs, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        root.addSubview(scrollView)
        root.addSubview(footerStack)
        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 350)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: root.topAnchor),
            material.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollHeight,
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            footerStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.$result.sink { [weak self] result in
            self?.rebuild(result)
        }.store(in: &updates)
        model.$scanning.sink { [weak self] scanning in
            self?.refreshButton?.isEnabled = !scanning
        }.store(in: &updates)
        model.accounts.$states.sink { [weak self] _ in
            guard let self else { return }
            rebuild(model.result)
        }.store(in: &updates)
    }

    func prepareToShow(availableScreenHeight: CGFloat? = nil) {
        self.availableScreenHeight = availableScreenHeight
        loadViewIfNeeded()
        rebuild(model.result)
    }

    private func rebuild(_ result: ScanResult) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let now = Date.now
        for provider in Provider.allCases {
            addCard(buildUsageLimits(for: provider, result: result, now: now))
        }
        if let grok = result.grok { addCard(buildGrok(grok, now: now)) }
        for provider in ServiceAccount.allCases {
            let profiles = model.accounts.states.filter { $0.provider == provider }
            if profiles.isEmpty {
                if !provider.isBilling { addCard(buildService(provider, now: now)) }
            } else {
                for profile in profiles { addCard(buildService(provider, profile: profile, now: now)) }
            }
        }
        footerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let running = buildBackground(result, now: now) {
            footerStack.addArrangedSubview(DividerView())
            footerStack.addArrangedSubview(running)
        }
        if let attention = buildAttention(result, now: now) {
            footerStack.addArrangedSubview(DividerView())
            footerStack.addArrangedSubview(attention)
        }
        footerStack.addArrangedSubview(DividerView())
        footerStack.addArrangedSubview(buildFooter())
        let grip = ResizeGrip()
        grip.onDrag = { [weak self] height in self?.resize(to: height) }
        grip.onReset = { [weak self] in
            guard let self else { return }
            chosenHeight = nil
            UserDefaults.standard.removeObject(forKey: "popover.height")
            rebuild(model.result)
        }
        grip.startHeight = { [weak self] in self?.scrollHeight.constant ?? 0 }
        grip.onFinish = { [weak self] in
            guard let self else { return }
            chosenHeight = Double(scrollHeight.constant)
            UserDefaults.standard.set(chosenHeight, forKey: "popover.height")
        }
        footerStack.addArrangedSubview(grip)

        view.layoutSubtreeIfNeeded()
        let arranged = contentStack.arrangedSubviews
        let inset = contentStack.edgeInsets.top + contentStack.edgeInsets.bottom
        let height = arranged.reduce(inset) { $0 + $1.fittingSize.height }
            + contentStack.spacing * CGFloat(max(0, arranged.count - 1))
        footerHeight = ceil(footerStack.fittingSize.height)
        let screenHeight = availableScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 800
        let popoverClearance: CGFloat = 28
        maxScrollHeight = max(0, screenHeight - popoverClearance - footerHeight)
        if let chosenHeight {
            resize(to: CGFloat(chosenHeight))
        } else {
            resize(to: ceil(height))
        }
    }

    private func resize(to height: CGFloat) {
        scrollHeight.constant = min(max(height, min(140, maxScrollHeight)), maxScrollHeight).rounded()
        let size = NSSize(width: Self.contentWidth, height: scrollHeight.constant + footerHeight)
        preferredContentSize = size
        onSized?(size)
    }

    private func addCard(_ card: NSView, inset: CGFloat = Spacing.xs) {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)
        contentStack.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: inset),
            card.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -inset),
        ])
    }

    private func buildUsageLimits(for provider: Provider, result: ScanResult, now: Date) -> NSView {
        let desktop = provider == .claude && result.claudeQuotasFromDesktop
        let title = Typography.caption(provider.title)
        let header = horizontalStack([title, flexibleSpacer()], alignment: .firstBaseline)
        if provider == .codex, result.codexQuotasLive {
            let plan = result.codexLive?.plan.map { " · " + $0 } ?? ""
            let source = NSTextField(labelWithString: "Live" + plan)
            source.font = .systemFont(ofSize: 10)
            source.textColor = Palette.secondaryText
            source.toolTip = "Live limits from ChatGPT, checked " +
                (result.codexLive?.attemptedAt.formatted(.dateTime.hour().minute()) ?? "")
            header.addArrangedSubview(source)
        }
        if provider == .claude, result.claudeQuotasLive {
            let seen = result.claudeQuotas.map(\.observedAt).max()
            let source = NSTextField(labelWithString: "Live")
            source.font = .systemFont(ofSize: 10)
            source.textColor = Palette.secondaryText
            source.toolTip = "Limits read from Claude Code's own response headers, seen " +
                (seen?.formatted(.dateTime.hour().minute()) ?? "")
            header.addArrangedSubview(source)
        } else if desktop {
            let source = NSTextField(labelWithString: "Desktop cache")
            source.font = .systemFont(ofSize: 10)
            source.textColor = Palette.secondaryText
            header.addArrangedSubview(source)
        }

        let quotas = result.quotas(for: provider)
        let windows = quotas.isEmpty ? QuotaWindow.allCases : QuotaWindow.allCases.filter { window in
            quotas.contains { $0.window == window }
        }
        let rows = windows.map { window in
            makeLimitRow(label: window == .fiveHours ? "5-hour rolling" : "7-day rolling",
                         quota: quotas.first { $0.window == window }, now: now) {
                self.quotaDetail($0, now: now, desktop: desktop)
            }
        }
        let tokens = result.sessions.reduce(into: Tokens()) { total, session in
            if session.provider == provider { total = total + session.tokens }
        }
        let total = makeSimpleStatRow(label: "Tokens · \(model.days)d",
                                      value: tokens.total.formatted(.number.notation(.compactName)))
        var contents: [NSView] = [header]
        if provider == .codex, let codex = result.codexLive, [.expired, .throttled].contains(codex.status) {
            contents.append(note(codex.status.message))
        }
        for (index, row) in rows.enumerated() {
            if index > 0 { contents.append(DividerView()) }
            contents.append(row)
        }
        if provider == .claude, let quota = result.claudeFableQuota {
            let stale = quota.isStale(at: now)
                || !result.claudeFableQuotaLive && now.timeIntervalSince(quota.observedAt) >= 3600
            let cachedFable = makeLimitRow(label: "Fable · 7-day", quota: quota, now: now, stale: stale) {
                if stale { return "Stale" }
                return Self.resetCaption($0.resetsAt, now: now)
                    ?? "Cached " + $0.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            }
            let source = result.claudeFableQuotaLive ? "Claude Code's own response headers."
                : result.claudeFableQuotaFromCode ? "Claude Code /usage cache." : "Claude Statistics cache."
            cachedFable.toolTip = [source, Self.resetTooltip(quota.resetsAt, observed: quota.observedAt)]
                .compactMap { $0 }.joined(separator: " ")
            contents += [DividerView(), cachedFable]
        }
        if provider == .claude {
            for model in result.claudeModelQuotas where !model.quota.isStale(at: now) {
                let stale = now.timeIntervalSince(model.quota.observedAt) >= 3600
                let row = makeLimitRow(label: model.name + " · 7-day", quota: model.quota, now: now, stale: stale) {
                    stale ? "Seen " + $0.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                        : Self.resetCaption($0.resetsAt, now: now) ?? "Reset unavailable"
                }
                contents += [DividerView(), row]
            }
        }
        if provider == .codex, let resets = result.codexLive?.resets, resets > 0 {
            let usable = result.codexLive?.usableResets ?? 0
            let row = makeSimpleStatRow(label: "Limit resets", value: resets.formatted())
            row.toolTip = usable > 0 ? "\(usable) can be used now in Codex."
                : "Codex lets you use a reset once a limit runs out."
            contents.append(DividerView())
            contents.append(row)
            contents.append(note(usable > 0 ? "\(usable) ready to use now" : "Usable once a limit runs out",
                             color: usable > 0 ? Palette.accent : nil))
        }
        contents += [DividerView(), total]
        if provider == .claude {
            let value = result.fableEstimateUSD.map { $0.formatted(.currency(code: "USD")) } ?? "—"
            let cost = makeSimpleStatRow(label: "Fable API estimate · \(model.days)d", value: value)
            cost.toolTip = "Estimated value of Fable usage in local Claude Code logs at Anthropic API list prices."
            contents.append(cost)
        }
        return MenubarCardView(content: verticalStack(contents))
    }

    private func buildGrok(_ grok: GrokUsage, now: Date) -> NSView {
        let header = horizontalStack([Typography.caption("Grok"), flexibleSpacer()], alignment: .firstBaseline)
        if let plan = grok.plan {
            let label = NSTextField(labelWithString: plan)
            label.font = .systemFont(ofSize: 10)
            label.textColor = Palette.secondaryText
            header.addArrangedSubview(label)
        }
        var contents: [NSView] = [header]
        if let quota = grok.quota {
            let stale = quota.isStale(at: now) || now.timeIntervalSince(quota.observedAt) >= 3600
            contents.append(makeLimitRow(label: "Weekly included", quota: quota, now: now, stale: stale) {
                stale ? "Seen " + $0.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                    : Self.resetCaption($0.resetsAt, now: now) ?? "Reset unavailable"
            })
        }
        if grok.status != .ready { contents.append(note(grok.status.message)) }
        return MenubarCardView(content: verticalStack(contents))
    }

    private func buildService(_ provider: ServiceAccount, profile: ServiceAccountProfile? = nil, now: Date) -> NSView {
        let title = profile?.title ?? provider.title
        let header = horizontalStack([Typography.caption(title), flexibleSpacer()])
        if title != provider.title {
            let service = NSTextField(labelWithString: provider.title)
            service.font = .systemFont(ofSize: 10)
            service.textColor = Palette.secondaryText
            header.addArrangedSubview(service)
        }
        var rows: [NSView] = [header]
        if provider == .openAI, profile != nil, profile?.reportKeyID == nil {
            let credit = profile?.creditBalance
            rows.append(makeSimpleStatRow(label: "Saved API credit balance",
                                          value: credit?.amountUSD.formatted(.currency(code: "USD")) ?? "—"))
            let detail = credit.map { "Saved " + $0.capturedAt.formatted(.dateTime.month().day().hour().minute()) }
                ?? "Save in Settings"
            let note = NSTextField(labelWithString: detail)
            note.textColor = Palette.secondaryText
            note.font = .systemFont(ofSize: 10)
            let openBilling = NSButton(title: "Billing overview", target: self, action: #selector(openOpenAIBilling))
            rows.append(horizontalStack([note, flexibleSpacer(), openBilling]))
            rows.append(DividerView())
        }
        if let usage = profile?.usage, let billing = usage.billing {
            var monthFormat = Date.FormatStyle().month(.wide).year()
            monthFormat.timeZone = TimeZone(secondsFromGMT: 0)!
            let title = billing.monthStart.formatted(monthFormat)
            let scope = NSTextField(labelWithString: title + " · " + (provider == .xai ? "Team" : profile?.reportKeyID ?? "Organization"))
            scope.lineBreakMode = .byTruncatingMiddle
            scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            scope.textColor = Palette.secondaryText
            scope.font = .systemFont(ofSize: 11)
            rows.append(horizontalStack([scope, flexibleSpacer()]))
            rows.append(makeSimpleStatRow(label: "API costs", value: billing.costUSD?.formatted(.currency(code: "USD")) ?? "—"))
            if provider == .openAI, billing.costUSD == nil {
                let pending = NSTextField(labelWithString: "Costs report has no entries yet")
                pending.textColor = Palette.secondaryText
                pending.font = .systemFont(ofSize: 10)
                rows.append(horizontalStack([pending, flexibleSpacer()]))
            }
            if let credit = billing.creditUSD {
                rows.append(makeSimpleStatRow(label: "Prepaid credits", value: credit.formatted(.currency(code: "USD"))))
            }
            if let limit = billing.limitUSD, limit > 0 {
                let spent = NSDecimalNumber(decimal: billing.costUSD ?? 0).doubleValue
                let cap = NSDecimalNumber(decimal: limit).doubleValue
                rows.append(makePercentRow(label: "Spending limit " + limit.formatted(.currency(code: "USD")),
                                           used: min(100, max(0, spent / cap * 100)), caption: nil, stale: false))
            }
            if provider != .xai {
                let tokenLabel = provider == .openAI ? "Completions tokens" : "Tokens"
                rows.append(makeSimpleStatRow(label: tokenLabel, value: billing.tokens?.formatted() ?? "—"))
            }
            if let requests = billing.requests {
                rows.append(makeSimpleStatRow(label: "Model requests", value: requests.formatted()))
            }
            let stale = usage.isStale(at: now) || billing.monthStart != BillingUsage.startOfMonth(at: now)
            let freshness: String
            if stale {
                freshness = "Last checked " + usage.observedAt.formatted(.dateTime.month().day().hour().minute())
            } else if let through = billing.dataThrough {
                freshness = "Provider data through " + through.formatted(.dateTime.month().day().hour().minute())
            } else {
                freshness = provider == .anthropic ? "Waiting for provider data"
                    : "Checked " + usage.observedAt.formatted(.dateTime.hour().minute())
            }
            let detail = NSTextField(labelWithString: freshness)
            detail.textColor = Palette.secondaryText
            detail.font = .systemFont(ofSize: 10)
            rows.append(horizontalStack([detail, flexibleSpacer()]))
        } else if let usage = profile?.usage {
            let stale = usage.isStale(at: now)
            for (index, window) in usage.windows.enumerated() {
                if index > 0 { rows.append(DividerView()) }
                let row = makePercentRow(label: window.title, used: window.usedPercent,
                                         caption: stale ? "Stale" : Self.resetCaption(window.resetsAt, now: now)
                                            ?? (window.usedPercent == 0 ? "not started" : nil),
                                         stale: stale)
                row.toolTip = Self.resetTooltip(window.resetsAt, observed: usage.observedAt)
                rows.append(row)
            }
            let date = NSTextField(labelWithString: "Updated " + usage.observedAt.formatted(.dateTime.hour().minute()))
            date.font = .systemFont(ofSize: 10)
            date.textColor = Palette.secondaryText
            rows.append(horizontalStack([date, flexibleSpacer()]))
        } else {
            if profile == nil {
                let connect = NSButton(title: "Connect in Settings…", target: self, action: #selector(showSettings))
                rows.append(horizontalStack([connect, flexibleSpacer()]))
            } else {
                rows.append(NSTextField(labelWithString: "No snapshot"))
            }
        }
        if let message = profile?.message {
            let text = NSTextField(wrappingLabelWithString: message)
            text.font = .systemFont(ofSize: 11)
            text.textColor = Palette.secondaryText
            rows.append(horizontalStack([text, flexibleSpacer()]))
        }
        return MenubarCardView(content: verticalStack(rows))
    }

    @objc private func openOpenAIBilling() {
        if let url = URL(string: "https://platform.openai.com/settings/organization/billing/overview") {
            NSWorkspace.shared.openInBrowser(url)
        }
    }

    private func makeLimitRow(label: String, quota: Quota?, now: Date, stale: Bool? = nil,
                              detail: (Quota) -> String) -> NSView {
        let stale = stale ?? (quota?.isStale(at: now) == true)
        let exhaustion = stale ? nil : quota?.projectedExhaustion(at: now)
        let note = exhaustion.map { "At current rate, runs out in " + Self.countdown($0.timeIntervalSince(now)) }
        let row = makePercentRow(label: label, used: quota?.used, caption: quota.map(detail), stale: stale, note: note)
        row.toolTip = quota.flatMap { Self.resetTooltip($0.resetsAt, observed: $0.observedAt) }
        return row
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let total = max(60, Int(interval))
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func resetCaption(_ reset: Date?, now: Date) -> String? {
        guard let reset else { return nil }
        let interval = reset.timeIntervalSince(now)
        return interval < 60 ? "resets now" : "resets in " + countdown(interval)
    }

    static func resetTooltip(_ reset: Date?, observed: Date) -> String? {
        let seen = "Observed " + observed.formatted(.dateTime.month(.abbreviated).day().hour().minute()) + "."
        guard let reset else { return seen }
        return "Resets " + reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
            + ". " + seen
    }

    private func makePercentRow(label: String, used: Double?, caption: String?, stale: Bool,
                                note: String? = nil) -> NSView {
        let color: NSColor
        if let used, !stale {
            color = used >= 90 ? Palette.urgencyRed : used >= 70 ? Palette.urgencyAmber : Palette.accent
        } else {
            color = Palette.secondaryText
        }
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        let value = NSTextField(labelWithString: used.map { "\(Int($0.rounded()))%" } ?? "No snapshot")
        value.font = used == nil ? .systemFont(ofSize: 11) : Typography.mono(12, weight: .semibold)
        value.textColor = color

        var values: [NSView] = [value]
        if let caption {
            let text = NSTextField(labelWithString: caption)
            text.font = .systemFont(ofSize: 10)
            text.textColor = Palette.secondaryText
            values.append(text)
        }
        let trailing = horizontalStack(values, alignment: .firstBaseline)
        let header = horizontalStack([name, flexibleSpacer(), trailing], spacing: 6, alignment: .firstBaseline)

        let bar = ProgressBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        bar.value = (used ?? 0) / 100
        bar.tint = stale ? color.withAlphaComponent(0.45) : color
        guard let note else { return verticalStack([header, bar], spacing: 5) }
        let warning = NSTextField(labelWithString: note)
        warning.font = .systemFont(ofSize: 10)
        warning.textColor = Palette.urgencyRed
        return verticalStack([header, bar, horizontalStack([warning, flexibleSpacer()])], spacing: 5)
    }

    private func note(_ text: String, color: NSColor? = nil) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = color ?? Palette.secondaryText
        label.alignment = .left
        label.preferredMaxLayoutWidth = Self.contentWidth - 2 * (Spacing.xs + Spacing.s)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return horizontalStack([label, flexibleSpacer()])
    }

    private func quotaDetail(_ quota: Quota, now: Date, desktop: Bool) -> String {
        if quota.isStale(at: now) { return "Stale" }
        if let caption = Self.resetCaption(quota.resetsAt, now: now) { return caption }
        return desktop ? "Seen " + quota.observedAt.formatted(.dateTime.hour().minute()) : "Reset unavailable"
    }

    private func makeSimpleStatRow(label: String, value: String) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        let number = NSTextField(labelWithString: value)
        number.font = Typography.mono(12, weight: .semibold)
        return horizontalStack([name, flexibleSpacer(), number], spacing: 6, alignment: .firstBaseline)
    }

    private func buildBackground(_ result: ScanResult, now: Date) -> NSView? {
        guard let snapshot = result.agentProcesses, snapshot.isFresh(at: now) else { return nil }
        let ghosts = snapshot.ghosts
        let remote = snapshot.groups.filter { $0.kind == .remote }.map(\.title)
        var parts = Dictionary(grouping: ghosts, by: \.title).sorted { $0.key < $1.key }.map { title, runs in
            runs.count > 1 ? "\(runs.count) × \(title)" : title
        } + remote
        if !snapshot.remoteFolders.isEmpty { parts.append("Claude Remote Control") }
        guard !parts.isEmpty else { return nil }
        let label = NSTextField(wrappingLabelWithString: "In background: " + parts.joined(separator: ", "))
        label.font = .systemFont(ofSize: 11)
        label.textColor = ghosts.isEmpty ? Palette.secondaryText : Palette.primaryText
        label.preferredMaxLayoutWidth = Self.contentWidth - 2 * Spacing.m - 90
        let open = NSButton(title: "Details…", target: self, action: #selector(showStats))
        open.controlSize = .small
        let stack = horizontalStack([label, flexibleSpacer(), open], alignment: .centerY)
        stack.edgeInsets = NSEdgeInsets(top: Spacing.xs, left: Spacing.m, bottom: Spacing.xs, right: Spacing.m)
        return stack
    }

    private func buildAttention(_ result: ScanResult, now: Date) -> NSView? {
        var notes: [(text: String, urgent: Bool)] = []
        if let usable = result.codexLive?.usableResets, usable > 0 {
            notes.append(("Codex · \(usable == 1 ? "a limit reset is" : "\(usable) limit resets are") ready to use", false))
        }
        if let grok = result.grok, grok.status == .expired || grok.status == .signedOut {
            notes.append(("Grok Bot sign-in expired. Open Grok Bot to sign in again", false))
        }
        for profile in model.accounts.states where profile.needsKeyAttention(at: now) {
            let expired = (profile.adminKey?.expiresAt).map { $0 <= now } == true
            let soon = (profile.adminKey?.expiresAt).map { $0.timeIntervalSince(now) < 3 * 86_400 } == true
            let detail = profile.keyRejected ? "Key rejected" : profile.keyExpiry(at: now) ?? "Key expires soon"
            notes.append((profile.title + " · " + detail, profile.keyRejected || expired || soon))
        }
        guard !notes.isEmpty else { return nil }
        let rows: [NSView] = notes.map { note in
            let label = NSTextField(wrappingLabelWithString: note.text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = note.urgent ? Palette.urgencyRed : Palette.secondaryText
            label.preferredMaxLayoutWidth = Self.contentWidth - 2 * Spacing.m - 90
            return horizontalStack([label, flexibleSpacer()])
        }
        let open = NSButton(title: "Settings…", target: self, action: #selector(showSettings))
        open.controlSize = .small
        let stack = horizontalStack([verticalStack(rows, spacing: 4, alignment: .leading), flexibleSpacer(), open],
                                    alignment: .centerY)
        stack.edgeInsets = NSEdgeInsets(top: Spacing.xs, left: Spacing.m, bottom: Spacing.xs, right: Spacing.m)
        return stack
    }

    private func buildFooter() -> NSView {
        let container = NSView()
        let stats = FooterIconButton(symbol: "chart.line.uptrend.xyaxis", tooltip: "Stats", target: self,
                                     action: #selector(showStats))
        let settings = FooterIconButton(symbol: "slider.horizontal.3", tooltip: "Settings", target: self,
                                        action: #selector(showSettings))
        let activity = FooterIconButton(symbol: "waveform", tooltip: "Agent activity", target: self,
                                        action: #selector(showActivity))
        let refresh = FooterIconButton(symbol: "arrow.clockwise", tooltip: "Refresh", target: self,
                                       action: #selector(refreshStats))
        refresh.isEnabled = !model.scanning
        refreshButton = refresh

        let quit = FooterIconButton(symbol: "power", tooltip: "Quit Agent Meter", target: self,
                                    action: #selector(quitApp))
        for (button, key) in [(stats, "2"), (settings, ","), (refresh, "r"), (quit, "q")] {
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = .command
        }
        let leftStack = horizontalStack([stats, settings, activity, refresh], spacing: Spacing.xxs)
        container.addSubview(leftStack)
        container.addSubview(quit)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.m),
            leftStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            quit.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Spacing.m),
            quit.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 40),
        ])
        return container
    }

    @objc private func showStats() { onShowStats?() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func showActivity() { onShowActivity?() }
    @objc private func refreshStats() { model.refresh(force: true) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

private final class ResizeGrip: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onFinish: (() -> Void)?
    var onReset: (() -> Void)?
    var startHeight: (() -> CGFloat)?
    private var origin: (mouse: CGFloat, height: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 9).isActive = true
        toolTip = "Drag to change the height. Double-click to fit the content."
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panel")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ dirtyRect: NSRect) {
        let handle = NSRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3)
        Palette.secondaryText.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            origin = nil
            onReset?()
            return
        }
        origin = (NSEvent.mouseLocation.y, startHeight?() ?? 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        onDrag?(origin.height + origin.mouse - NSEvent.mouseLocation.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        origin = nil
        onFinish?()
    }
}
