import AppKit
import Combine
import UsageCore

@MainActor
final class SettingsViewController: PreferencePaneViewController {
    private let model: MeterModel
    private let sourceRows = verticalStack([])
    private let accountRows = verticalStack([])
    private let billingRows = verticalStack([])
    private let menuBarRows = verticalStack([])
    private let notchProvider = NSPopUpButton()
    private let automaticStatus = NSTextField(wrappingLabelWithString: "")
    private let boardStatus = NSTextField(wrappingLabelWithString: "")
    private let boardRows = verticalStack([])
    private var updates = Set<AnyCancellable>()

    override var preferredContentWidth: CGFloat? { 580 }

    init(model: MeterModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addSection(title: "Data sources", subtitle: "Grant read-only access to the log folders you choose.",
                   symbol: "folder", body: sourceRows)

        addSection(title: "Menu bar display", subtitle: "Choose what appears in the macOS menu bar.",
                   symbol: "menubar.rectangle", body: menuBarRows)
        addSection(title: "Service accounts", subtitle: "Usage refreshes every 5 minutes. API keys stay in Agent Meter’s private app folder.",
                   symbol: "person.crop.circle", body: accountRows)
        addSection(title: "API billing", subtitle: "Monthly costs, tokens and credits. Admin and management keys stay in Agent Meter’s private app folder. Reports refresh every 5 minutes.",
                   symbol: "creditcard", body: billingRows)
        automaticStatus.font = .systemFont(ofSize: 12)
        let enable = NSButton(title: "Enable automatic refresh…", target: self, action: #selector(enableAutomatic))
        let login = NSButton(title: "Sign in for Agent Meter…", target: self, action: #selector(loginClaude))
        addSection(title: "Claude account", subtitle: "The background collector reads limits and reset times through the official Claude Code client. A separate sign-in keeps your other sessions from using up its request budget.",
                   symbol: "gauge.with.dots.needle.50percent",
                   body: verticalStack([horizontalStack([automaticStatus, flexibleSpacer()]),
                                        horizontalStack([enable, login, flexibleSpacer()])]))

        let notch = NSButton(checkboxWithTitle: "Show session activity at the notch", target: self,
                             action: #selector(toggleNotch(_:)))
        notch.state = model.notchEnabled ? .on : .off
        let resume = NSButton(checkboxWithTitle: "Copy claude --resume when a chat is not in Claude Desktop", target: self,
                              action: #selector(toggleCopyResume(_:)))
        resume.state = SessionFocus.copiesResume ? .on : .off
        notchProvider.addItems(withTitles: Provider.allCases.map(\.title))
        notchProvider.setAccessibilityLabel("Hook provider")
        let setup = NSButton(title: "Copy install command", target: self, action: #selector(copyHookCommand(_:)))
        let removal = NSButton(title: "Copy remove command", target: self, action: #selector(copyHookCommand(_:)))
        removal.tag = 1
        addSection(title: "Notch notifications", subtitle: "Run the copied command in Terminal. Review new Codex hooks in /hooks.",
                   symbol: "waveform", body: verticalStack([
                       horizontalStack([notch, flexibleSpacer()]),
                       horizontalStack([resume, flexibleSpacer()]),
                       horizontalStack([notchProvider, setup, removal, flexibleSpacer()]),
                   ]))

        boardStatus.font = .systemFont(ofSize: 12)
        let boardSwitch = NSButton(checkboxWithTitle: "Push the numbers to the quota board over Bluetooth",
                                   target: self, action: #selector(toggleBoard(_:)))
        boardSwitch.state = model.board.enabled ? .on : .off
        addSection(title: "Quota board", subtitle: "The e-paper board shows the limits this Mac already collects, so it stores no tokens of its own. Settings below are stored on the board.",
                   symbol: "rectangle.on.rectangle",
                   body: verticalStack([horizontalStack([boardSwitch, flexibleSpacer()]),
                                        horizontalStack([boardStatus, flexibleSpacer()]),
                                        boardRows]))

        let links = NSButton(title: "Open Codex plugin link…", target: self, action: #selector(openLink))
        addSection(title: "Links", symbol: "link", body: horizontalStack([links, flexibleSpacer()]))

        model.$roots.combineLatest(model.$result.map(\.unreadable).removeDuplicates()).sink { [weak self] roots, unreadable in
            self?.updateSources(roots, unreadable: unreadable)
        }.store(in: &updates)
        model.accounts.$states.combineLatest(model.accounts.$loading).sink { [weak self] states, loading in
            self?.updateAccounts(states, loading: loading)
        }.store(in: &updates)
        model.accounts.$states.combineLatest(model.$hiddenMenuItems).sink { [weak self] states, hidden in
            self?.updateMenuBarOptions(states, hidden: hidden)
        }.store(in: &updates)
        model.$result.sink { [weak self] result in
            self?.automaticStatus.stringValue = result.automaticClaude?.message()
                ?? "Enable the background collector for automatic account limits."
        }.store(in: &updates)
        model.board.$config.removeDuplicates().sink { [weak self] config in
            self?.updateBoard(config)
        }.store(in: &updates)
        model.board.$status.combineLatest(model.board.$pushedAt).sink { [weak self] status, pushed in
            self?.updateBoardStatus(status, pushed: pushed)
        }.store(in: &updates)
    }

    private static let cardFields: [(id: String, title: String, field: WritableKeyPath<BoardConfig.Cards, Bool>)] = [
        ("session", "Claude 5-hour session", \.session),
        ("opus", "Opus weekly", \.opus),
        ("fable", "Fable weekly", \.fable),
        ("codex", "Codex session", \.codex),
        ("codexWeek", "Codex week, inline on the Codex row", \.codexWeek),
        ("detail", "Second page: Claude session, week and Sonnet", \.detail),
        ("indoor", "Indoor temperature and humidity in the footer", \.indoor),
        ("battery", "Battery voltage in the footer", \.battery),
    ]

    private func updateBoardStatus(_ status: BoardLink.Status, pushed: Date?) {
        guard status == .connected, let config = model.board.config else {
            boardStatus.stringValue = status.text
            return
        }
        let identity = [config.board, config.fw.map { "firmware \($0)" },
                        config.ip?.isEmpty == false ? config.ip : nil].compactMap { $0 }.joined(separator: " · ")
        let pushing = config.pushesQuota
            ? pushed.map { "numbers pushed at " + $0.formatted(.dateTime.hour().minute()) } ?? "waiting for the next refresh"
            : "fetching through its own proxy, nothing pushed from here"
        boardStatus.stringValue = "Connected · " + identity + "\n" + pushing
    }

    private func updateBoard(_ config: BoardConfig?) {
        boardRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updateBoardStatus(model.board.status, pushed: model.board.pushedAt)
        guard let config else { return }

        let source = NSPopUpButton()
        source.addItems(withTitles: ["Agent Meter, over Bluetooth", "The board itself, through the proxy"])
        source.selectItem(at: config.pushesQuota ? 0 : 1)
        source.target = self
        source.action = #selector(boardSource(_:))
        source.setAccessibilityLabel("Board data source")

        let theme = NSPopUpButton()
        theme.addItems(withTitles: BoardConfig.themes)
        theme.selectItem(at: min(max(config.theme, 0), BoardConfig.themes.count - 1))
        theme.target = self
        theme.action = #selector(boardTheme(_:))
        theme.setAccessibilityLabel("Board theme")

        let interval = NSPopUpButton()
        interval.addItems(withTitles: BoardConfig.intervals.map { "every \($0) min" })
        interval.selectItem(at: BoardConfig.intervals.firstIndex(of: config.every) ?? 2)
        interval.target = self
        interval.action = #selector(boardInterval(_:))
        interval.setAccessibilityLabel("Board redraw interval")

        let zone = NSTextField(string: config.tz)
        zone.target = self
        zone.action = #selector(boardZone(_:))
        zone.setAccessibilityLabel("Board timezone")
        zone.toolTip = "POSIX timezone, for example MSK-3 or CET-1CEST,M3.5.0,M10.5.0/3"
        zone.widthAnchor.constraint(equalToConstant: 150).isActive = true

        boardRows.addArrangedSubview(horizontalStack([label("Numbers from"), source, flexibleSpacer()]))
        boardRows.addArrangedSubview(horizontalStack([label("Redraw"), theme, interval, flexibleSpacer()]))
        boardRows.addArrangedSubview(horizontalStack([label("Timezone"), zone, flexibleSpacer()]))
        boardRows.addArrangedSubview(DividerView())
        for card in Self.cardFields {
            let checkbox = NSButton(checkboxWithTitle: card.title, target: self, action: #selector(boardCard(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(card.id)
            checkbox.state = config.cards[keyPath: card.field] ? .on : .off
            boardRows.addArrangedSubview(horizontalStack([checkbox, flexibleSpacer()]))
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = Palette.secondaryText
        return field
    }

    private func changeBoard(_ edit: (inout BoardConfig) -> Void) {
        guard var config = model.board.config else { return }
        edit(&config)
        model.board.apply(config)
    }

    @objc private func toggleBoard(_ button: NSButton) {
        model.board.enabled = button.state == .on
    }

    @objc private func boardSource(_ sender: NSPopUpButton) {
        changeBoard { $0.source = sender.indexOfSelectedItem == 0 ? 0 : 1 }
    }

    @objc private func boardTheme(_ sender: NSPopUpButton) {
        changeBoard { $0.theme = max(0, sender.indexOfSelectedItem) }
    }

    @objc private func boardInterval(_ sender: NSPopUpButton) {
        changeBoard { $0.every = BoardConfig.intervals[max(0, sender.indexOfSelectedItem)] }
    }

    @objc private func boardZone(_ sender: NSTextField) {
        let zone = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zone.isEmpty, zone.count <= 48 else { return }
        changeBoard { $0.tz = zone }
    }

    @objc private func boardCard(_ sender: NSButton) {
        guard let card = Self.cardFields.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        changeBoard { $0.cards[keyPath: card.field] = sender.state == .on }
    }

    private func updateMenuBarOptions(_ states: [ServiceAccountProfile], hidden: Set<String>) {
        menuBarRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let providers = Provider.allCases.map { ($0.rawValue, $0.title) } + [("grok", "Grok")]
        let accounts = states.map { ($0.id, $0.title == $0.provider.title ? $0.title : "\($0.title) · \($0.provider.title)") }
        for (id, title) in providers + accounts {
            let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleMenuItem(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(id)
            checkbox.state = hidden.contains(id) ? .off : .on
            menuBarRows.addArrangedSubview(horizontalStack([checkbox, flexibleSpacer()]))
        }
    }

    @objc private func toggleMenuItem(_ button: NSButton) {
        guard let id = button.identifier?.rawValue else { return }
        model.setMenuItem(id, visible: button.state == .on)
    }

    private func updateAccounts(_ states: [ServiceAccountProfile], loading: Set<String>) {
        accountRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        billingRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, provider) in ServiceAccount.allCases.enumerated() {
            let rows = provider.isBilling ? billingRows : accountRows
            if !rows.arrangedSubviews.isEmpty { rows.addArrangedSubview(DividerView()) }
            let title = NSTextField(labelWithString: provider.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            let add = NSButton(title: "Add " + provider.keyName + "…", target: self, action: #selector(addAccount(_:)))
            add.tag = index
            let keyPage = NSButton(title: "Get " + provider.keyName, target: self, action: #selector(openKeyPage(_:)))
            keyPage.tag = index
            rows.addArrangedSubview(horizontalStack([title, flexibleSpacer(), keyPage, add]))
            for profile in states where profile.provider == provider {
                let name = NSTextField(labelWithString: profile.title)
                name.font = .systemFont(ofSize: 12, weight: .medium)
                let status = loading.contains(profile.id) ? "Checking connection…" : profile.message ?? "Connected"
                let scope = provider == .xai ? "Team" : provider.isBilling ? (profile.reportKeyID ?? "Organization")
                    : provider == .kimi ? profile.region.title : nil
                let expiry = profile.keyRejected ? nil : profile.keyExpiry(at: .now)
                let detail = NSTextField(wrappingLabelWithString: [scope, status, expiry].compactMap { $0 }.joined(separator: " · "))
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = profile.needsKeyAttention(at: .now) ? Palette.urgencyRed : Palette.secondaryText
                let edit = NSButton(title: "Edit…", target: self, action: #selector(editAccount(_:)))
                let remove = NSButton(title: "Remove", target: self, action: #selector(disconnectAccount(_:)))
                edit.identifier = NSUserInterfaceItemIdentifier(profile.id)
                remove.identifier = edit.identifier
                edit.isEnabled = !loading.contains(profile.id)
                let labels = verticalStack([name, detail], spacing: 3, alignment: .leading)
                let row = horizontalStack([labels, flexibleSpacer()])
                if provider == .openAI, profile.reportKeyID == nil {
                    let balance = NSButton(title: profile.creditBalance == nil ? "Save balance…" : "Update balance…",
                                           target: self, action: #selector(editCreditBalance(_:)))
                    balance.identifier = edit.identifier
                    row.addArrangedSubview(balance)
                }
                if profile.canRotate {
                    let rotate = NSButton(title: "Rotate key…", target: self, action: #selector(rotateKey(_:)))
                    rotate.identifier = edit.identifier
                    rotate.isEnabled = !loading.contains(profile.id)
                    row.addArrangedSubview(rotate)
                }
                row.addArrangedSubview(edit)
                row.addArrangedSubview(remove)
                rows.addArrangedSubview(row)
            }
        }
        if !loading.subtracting(states.map(\.id)).isEmpty {
            let pending = NSTextField(labelWithString: "Validating new API key…")
            pending.textColor = Palette.secondaryText
            pending.font = .systemFont(ofSize: 11)
            accountRows.addArrangedSubview(horizontalStack([pending, flexibleSpacer()]))
        }
    }

    @objc private func rotateKey(_ button: NSButton) {
        guard let window = view.window,
              let profile = model.accounts.states.first(where: { $0.id == button.identifier?.rawValue }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rotate the \(profile.title) admin key?"
        let lifetime = profile.adminKey?.expiresAt == nil ? "without an expiry date" : "with the same lifetime"
        alert.informativeText = "Agent Meter creates a new admin key \(lifetime), saves it, and deletes the current key in your OpenAI organization."
        alert.addButton(withTitle: "Rotate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let notice = NSAlert()
                do {
                    let removed = try await self.model.accounts.rotateKey(profile.id)
                    guard !removed else { return }
                    notice.messageText = "New key saved"
                    notice.informativeText = "Agent Meter could not delete the old key. Delete it on the OpenAI Admin keys page."
                } catch {
                    notice.messageText = "Key not rotated"
                    notice.informativeText = (error as? ServiceUsageError)?.message ?? error.localizedDescription
                }
                if let window = self.view.window { notice.beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    @objc private func editCreditBalance(_ button: NSButton) {
        guard let window = view.window,
              let profile = model.accounts.states.first(where: { $0.id == button.identifier?.rawValue }) else { return }
        let alert = NSAlert()
        alert.messageText = "Save OpenAI API credit balance"
        alert.informativeText = "Enter the balance shown in Billing Overview. Agent Meter displays the saved amount with its date."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if profile.creditBalance != nil { alert.addButton(withTitle: "Clear saved balance") }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        field.placeholderString = "Amount in USD"
        field.setAccessibilityLabel("API credit balance in US dollars")
        field.stringValue = profile.creditBalance.map { NSDecimalNumber(decimal: $0.amountUSD).stringValue } ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn {
                model.accounts.setOpenAICreditBalance(nil, for: profile.id)
            } else if response == .alertFirstButtonReturn {
                guard let amount = OpenAICreditSnapshot.parseAmount(field.stringValue) else {
                    model.alert = "Enter the balance as a dollar amount, for example 42.50."
                    return
                }
                model.accounts.setOpenAICreditBalance(amount, for: profile.id)
            }
        }
    }

    @objc private func addAccount(_ button: NSButton) {
        showAccountEditor(ServiceAccount.allCases[button.tag])
    }

    @objc private func editAccount(_ button: NSButton) {
        guard let profile = model.accounts.states.first(where: { $0.id == button.identifier?.rawValue }) else { return }
        showAccountEditor(profile.provider, replacing: profile)
    }

    private func showAccountEditor(_ provider: ServiceAccount, replacing profile: ServiceAccountProfile? = nil) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = profile.map { "Edit " + $0.title } ?? "Connect " + provider.title
        if provider == .xai {
            alert.informativeText = profile == nil
                ? "Use a management key, not a Grok API key: xAI Console → Settings → Management keys. Agent Meter shows prepaid credits left, this month’s spend and the spending limit. Prepaid credits do not reset; the spend total resets on the 1st (UTC)."
                : "Leave the management key blank to keep it."
        } else if provider.isBilling {
            let keyHint = profile == nil ? "Paste the full Admin API key shown when you create it." : "Leave the Admin API key blank to keep it."
            alert.informativeText = keyHint + " Enter a working key’s ID to filter the report. A blank ID shows the whole organization."
        } else {
            alert.informativeText = profile == nil ? "Enter a Coding Plan API key."
                : provider == .kimi ? "Leave the API key blank to keep it. Changing region requires a new key."
                : "Leave the API key blank to keep it."
        }
        alert.addButton(withTitle: profile == nil ? "Connect" : "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 320
        let regionHeight: CGFloat = provider == .kimi || provider.filtersByKeyID ? 34 : 0
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 62 + regionHeight))
        let name = NSTextField(frame: NSRect(x: 0, y: 34 + regionHeight, width: width, height: 26))
        name.placeholderString = "Account name"
        name.setAccessibilityLabel("Account name")
        name.stringValue = profile?.title ?? model.accounts.suggestedName(for: provider)
        let key = NSSecureTextField(frame: NSRect(x: 0, y: regionHeight, width: width, height: 26))
        key.placeholderString = provider == .xai ? "Management key" : provider.isBilling ? "Admin API key"
            : (profile == nil ? "API key" : "New API key")
        key.setAccessibilityLabel(provider.title + " API key")
        accessory.addSubview(name)
        accessory.addSubview(key)
        let region = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        region.addItems(withTitles: KimiRegion.allCases.map(\.title))
        region.selectItem(at: (profile?.region ?? .china) == .china ? 0 : 1)
        region.setAccessibilityLabel("Kimi region")
        let keyID = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        keyID.placeholderString = provider == .openAI ? "Key ID (key_…) · optional" : "Key ID (apikey_…) · optional"
        keyID.stringValue = profile?.reportKeyID ?? ""
        keyID.setAccessibilityLabel("API key ID filter")
        name.nextKeyView = key
        if provider == .kimi {
            accessory.addSubview(region)
            key.nextKeyView = region
        } else if provider.filtersByKeyID {
            accessory.addSubview(keyID)
            key.nextKeyView = keyID
        }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = profile == nil ? key : name
        alert.beginSheetModal(for: window) { [weak self] response in
            let value = key.stringValue
            key.stringValue = ""
            guard response == .alertFirstButtonReturn, let self else { return }
            let selectedRegion = KimiRegion.allCases[max(0, region.indexOfSelectedItem)]
            let label = name.stringValue
            let reportKeyID = keyID.stringValue
            Task {
                do {
                    try await self.model.accounts.connect(provider, replacing: profile,
                                                          name: label, key: value, region: selectedRegion,
                                                          reportKeyID: reportKeyID)
                } catch {
                    self.model.alert = error.localizedDescription
                }
            }
        }
    }

    @objc private func disconnectAccount(_ button: NSButton) {
        guard let id = button.identifier?.rawValue else { return }
        do {
            try model.accounts.disconnect(id)
            model.setMenuItem(id, visible: true)
        } catch { model.alert = error.localizedDescription }
    }

    @objc private func openKeyPage(_ button: NSButton) {
        let provider = ServiceAccount.allCases[button.tag]
        let international = model.accounts.states.first { $0.provider == provider }?.region == .international
        let url: String
        switch provider {
        case .zai: url = "https://z.ai/manage-apikey"
        case .kimi: url = international ? "https://www.kimi.ai/code/console" : "https://www.kimi.com/code/console"
        case .openAI: url = "https://platform.openai.com/settings/organization/admin-keys"
        case .anthropic: url = "https://platform.claude.com/settings/admin-keys"
        case .xai: url = "https://console.x.ai/team/default/management-keys"
        }
        if let url = URL(string: url) { NSWorkspace.shared.openInBrowser(url) }
    }

    @objc private func toggleNotch(_ button: NSButton) {
        model.notchEnabled = button.state == .on
    }

    @objc private func copyHookCommand(_ button: NSButton) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentMeterHook").path
        guard FileManager.default.isExecutableFile(atPath: helper),
              let provider = Provider.allCases.dropFirst(max(0, notchProvider.indexOfSelectedItem)).first else {
            model.alert = AccessError.helperMissing.localizedDescription
            return
        }
        let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let operation = button.tag == 1 ? "--remove" : "--install"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([quoted, operation, provider.rawValue].joined(separator: " "), forType: .string)
    }

    @objc private func toggleCopyResume(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: SessionFocus.copyResumeKey)
    }

    @objc private func enableAutomatic() { showClaudeSetup(login: false) }
    @objc private func loginClaude() { showClaudeSetup(login: true) }

    private func showClaudeSetup(login: Bool) {
        guard let window = view.window, let command = model.claudeSetupCommand(login: login) else { return }
        let alert = NSAlert()
        alert.messageText = login ? "Sign in for Agent Meter" : "Enable automatic Claude refresh"
        let action = login ? "Claude Code opens the claude.ai sign-in page. This sign-in is only for Agent Meter and does not change your main Claude Code session."
            : "The command enables the background collector for your macOS account."
        alert.informativeText = "Paste the command in Terminal and press Return. " + action
        alert.addButton(withTitle: "Copy & Open Terminal")
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        let text = NSTextField(wrappingLabelWithString: command)
        text.font = Typography.mono(11)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 400
        text.frame.size = NSSize(width: 400, height: ceil(text.fittingSize.height))
        text.setAccessibilityLabel("Terminal command")
        alert.accessoryView = text
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            if response == .alertFirstButtonReturn { self?.openTerminalForCopiedCommand() }
        }
    }

    private func openTerminalForCopiedCommand() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: terminal, configuration: configuration) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.model.alert = "Command copied. Open Terminal and paste it to continue." }
        }
    }

    private func updateSources(_ roots: [LogSource: URL], unreadable: Set<LogSource>) {
        sourceRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, source) in LogSource.allCases.enumerated() {
            if index > 0 { sourceRows.addArrangedSubview(DividerView()) }
            let path = roots[source]?.path ?? (source.provider == .claude ? "~/.claude/" : "~/.codex/") + source.folder
            let title = NSTextField(labelWithString: sourceTitle(source))
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            let detail = NSTextField(labelWithString: path)
            detail.font = Typography.mono(11)
            detail.textColor = Palette.secondaryText
            detail.lineBreakMode = .byTruncatingMiddle
            detail.toolTip = path

            let labels = verticalStack([title, detail], spacing: 3, alignment: .leading)
            let row = horizontalStack([labels, flexibleSpacer()])
            if source == .claudeProjects, roots[source] != nil {
                row.addArrangedSubview(NSButton(title: "Copy status line setup", target: self,
                                               action: #selector(copySetup)))
            }
            if roots[source] == nil || unreadable.contains(source) {
                let connect = NSButton(title: roots[source] == nil ? "Connect…" : "Reconnect…", target: self,
                                       action: #selector(connect(_:)))
                connect.tag = index
                row.addArrangedSubview(connect)
            }
            if roots[source] != nil {
                let disconnect = NSButton(title: "Disconnect", target: self, action: #selector(disconnect(_:)))
                disconnect.tag = index
                row.addArrangedSubview(disconnect)
            }
            sourceRows.addArrangedSubview(row)
        }
    }

    private func sourceTitle(_ source: LogSource) -> String {
        switch source {
        case .claudeProjects: "Claude Code projects"
        case .codexSessions: "Codex sessions"
        case .codexArchive: "Codex archive"
        }
    }

    @objc private func connect(_ button: NSButton) { model.choose(LogSource.allCases[button.tag]) }
    @objc private func disconnect(_ button: NSButton) { model.remove(LogSource.allCases[button.tag]) }
    @objc private func copySetup() { model.copyClaudeSetup() }

    @objc private func openLink() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Open a Codex plugin page"
        alert.informativeText = "The page opens in the Codex app."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 310, height: 23))
        field.placeholderString = "codex://plugins/<id>"
        field.setAccessibilityLabel("Codex plugin link")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.openCodexPlugin(field.stringValue) }
        }
    }
}

private extension ServiceAccount {
    var keyName: String {
        switch self {
        case .xai: "management key"
        case .openAI, .anthropic: "Admin key"
        case .zai, .kimi: "API key"
        }
    }
}
