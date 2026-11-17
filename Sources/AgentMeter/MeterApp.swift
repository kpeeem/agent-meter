import AppKit
import Combine
import UsageCore

@main
struct AgentMeterApp {
    @MainActor
    static func main() {
        Typography.registerBundled()
        let app = NSApplication.shared
        let delegate = MeterDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class MeterDelegate: NSObject, NSApplicationDelegate {
    private let model = MeterModel()
    private let popover = NSPopover()
    private lazy var quotaPopover = QuotaPopoverController(model: model)
    private lazy var detailWindow = DetailWindowController(model: model)
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var updates: AnyCancellable?
    private var notchUpdates = Set<AnyCancellable>()
    private lazy var notch = NotchController()
    private var timer: Timer?
    private let statusStrip = MenuBarUsageStrip()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = quotaPopover
        quotaPopover.onSized = { [weak self] size in
            guard let popover = self?.popover, popover.isShown else { return }
            let animates = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = animates
        }
        quotaPopover.onShowStats = { [weak self] in self?.showDetail(.stats) }
        quotaPopover.onShowSettings = { [weak self] in self?.showDetail(.settings) }
        quotaPopover.onShowActivity = { [weak self] in
            self?.popover.performClose(nil)
            self?.notch.show()
        }
        model.$notchEnabled.removeDuplicates().sink { [weak self] enabled in
            self?.notch.setEnabled(enabled)
        }.store(in: &notchUpdates)
        model.$result.map(\.notchActivities).removeDuplicates().sink { [weak self] sessions in
            self?.notch.setLogActivities(sessions)
        }.store(in: &notchUpdates)
        notch.onPeek = { [weak self] in
            guard let self, !model.scanning, Date.now.timeIntervalSince(model.updatedAt ?? .distantPast) > 15 else { return }
            model.refresh()
        }
        status.button?.target = self
        status.button?.action = #selector(togglePopover)
        let rotation = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect().scan(0) { tick, _ in tick &+ 1 }.prepend(0)
        updates = model.$result.combineLatest(model.accounts.$states, model.$hiddenMenuItems, rotation)
            .sink { [weak self] result, states, hidden, tick in
                guard let self, let button = status.button else { return }
                let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let strip = statusStrip.render(result: result, services: states, hidden: hidden, tick: tick, dark: dark)
                button.image = strip.image
                button.toolTip = strip.description
                button.setAccessibilityLabel(strip.description)
            }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
        model.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let id = NotchActivity.sessionID(from: url) { notch.show(id: id) }
        }
    }

    @objc private func togglePopover() {
        guard let button = status.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            quotaPopover.prepareToShow(availableScreenHeight: button.window?.screen?.visibleFrame.height)
            popover.contentSize = quotaPopover.preferredContentSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            model.refresh()
        }
    }

    private func showDetail(_ tab: DetailWindowController.Tab) {
        popover.performClose(nil)
        detailWindow.show(tab)
    }
}
