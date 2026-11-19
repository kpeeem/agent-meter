import AppKit
import Combine

@MainActor
final class DetailTabViewController: NSTabViewController {
    static let defaultContentSize = NSSize(width: 820, height: 680)
    static let minimumContentHeight: CGFloat = 320

    override var preferredContentSize: NSSize {
        get { .zero }
        set {}
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        transitionOptions = []
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        updateToolbarSelection(view.window?.toolbar)
    }

    override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                          willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = super.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
        guard let item, let image = item.image,
              let index = tabViewItems.firstIndex(where: { $0.label == item.label }) else { return item }
        let button = NSButton(title: item.label, image: image, target: self, action: #selector(selectTab(_:)))
        button.tag = index
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageAbove
        button.isBordered = false
        button.frame.size = NSSize(width: 55, height: 48)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        style(button, title: item.label)
        item.view = button
        return item
    }

    override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    @objc private func selectTab(_ sender: NSButton) {
        selectedTabViewItemIndex = sender.tag
        updateToolbarSelection(view.window?.toolbar)
    }

    private func updateToolbarSelection(_ toolbar: NSToolbar?) {
        for item in toolbar?.items ?? [] {
            guard let button = item.view as? NSButton else { continue }
            style(button, title: item.label)
        }
    }

    private func style(_ button: NSButton, title: String) {
        let selected = button.tag == selectedTabViewItemIndex
        button.state = selected ? .on : .off
        let color = selected ? Palette.primaryText : Palette.secondaryText
        button.contentTintColor = color
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: color,
        ])
        button.layer?.backgroundColor = (selected ? NSColor(white: 1, alpha: 0.11) : .clear).cgColor
    }
}

@MainActor
final class DetailWindowController: NSWindowController {
    enum Tab: Int { case stats, settings, about }

    private let tabs = DetailTabViewController()
    private let model: MeterModel
    private var alerts: AnyCancellable?

    init(model: MeterModel) {
        self.model = model
        super.init(window: nil)

        tabs.tabStyle = .toolbar
        addTab(StatsViewController(model: model), title: "Stats", icon: "chart.line.uptrend.xyaxis")
        addTab(SettingsViewController(model: model), title: "Settings", icon: "gearshape")
        addTab(AboutViewController(), title: "About", icon: "info.circle")

        let size = DetailTabViewController.defaultContentSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Agent Meter"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: size.width, height: DetailTabViewController.minimumContentHeight)
        window.contentMaxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        window.contentViewController = tabs
        window.setContentSize(size)
        window.toolbar?.displayMode = .iconOnly
        window.center()
        if let contentView = window.contentView {
            let effect = NSVisualEffectView(frame: contentView.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            contentView.addSubview(effect, positioned: .below, relativeTo: nil)
        }
        self.window = window

        alerts = model.$alert.sink { [weak self] message in
            guard message != nil else { return }
            Task { @MainActor in self?.showPendingAlert() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func show(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        showPendingAlert()
    }

    private func addTab(_ controller: NSViewController, title: String, icon: String) {
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    private func showPendingAlert() {
        guard let window, window.isVisible, window.attachedSheet == nil,
              let message = model.alert else { return }
        model.alert = nil
        let alert = NSAlert()
        alert.messageText = "Agent Meter"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { [weak self] _ in self?.showPendingAlert() }
    }
}

@MainActor
class PreferencePaneViewController: NSViewController {
    let contentStack = NSStackView()
    private let scrollView = NSScrollView()

    var preferredContentWidth: CGFloat? { nil }

    override func loadView() {
        view = FlippedView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: Spacing.l),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: DetailTabViewController.defaultContentSize.width),
        ])

        if let width = preferredContentWidth {
            NSLayoutConstraint.activate([
                contentStack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
                contentStack.widthAnchor.constraint(equalToConstant: width),
            ])
        } else {
            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
                contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            ])
        }
    }

    func addFullWidth(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    func addSection(title: String, subtitle: String? = nil, symbol: String, body: NSView) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        icon.contentTintColor = Palette.secondaryText
        let header = horizontalStack([icon, Typography.caption(title)], spacing: 5)
        let section = verticalStack([header], spacing: 4, alignment: .leading)
        if let subtitle {
            let text = NSTextField(wrappingLabelWithString: subtitle)
            text.font = .systemFont(ofSize: 11)
            text.textColor = Palette.secondaryText
            section.addArrangedSubview(text)
            text.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            section.setCustomSpacing(8, after: text)
        } else {
            section.setCustomSpacing(6, after: header)
        }
        let card = MenubarCardView(content: body, horizontal: Spacing.l, vertical: Spacing.m)
        section.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        addFullWidth(section)
    }
}

@MainActor
private final class AboutViewController: PreferencePaneViewController {
    override var preferredContentWidth: CGFloat? { 580 }

    override func viewDidLoad() {
        super.viewDidLoad()
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "Agent Meter")
        name.font = .systemFont(ofSize: 23, weight: .semibold)
        let version = NSTextField(labelWithString: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        version.font = Typography.mono(12)
        version.textColor = Palette.secondaryText
        let identity = verticalStack([name, version], spacing: Spacing.xxs, alignment: .leading)
        addFullWidth(horizontalStack([icon, identity, flexibleSpacer()], spacing: Spacing.m))
        let credit = NSTextField(wrappingLabelWithString:
            "Native interface adapted from ContextBar. Uses the JetBrains Mono typeface.")
        addSection(title: "Credits", symbol: "info.circle", body: credit)
    }
}
