import AppKit
import SwiftUI
import UsageCore

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ActivityHostingView: NSHostingView<NotchActivityView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchHoverState {
    private(set) var active = false
    private var changedAt: TimeInterval?
    private var waitForExit = false

    mutating func sample(inside: Bool, at time: TimeInterval) -> Bool {
        if waitForExit {
            if !inside { waitForExit = false }
            return false
        }
        if inside == active {
            changedAt = nil
            return false
        }
        let since = changedAt ?? time
        changedAt = since
        let delay = inside ? 0.09 : 0.16
        guard time - since >= delay else { return false }
        active = inside
        changedAt = nil
        return true
    }

    mutating func dismiss() {
        active = false
        changedAt = nil
        waitForExit = true
    }
}

@MainActor
struct NotchAnnouncements {
    private struct Entry {
        let kind: NotchCard.Kind
        let turn: Date?
        let action: String?
        let requestID: String?
        var progressed: Bool
    }

    private var entries: [String: Entry] = [:]
    private var primed = false

    mutating func cards(for sessions: [NotchActivity], now: Date) -> [NotchCard] {
        var cards: [NotchCard] = []
        for session in sessions {
            guard let kind = NotchCard.Kind(session.phase) else {
                if session.phase == .running || session.phase == .ready { entries[session.id]?.progressed = true }
                continue
            }
            if kind == .permission && !session.needsApproval(at: now) { continue }
            if let previous = entries[session.id] {
                let newTurn = previous.turn.flatMap { old in
                    session.startedAt.map { abs($0.timeIntervalSince(old)) > 5 }
                } ?? false
                let sameRequest = previous.requestID == session.request?.id
                let sameAction = (kind != .permission && kind != .question)
                    || (previous.action == session.action && sameRequest)
                if previous.kind == kind && !previous.progressed && !newTurn && sameAction { continue }
                if session.request == nil, previous.requestID != nil, previous.kind == kind { continue }
            }
            entries[session.id] = Entry(kind: kind, turn: session.startedAt, action: session.action,
                                        requestID: session.request?.id, progressed: false)
            guard primed || session.request != nil, session.updatedAt <= now.addingTimeInterval(5),
                  now.timeIntervalSince(session.updatedAt) < 20 + session.approvalGrace else { continue }
            cards.append(NotchCard(activity: session, kind: kind, now: now))
        }
        primed = true
        return cards
    }
}

@MainActor
final class NotchController {
    var onPeek: (() -> Void)?

    private let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
    private var activityTimer: Timer?
    private var pointerTimer: Timer?
    private var cardTimer: Timer?
    private var clickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var enabled = false
    private var pinned = false
    private var pinnedVisited = false
    private var showsAll = false
    private var selectedID: String?
    private var hover = NotchHoverState()
    private var hooks: [NotchActivity] = []
    private var logs: [NotchActivity] = []
    private var current: [NotchActivity] = []
    private var cards: [NotchCard] = []
    private var cardDeadline: Date?
    private var cardContents: [String: NotchCardContent] = [:]
    private var announcements = NotchAnnouncements()
    private var hooksModified: Date?
    private var heartbeatAt: Date?
    private var alwaysAllow: Set<String> = []
    private var selections: [String: [Int: Set<Int>]] = [:]
    private var presentation: NotchPresentation?
    private var resizeGeneration = 0

    init() {
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.hostActivated(bundle) }
        }
    }

    private var home: URL? {
        getpwuid(getuid())?.pointee.pw_dir.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
    }

    func shutdown() {
        if let home { NotchReplyChannel.removeHeartbeat(home: home) }
    }

    private func reply(_ reply: NotchReply, to activity: NotchActivity?) {
        guard let request = activity?.request, let home else { return }
        try? NotchReplyChannel.send(reply, for: request.id, home: home)
    }

    private func beat(now: Date) {
        guard let home, now.timeIntervalSince(heartbeatAt ?? .distantPast) >= 2 else { return }
        heartbeatAt = now
        try? NotchReplyChannel.writeHeartbeat(home: home, now: now)
    }

    private func hostActivated(_ bundle: String?) {
        guard let bundle else { return }
        let before = cards.count
        cards.removeAll { card in
            guard [.permission, .question, .waiting].contains(card.kind), let activity = card.activity,
                  NotchFocus.bundleID(for: activity) == bundle else { return false }
            reply(NotchReply(decision: .pass), to: activity)
            return true
        }
        guard cards.count != before else { return }
        startCardTimer()
        render()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        activityTimer?.invalidate()
        pointerTimer?.invalidate()
        activityTimer = nil
        pointerTimer = nil
        hover = NotchHoverState()
        if enabled {
            let events = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshActivity() }
            }
            let pointer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.samplePointer() }
            }
            events.tolerance = 0.05
            pointer.tolerance = 0.01
            RunLoop.main.add(events, forMode: .common)
            RunLoop.main.add(pointer, forMode: .common)
            activityTimer = events
            pointerTimer = pointer
            refreshActivity()
        } else {
            unpin()
            showsAll = false
            for card in cards { reply(NotchReply(decision: .pass), to: card.activity) }
            cards.removeAll()
            stopCardTimer()
            heartbeatAt = nil
            shutdown()
            panel.orderOut(nil)
        }
    }

    func setLogActivities(_ sessions: [NotchActivity]) {
        logs = sessions
        refreshActivity()
    }

    func show(id: String? = nil) {
        loadHooks()
        current = sessions(now: .now)
        if let id, !current.contains(where: { $0.id == id }) {
            post(notice: "This session is no longer in the activity list.")
            return
        }
        selectedID = id
        pinned = true
        pinnedVisited = hover.active
        setClickMonitor(true)
        onPeek?()
        render()
    }

    private func unpin() {
        pinned = false
        pinnedVisited = false
        selectedID = nil
        setClickMonitor(false)
    }

    private func closeList() {
        unpin()
        showsAll = false
        hover.dismiss()
        render()
    }

    private func setClickMonitor(_ on: Bool) {
        if on, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.pinned else { return }
                    self.unpin()
                    self.render()
                }
            }
        } else if !on, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func samplePointer(at location: NSPoint = NSEvent.mouseLocation,
                               time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard panel.isVisible, let layout = presentation?.content.layout else { return }
        if hover.sample(inside: layout.interactionFrame.contains(location), at: time) {
            if hover.active {
                if pinned { pinnedVisited = true }
                pauseCardTimer()
                onPeek?()
            } else {
                if pinned && pinnedVisited { unpin() }
                startCardTimer()
            }
            render()
        }
        updateMouseInteraction(at: location)
    }

    private func updateMouseInteraction(at location: NSPoint = NSEvent.mouseLocation) {
        guard let layout = presentation?.content.layout else { return }
        let interactive: Bool
        switch layout.mode {
        case .idle: interactive = layout.physicalNotch == nil
        case .expanded, .card: interactive = true
        }
        let outsideTarget = panel.frame != layout.frame && !layout.frame.contains(location)
        let ignoresMouse = !interactive || outsideTarget
        if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }
    }

    private func refreshActivity() {
        let now = Date.now
        if enabled { beat(now: now) }
        loadHooks()
        current = sessions(now: now)
        if enabled {
            for card in announcements.cards(for: current, now: now) { handle(card) }
            pruneCards(now: now)
        }
        render(now: now)
    }

    private func loadHooks() {
        guard let home else { return }
        let url = home.appendingPathComponent(NotchActivityStore.relativePath)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified == hooksModified, !hooks.isEmpty { return }
        hooksModified = modified
        hooks = NotchActivityStore.read(url)
    }

    private func handle(_ card: NotchCard) {
        guard let activity = card.activity else { return enqueue(card) }
        if let request = activity.request {
            if request.kind == .approval, alwaysAllow.contains(activity.id + "|" + (request.tool ?? "")) {
                reply(NotchReply(decision: .allow), to: activity)
                return
            }
            if NotchFocus.isFrontmost(activity) {
                reply(NotchReply(decision: .pass), to: activity)
                return
            }
        } else if [.permission, .question, .waiting].contains(card.kind), NotchFocus.isFrontmost(activity) {
            return
        }
        enqueue(card)
    }

    private func decide(_ id: String, _ decision: NotchDecision) {
        guard let card = cards.first(where: { $0.id == id }), let activity = card.activity,
              let request = activity.request else { return }
        switch decision {
        case .deny:
            reply(NotchReply(decision: .deny), to: activity)
        case .always:
            alwaysAllow.insert(activity.id + "|" + (request.tool ?? ""))
            reply(NotchReply(decision: .allow), to: activity)
        case .allow:
            if request.kind == .question {
                let chosen = selections[id] ?? [:]
                var answers: [String: String] = [:]
                for (index, question) in request.questions.enumerated() {
                    let labels = (chosen[index] ?? []).sorted().compactMap {
                        question.options.indices.contains($0) ? question.options[$0].label : nil
                    }
                    guard !labels.isEmpty else { return }
                    answers[question.question] = labels.joined(separator: ",")
                }
                reply(NotchReply(decision: .allow, answers: answers), to: activity)
            } else {
                reply(NotchReply(decision: .allow), to: activity)
            }
        }
        selections[id] = nil
        dismissCard(id: id, byUser: true)
    }

    private func toggle(_ id: String, question: Int, option: Int) {
        guard let questions = cards.first(where: { $0.id == id })?.activity?.request?.questions,
              questions.indices.contains(question) else { return }
        var chosen = selections[id]?[question] ?? []
        if questions[question].multiSelect {
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
        } else {
            chosen = [option]
        }
        selections[id, default: [:]][question] = chosen
        render()
    }

    private func sessions(now: Date) -> [NotchActivity] {
        var sessions = Dictionary(logs.filter {
            now.timeIntervalSince($0.updatedAt) < ($0.phase == .recent ? 4 * 3600 : 15 * 60)
        }.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        for hook in hooks {
            let log = sessions[hook.id]
            if let log, log.phase != .recent, log.updatedAt > hook.updatedAt,
               !hook.phase.needsAttention || log.phase.isFinished {
                sessions[hook.id] = log.filling(from: hook)
                continue
            }
            if hook.phase == .ended { sessions.removeValue(forKey: hook.id) }
            else { sessions[hook.id] = log.map { hook.filling(from: $0) } ?? hook }
        }
        return sessions.values.sorted {
            if $0.phase.needsAttention != $1.phase.needsAttention { return $0.phase.needsAttention }
            if $0.phase.isActive != $1.phase.isActive { return $0.phase.isActive }
            if ($0.phase == .recent) != ($1.phase == .recent) { return $0.phase != .recent }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func enqueue(_ card: NotchCard) {
        if let id = card.activity?.id, let index = cards.firstIndex(where: { $0.activity?.id == id }) {
            cards.remove(at: index)
        }
        if let first = cards.first, card.kind >= first.kind {
            let index = cards.indices.dropFirst().first { cards[$0].kind > card.kind } ?? cards.endIndex
            cards.insert(card, at: index)
        } else {
            cards.insert(card, at: 0)
        }
        if cards.count > 8 { cards.removeLast(cards.count - 8) }
        if cards.first?.id == card.id { startCardTimer() }
    }

    private func pruneCards(now: Date) {
        let visible = cards.first?.id
        cards.removeAll { card in
            guard let activity = card.activity else { return false }
            guard let session = current.first(where: { $0.id == activity.id }) else {
                return [.permission, .question, .waiting].contains(card.kind)
            }
            if let request = activity.request { return session.request?.id != request.id }
            switch card.kind {
            case .permission, .question, .waiting:
                return session.phase != activity.phase || now.timeIntervalSince(card.createdAt) > 600
            case .done, .failed:
                return session.phase == .running && session.updatedAt > activity.updatedAt
            case .notice:
                return false
            }
        }
        if cards.first?.id != visible { startCardTimer() }
    }

    private func post(notice: String) {
        enqueue(NotchCard(notice: notice, now: .now))
        render()
    }

    private func dismissCard(id: String, byUser: Bool) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards.remove(at: index)
        if byUser && cards.isEmpty { hover.dismiss() }
        if index == 0 { startCardTimer() }
        render()
    }

    private func startCardTimer() {
        stopCardTimer()
        guard let card = cards.first, let duration = card.kind.autoDismiss, !hover.active else { return }
        let deadline = Date.now.addingTimeInterval(duration)
        cardDeadline = deadline
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissCard(id: card.id, byUser: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardTimer = timer
    }

    private func pauseCardTimer() {
        stopCardTimer()
    }

    private func stopCardTimer() {
        cardTimer?.invalidate()
        cardTimer = nil
        cardDeadline = nil
    }

    private func open(_ activity: NotchActivity) {
        Task { @MainActor in
            switch await SessionFocus.open(activity) {
            case .opened: break
            case .copied: post(notice: "Resume command copied")
            case .failed(let message): post(notice: message)
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func render(now: Date = .now) {
        guard enabled || pinned else {
            panel.orderOut(nil)
            return
        }
        guard let screen = targetScreen() else { return }
        let sessions = current
        let card = enabled ? cards.first : nil
        let mode: NotchLayout.Mode = card != nil ? .card : pinned || hover.active ? .expanded : .idle
        if mode != .expanded || sessions.count <= NotchLayout.visibleRows { showsAll = false }
        let physicalNotch: CGSize?
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = screen.frame.width - left - right
            physicalNotch = CGSize(width: left > 0 && right > 0 && width > 0 ? width : 200,
                                   height: screen.safeAreaInsets.top)
        } else {
            physicalNotch = nil
        }
        let width = min(NotchLayout.expandedWidth, screen.frame.width) - 2 * NotchLayout.expandedSideInset
        var cardContent = card.map { card in
            if let cached = cardContents[card.id] { return cached }
            let made = NotchCardContent(card: card, width: width)
            cardContents = cardContents.filter { id, _ in cards.contains { $0.id == id } }
            cardContents[card.id] = made
            return made
        }
        cardContent?.deadline = cardDeadline
        var layout = NotchLayout(screenFrame: screen.frame, visibleScreenHeight: screen.visibleFrame.height,
                                 physicalNotch: physicalNotch, mode: mode,
                                 rowHeights: sessions.map(NotchRowStyle.height), showsAll: showsAll,
                                 canDismiss: pinned)
        if let cardContent {
            layout.cardHasSubtitle = cardContent.subtitle != nil
            layout.cardHasActions = cardContent.hasActions
            layout.cardBodyHeight = cardContent.bodyHeight
        }
        let content = NotchActivityContent(layout: layout, sessions: sessions, selectedID: selectedID,
                                           card: cardContent, selections: card.flatMap { selections[$0.id] } ?? [:])
        guard !panel.isVisible || presentation?.content != content else { return }
        if panel.isVisible, let presentation {
            updatePresentation(presentation, to: content)
        } else {
            installPresentation(content)
        }
        updateMouseInteraction()
    }

    private func installPresentation(_ content: NotchActivityContent) {
        resizeGeneration += 1
        let presentation = NotchPresentation(content: content)
        let view = NotchActivityView(presentation: presentation,
                                     onToggle: { [weak self] in self?.show() },
                                     onClose: { [weak self] in self?.closeList() },
                                     onShowAll: { [weak self] in
                                         guard let self else { return }
                                         showsAll.toggle()
                                         render()
                                     },
                                     onOpen: { [weak self] session in
                                         guard let self else { return }
                                         closeList()
                                         open(session)
                                     },
                                     onCardOpen: { [weak self] id in
                                         guard let self, let card = cards.first(where: { $0.id == id }) else { return }
                                         reply(NotchReply(decision: .pass), to: card.activity)
                                         dismissCard(id: id, byUser: true)
                                         if let activity = card.activity { open(activity) }
                                     },
                                     onCardDismiss: { [weak self] id in
                                         guard let self else { return }
                                         reply(NotchReply(decision: .pass), to: cards.first { $0.id == id }?.activity)
                                         dismissCard(id: id, byUser: true)
                                     },
                                     onDecide: { [weak self] id, decision in self?.decide(id, decision) },
                                     onToggleOption: { [weak self] id, question, option in
                                         self?.toggle(id, question: question, option: option)
                                     })
        let hosting = ActivityHostingView(rootView: view)
        hosting.sizingOptions = []
        self.presentation = presentation
        panel.contentView = hosting
        panel.setFrame(content.layout.frame, display: true)
        panel.orderFrontRegardless()
    }

    private func updatePresentation(_ presentation: NotchPresentation, to content: NotchActivityContent) {
        let previous = presentation.content.layout
        let next = content.layout
        let frameChanged = previous.frame != next.frame
        let modeChanged = previous.mode != next.mode
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion || previous.screenFrame != next.screenFrame {
            resizeGeneration += 1
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentation.content = content }
            if panel.frame != next.frame { panel.setFrame(next.frame, display: true) }
            return
        }

        let cardChanged = presentation.content.card?.id != content.card?.id
        guard frameChanged || modeChanged || cardChanged else {
            presentation.content = content
            return
        }
        let large: Set<NotchLayout.Mode> = [.expanded, .card]
        let growing = next.frame.height > previous.frame.height + 0.5 || next.frame.width > previous.frame.width + 0.5
        let animation: Animation
        if next.mode == previous.mode || (large.contains(next.mode) && large.contains(previous.mode)) {
            animation = .spring(response: 0.34, dampingFraction: 0.88)
        } else if growing {
            animation = .timingCurve(0.18, 0.86, 0.24, 1, duration: 0.38)
        } else {
            animation = .timingCurve(0.32, 0, 0.18, 1, duration: 0.36)
        }
        guard frameChanged else {
            withAnimation(animation) { presentation.content = content }
            return
        }

        let canvas = panel.frame.union(next.frame)
        if panel.frame != canvas {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                panel.setFrame(canvas, display: false)
                panel.contentView?.layoutSubtreeIfNeeded()
            }
        }
        resizeGeneration += 1
        let generation = resizeGeneration
        let completion: AnimationCompletionCriteria = modeChanged || cardChanged ? .removed : .logicallyComplete
        withAnimation(animation, completionCriteria: completion) {
            presentation.content = content
        } completion: { [weak self] in
            guard let self, resizeGeneration == generation, panel.isVisible else { return }
            if panel.frame != next.frame { panel.setFrame(next.frame, display: true) }
            updateMouseInteraction()
        }
    }
}

@MainActor
enum NotchFocus {
    static func bundleID(for activity: NotchActivity) -> String? {
        if let host = activity.host { return host.bundleID }
        return activity.provider == .codex ? NotchActivity.Host.codexApp.bundleID : nil
    }

    static func isFrontmost(_ activity: NotchActivity) -> Bool {
        guard let bundle = bundleID(for: activity) else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
    }
}
