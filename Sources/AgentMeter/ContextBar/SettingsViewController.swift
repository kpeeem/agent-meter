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
        addSection(title: String(localized: "Data sources"), subtitle: String(localized: "Grant read-only access to the log folders you choose."),
                   symbol: "folder", body: sourceRows)

        addSection(title: String(localized: "Menu bar display"), subtitle: String(localized: "Choose what appears in the macOS menu bar."),
                   symbol: "menubar.rectangle", body: menuBarRows)
        addSection(title: String(localized: "Service accounts"), subtitle: String(localized: "Usage refreshes every 5 minutes. API keys stay in Agent Meter’s private app folder."),
                   symbol: "person.crop.circle", body: accountRows)
        addSection(title: String(localized: "API billing"), subtitle: String(localized: "Monthly costs, tokens and credits. Admin and management keys stay in Agent Meter’s private app folder. Reports refresh every 5 minutes."),
                   symbol: "creditcard", body: billingRows)
        automaticStatus.font = .systemFont(ofSize: 12)
        let enable = NSButton(title: String(localized: "Enable automatic refresh…"), target: self, action: #selector(enableAutomatic))
        addSection(title: String(localized: "Codex and Grok limits"), subtitle: String(localized: "A helper outside the App Sandbox checks live Codex and Grok limits every 5 minutes while Agent Meter is open. Claude limits come only from files that Claude Code and Claude Desktop write themselves: Agent Meter never starts Claude Code and never calls Claude."),
                   symbol: "gauge.with.dots.needle.50percent",
                   body: verticalStack([horizontalStack([automaticStatus, flexibleSpacer()]),
                                        horizontalStack([enable, flexibleSpacer()])]))

        let processes = NSButton(title: String(localized: "List running agents…"), target: self, action: #selector(enableProcesses))
        addSection(title: String(localized: "Background agents"), subtitle: String(localized: "A helper outside the App Sandbox lists Claude Code, Codex and MCP processes every 30 seconds, including runs that keep no transcript. It saves only names, counts and memory, never command lines."),
                   symbol: "eye", body: horizontalStack([processes, flexibleSpacer()]))

        let notch = NSButton(checkboxWithTitle: String(localized: "Show session activity at the notch"), target: self,
                             action: #selector(toggleNotch(_:)))
        notch.state = model.notchEnabled ? .on : .off
        let resume = NSButton(checkboxWithTitle: String(localized: "Copy claude --resume when a chat is not in Claude Desktop"), target: self,
                              action: #selector(toggleCopyResume(_:)))
        resume.state = SessionFocus.copiesResume ? .on : .off
        let background = NSButton(checkboxWithTitle: String(localized: "Pop up cards for subagents, Guardian reviews and other background runs"),
                                  target: self, action: #selector(toggleBackgroundCards(_:)))
        background.state = UserDefaults.standard.bool(forKey: NotchController.backgroundCardsKey) ? .on : .off
        notchProvider.addItems(withTitles: Provider.allCases.map(\.title))
        notchProvider.setAccessibilityLabel(String(localized: "Hook provider"))
        let setup = NSButton(title: String(localized: "Copy install command"), target: self, action: #selector(copyHookCommand(_:)))
        let removal = NSButton(title: String(localized: "Copy remove command"), target: self, action: #selector(copyHookCommand(_:)))
        removal.tag = 1
        addSection(title: String(localized: "Notch notifications"), subtitle: String(localized: "Run the copied command in Terminal. Review new Codex hooks in /hooks."),
                   symbol: "waveform", body: verticalStack([
                       horizontalStack([notch, flexibleSpacer()]),
                       horizontalStack([resume, flexibleSpacer()]),
                       horizontalStack([background, flexibleSpacer()]),
                       horizontalStack([notchProvider, setup, removal, flexibleSpacer()]),
                   ]))

        boardStatus.font = .systemFont(ofSize: 12)
        let boardSwitch = NSButton(checkboxWithTitle: String(localized: "Push the numbers to the quota board over Bluetooth"),
                                   target: self, action: #selector(toggleBoard(_:)))
        boardSwitch.state = model.board.enabled ? .on : .off
        addSection(title: String(localized: "Quota board"), subtitle: String(localized: "The e-paper board shows the limits this Mac already collects, so it stores no tokens of its own. Settings below are stored on the board."),
                   symbol: "rectangle.on.rectangle",
                   body: verticalStack([horizontalStack([boardSwitch, flexibleSpacer()]),
                                        horizontalStack([boardStatus, flexibleSpacer()]),
                                        boardRows]))

        let links = NSButton(title: String(localized: "Open Codex plugin link…"), target: self, action: #selector(openLink))
        addSection(title: String(localized: "Links"), symbol: "link", body: horizontalStack([links, flexibleSpacer()]))

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
            guard let self else { return }
            automaticStatus.stringValue = result.codexLive.map {
                String(localized: "Codex last checked \($0.attemptedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
            } ?? String(localized: "Turn on automatic refresh for live Codex and Grok limits.")
        }.store(in: &updates)
        model.board.$config.removeDuplicates().sink { [weak self] config in
            self?.updateBoard(config)
        }.store(in: &updates)
        model.board.$status.combineLatest(model.board.$pushedAt).sink { [weak self] status, pushed in
            self?.updateBoardStatus(status, pushed: pushed)
        }.store(in: &updates)
    }

    private static let cardFields: [(id: String, title: String, field: WritableKeyPath<BoardConfig.Cards, Bool>)] = [
        ("session", String(localized: "Claude 5-hour session"), \.session),
        ("opus", String(localized: "Opus weekly"), \.opus),
        ("fable", String(localized: "Fable weekly"), \.fable),
        ("codex", String(localized: "Codex session"), \.codex),
        ("codexWeek", String(localized: "Codex week, inline on the Codex row"), \.codexWeek),
        ("detail", String(localized: "Second page: Claude session, week and Sonnet"), \.detail),
        ("indoor", String(localized: "Indoor temperature and humidity in the footer"), \.indoor),
        ("battery", String(localized: "Battery voltage in the footer"), \.battery),
    ]

    private func updateBoardStatus(_ status: BoardLink.Status, pushed: Date?) {
        guard status == .connected, let config = model.board.config else {
            boardStatus.stringValue = status.text
            return
        }
        let identity = [config.board, config.fw.map { String(localized: "firmware \($0)") },
                        config.ip?.isEmpty == false ? config.ip : nil].compactMap { $0 }.joined(separator: " · ")
        let pushing = config.pushesQuota
            ? pushed.map { String(localized: "numbers pushed at \($0.formatted(.dateTime.hour().minute()))") }
                ?? String(localized: "waiting for the next refresh")
            : String(localized: "fetching through its own proxy, nothing pushed from here")
        boardStatus.stringValue = String(localized: "Connected · \(identity)") + "\n" + pushing
    }

    private func updateBoard(_ config: BoardConfig?) {
        boardRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        updateBoardStatus(model.board.status, pushed: model.board.pushedAt)
        guard let config else { return }

        let source = NSPopUpButton()
        source.addItems(withTitles: [String(localized: "Agent Meter, over Bluetooth"),
                                     String(localized: "The board itself, through the proxy")])
        source.selectItem(at: config.pushesQuota ? 0 : 1)
        source.target = self
        source.action = #selector(boardSource(_:))
        source.setAccessibilityLabel(String(localized: "Board data source"))

        let theme = NSPopUpButton()
        theme.addItems(withTitles: BoardConfig.themes)
        theme.selectItem(at: min(max(config.theme, 0), BoardConfig.themes.count - 1))
        theme.target = self
        theme.action = #selector(boardTheme(_:))
        theme.setAccessibilityLabel(String(localized: "Board theme"))

        let interval = NSPopUpButton()
        interval.addItems(withTitles: BoardConfig.intervals.map { String(localized: "every \($0) min") })
        interval.selectItem(at: BoardConfig.intervals.firstIndex(of: config.every) ?? 2)
        interval.target = self
        interval.action = #selector(boardInterval(_:))
        interval.setAccessibilityLabel(String(localized: "Board redraw interval"))

        boardRows.addArrangedSubview(horizontalStack([label(String(localized: "Numbers from")), source, flexibleSpacer()]))
        boardRows.addArrangedSubview(horizontalStack([label(String(localized: "Redraw")), theme, interval, flexibleSpacer()]))
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
            let add = NSButton(title: provider.addKeyTitle, target: self, action: #selector(addAccount(_:)))
            add.tag = index
            let keyPage = NSButton(title: provider.getKeyTitle, target: self, action: #selector(openKeyPage(_:)))
            keyPage.tag = index
            rows.addArrangedSubview(horizontalStack([title, flexibleSpacer(), keyPage, add]))
            for profile in states where profile.provider == provider {
                let name = NSTextField(labelWithString: profile.title)
                name.font = .systemFont(ofSize: 12, weight: .medium)
                let status = loading.contains(profile.id) ? String(localized: "Checking connection…")
                    : profile.message ?? String(localized: "Connected")
                let scope = provider == .xai ? String(localized: "Team")
                    : provider.isBilling ? (profile.reportKeyID ?? String(localized: "Organization"))
                    : provider == .kimi ? profile.region.title : nil
                let expiry = profile.keyRejected ? nil : profile.keyExpiry(at: .now)
                let detail = NSTextField(wrappingLabelWithString: [scope, status, expiry].compactMap { $0 }.joined(separator: " · "))
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = profile.needsKeyAttention(at: .now) ? Palette.urgencyRed : Palette.secondaryText
                let edit = NSButton(title: String(localized: "Edit…"), target: self, action: #selector(editAccount(_:)))
                let remove = NSButton(title: String(localized: "Remove"), target: self, action: #selector(disconnectAccount(_:)))
                edit.identifier = NSUserInterfaceItemIdentifier(profile.id)
                remove.identifier = edit.identifier
                edit.isEnabled = !loading.contains(profile.id)
                let labels = verticalStack([name, detail], spacing: 3, alignment: .leading)
                let row = horizontalStack([labels, flexibleSpacer()])
                if provider == .openAI, profile.reportKeyID == nil {
                    let balance = NSButton(title: profile.creditBalance == nil ? String(localized: "Save balance…")
                                               : String(localized: "Update balance…"),
                                           target: self, action: #selector(editCreditBalance(_:)))
                    balance.identifier = edit.identifier
                    row.addArrangedSubview(balance)
                }
                if profile.canRotate {
                    let rotate = NSButton(title: String(localized: "Rotate key…"), target: self, action: #selector(rotateKey(_:)))
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
            let pending = NSTextField(labelWithString: String(localized: "Validating new API key…"))
            pending.textColor = Palette.secondaryText
            pending.font = .systemFont(ofSize: 11)
            accountRows.addArrangedSubview(horizontalStack([pending, flexibleSpacer()]))
        }
    }

    @objc private func rotateKey(_ button: NSButton) {
        guard let window = view.window,
              let profile = model.accounts.states.first(where: { $0.id == button.identifier?.rawValue }) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rotate the \(profile.title) admin key?")
        alert.informativeText = profile.adminKey?.expiresAt == nil
            ? String(localized: "Agent Meter creates a new admin key without an expiry date, saves it, and deletes the current key in your OpenAI organization.")
            : String(localized: "Agent Meter creates a new admin key with the same lifetime, saves it, and deletes the current key in your OpenAI organization.")
        alert.addButton(withTitle: String(localized: "Rotate"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let notice = NSAlert()
                do {
                    let removed = try await self.model.accounts.rotateKey(profile.id)
                    guard !removed else { return }
                    notice.messageText = String(localized: "New key saved")
                    notice.informativeText = String(localized: "Agent Meter could not delete the old key. Delete it on the OpenAI Admin keys page.")
                } catch {
                    notice.messageText = String(localized: "Key not rotated")
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
        alert.messageText = String(localized: "Save OpenAI API credit balance")
        alert.informativeText = String(localized: "Enter the balance shown in Billing Overview. Agent Meter displays the saved amount with its date.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if profile.creditBalance != nil { alert.addButton(withTitle: String(localized: "Clear saved balance")) }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        field.placeholderString = String(localized: "Amount in USD")
        field.setAccessibilityLabel(String(localized: "API credit balance in US dollars"))
        field.stringValue = profile.creditBalance.map { NSDecimalNumber(decimal: $0.amountUSD).stringValue } ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn {
                model.accounts.setOpenAICreditBalance(nil, for: profile.id)
            } else if response == .alertFirstButtonReturn {
                guard let amount = OpenAICreditSnapshot.parseAmount(field.stringValue) else {
                    model.alert = String(localized: "Enter the balance as a dollar amount, for example 42.50.")
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
        alert.messageText = profile.map { String(localized: "Edit \($0.title)") } ?? String(localized: "Connect \(provider.title)")
        if provider == .xai {
            alert.informativeText = profile == nil
                ? String(localized: "Use a management key, not a Grok API key: xAI Console → Settings → Management keys. Agent Meter shows prepaid credits left, this month’s spend and the spending limit. Prepaid credits do not reset; the spend total resets on the 1st (UTC).")
                : String(localized: "Leave the management key blank to keep it.")
        } else if provider.isBilling {
            let keyHint = profile == nil ? String(localized: "Paste the full Admin API key shown when you create it.")
                : String(localized: "Leave the Admin API key blank to keep it.")
            alert.informativeText = keyHint + " "
                + String(localized: "Enter a working key’s ID to filter the report. A blank ID shows the whole organization.")
        } else {
            alert.informativeText = profile == nil ? String(localized: "Enter a Coding Plan API key.")
                : provider == .kimi ? String(localized: "Leave the API key blank to keep it. Changing region requires a new key.")
                : String(localized: "Leave the API key blank to keep it.")
        }
        alert.addButton(withTitle: profile == nil ? String(localized: "Connect") : String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let width: CGFloat = 320
        let regionHeight: CGFloat = provider == .kimi || provider.filtersByKeyID ? 34 : 0
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 62 + regionHeight))
        let name = NSTextField(frame: NSRect(x: 0, y: 34 + regionHeight, width: width, height: 26))
        name.placeholderString = String(localized: "Account name")
        name.setAccessibilityLabel(String(localized: "Account name"))
        name.stringValue = profile?.title ?? model.accounts.suggestedName(for: provider)
        let key = NSSecureTextField(frame: NSRect(x: 0, y: regionHeight, width: width, height: 26))
        key.placeholderString = provider == .xai ? String(localized: "Management key")
            : provider.isBilling ? String(localized: "Admin API key")
            : (profile == nil ? String(localized: "API key") : String(localized: "New API key"))
        key.setAccessibilityLabel(String(localized: "\(provider.title) API key"))
        accessory.addSubview(name)
        accessory.addSubview(key)
        let region = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        region.addItems(withTitles: KimiRegion.allCases.map(\.title))
        region.selectItem(at: (profile?.region ?? .china) == .china ? 0 : 1)
        region.setAccessibilityLabel(String(localized: "Kimi region"))
        let keyID = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        keyID.placeholderString = provider == .openAI ? String(localized: "Key ID (key_…) · optional")
            : String(localized: "Key ID (apikey_…) · optional")
        keyID.stringValue = profile?.reportKeyID ?? ""
        keyID.setAccessibilityLabel(String(localized: "API key ID filter"))
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

    @objc private func toggleBackgroundCards(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: NotchController.backgroundCardsKey)
    }

    @objc private func enableAutomatic() {
        guard let command = model.refreshSetupCommand() else { return }
        showCommand(command, title: String(localized: "Refresh Codex and Grok limits"),
                    action: String(localized: "The command adds a background helper for your macOS account. Run it again with --uninstall to remove it."))
    }
    @objc private func enableProcesses() {
        guard let command = model.processSetupCommand() else { return }
        showCommand(command, title: String(localized: "List running agents"),
                    action: String(localized: "The command adds a background helper for your macOS account. Run it again with --uninstall-processes to remove it."))
    }

    private func showCommand(_ command: String, title: String, action: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "Paste the command in Terminal and press Return. \(action)")
        alert.addButton(withTitle: String(localized: "Copy & Open Terminal"))
        alert.addButton(withTitle: String(localized: "Copy Command"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let text = NSTextField(wrappingLabelWithString: command)
        text.font = Typography.mono(11)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 400
        text.frame.size = NSSize(width: 400, height: ceil(text.fittingSize.height))
        text.setAccessibilityLabel(String(localized: "Terminal command"))
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
            Task { @MainActor in self?.model.alert = String(localized: "Command copied. Open Terminal and paste it to continue.") }
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
                row.addArrangedSubview(NSButton(title: String(localized: "Copy status line setup"), target: self,
                                               action: #selector(copySetup)))
            }
            if roots[source] == nil || unreadable.contains(source) {
                let connect = NSButton(title: roots[source] == nil ? String(localized: "Connect…") : String(localized: "Reconnect…"),
                                       target: self,
                                       action: #selector(connect(_:)))
                connect.tag = index
                row.addArrangedSubview(connect)
            }
            if roots[source] != nil {
                let disconnect = NSButton(title: String(localized: "Disconnect"), target: self, action: #selector(disconnect(_:)))
                disconnect.tag = index
                row.addArrangedSubview(disconnect)
            }
            sourceRows.addArrangedSubview(row)
        }
    }

    private func sourceTitle(_ source: LogSource) -> String {
        switch source {
        case .claudeProjects: String(localized: "Claude Code projects")
        case .codexSessions: String(localized: "Codex sessions")
        case .codexArchive: String(localized: "Codex archive")
        }
    }

    @objc private func connect(_ button: NSButton) { model.choose(LogSource.allCases[button.tag]) }
    @objc private func disconnect(_ button: NSButton) { model.remove(LogSource.allCases[button.tag]) }
    @objc private func copySetup() { model.copyClaudeSetup() }

    @objc private func openLink() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Open a Codex plugin page")
        alert.informativeText = String(localized: "The page opens in the Codex app.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 310, height: 23))
        field.placeholderString = "codex://plugins/<id>"
        field.setAccessibilityLabel(String(localized: "Codex plugin link"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.openCodexPlugin(field.stringValue) }
        }
    }
}

private extension ServiceAccount {
    var addKeyTitle: String {
        switch self {
        case .xai: String(localized: "Add management key…")
        case .openAI, .anthropic: String(localized: "Add Admin key…")
        case .zai, .kimi: String(localized: "Add API key…")
        }
    }

    var getKeyTitle: String {
        switch self {
        case .xai: String(localized: "Get management key")
        case .openAI, .anthropic: String(localized: "Get Admin key")
        case .zai, .kimi: String(localized: "Get API key")
        }
    }
}
