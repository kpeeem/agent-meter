import AppKit
import SwiftUI
import UsageCore

struct NotchActivityContent: Equatable {
    let layout: NotchLayout
    let sessions: [NotchActivity]
    let selectedID: String?
    let card: NotchCardContent?
    var selections: [Int: Set<Int>] = [:]
}

@MainActor
final class NotchPresentation: ObservableObject {
    @Published var content: NotchActivityContent

    init(content: NotchActivityContent) {
        self.content = content
    }
}

enum NotchRowStyle {
    static func hasDetail(_ session: NotchActivity) -> Bool {
        session.message != nil || session.prompt != nil
    }

    static func height(_ session: NotchActivity) -> CGFloat {
        hasDetail(session) ? NotchLayout.detailRowHeight : NotchLayout.basicRowHeight
    }
}

struct NotchActivityView: View {
    @ObservedObject var presentation: NotchPresentation
    let onToggle: () -> Void
    let onClose: () -> Void
    let onShowAll: () -> Void
    let onOpen: (NotchActivity) -> Void
    let onCardOpen: (String) -> Void
    let onCardDismiss: (String) -> Void
    let onDecide: (String, NotchDecision) -> Void
    let onToggleOption: (String, Int, Int) -> Void

    private var layout: NotchLayout { presentation.content.layout }
    private var sessions: [NotchActivity] { presentation.content.sessions }

    var body: some View {
        let flatHandle = layout.mode == .idle && layout.physicalNotch == nil
        let size = layout.frame.size
        let shape = NotchShape(size: size, bottomRadius: flatHandle ? 0 : layout.cornerRadius)
        GeometryReader { canvas in
            ZStack(alignment: .top) {
                content
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .id(contentKey)
                    .transition(transition)
            }
            .frame(width: canvas.size.width, height: canvas.size.height, alignment: .top)
            .background(.black.opacity(flatHandle ? 0 : 1))
            .mask { shape.fill(.white) }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var contentKey: String {
        switch layout.mode {
        case .idle: "idle"
        case .expanded: "list"
        case .card: "card-" + (presentation.content.card?.id ?? "")
        }
    }

    private var transition: AnyTransition {
        switch layout.mode {
        case .expanded, .card:
            .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            .animation(.easeOut(duration: 0.24).delay(0.1)),
                        removal: .opacity.animation(.easeOut(duration: 0.1)))
        case .idle:
            .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.16)),
                        removal: .opacity.animation(.easeOut(duration: 0.08)))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout.mode {
        case .idle:
            if layout.physicalNotch == nil {
                Button(action: onToggle) {
                    Capsule()
                        .fill(.white.opacity(0.26))
                        .frame(width: 52, height: 4)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show agent activity")
            } else {
                Color.clear
            }
        case .expanded:
            expanded
        case .card:
            if let card = presentation.content.card { cardView(card) }
        }
    }

    private var expanded: some View {
        VStack(spacing: NotchLayout.rowSpacing) {
            if sessions.isEmpty {
                Text("No recent Claude Code or Codex sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: layout.listHeight, alignment: .topLeading)
            } else if layout.rowsHeight > layout.listHeight {
                ScrollView { sessionRows }
                    .frame(height: layout.listHeight)
            } else {
                sessionRows
            }
            if layout.hasFooter { footer }
        }
        .padding(.horizontal, NotchLayout.expandedSideInset)
        .padding(.top, layout.topInset)
        .padding(.bottom, layout.bottomInset)
    }

    private var sessionRows: some View {
        VStack(spacing: NotchLayout.rowSpacing) {
            ForEach(Array(sessions.prefix(layout.rowCount))) { session in
                sessionRow(session)
            }
        }
    }

    private var footer: some View {
        ZStack(alignment: .trailing) {
            if layout.hasMore {
                Button(action: onShowAll) {
                    HStack(spacing: 5) {
                        if !layout.showsAll {
                            Text("+\(sessions.count - NotchLayout.visibleRows)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        Text(layout.showsAll ? "Show less" : "Show all")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: layout.showsAll ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, minHeight: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if layout.canDismiss {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close agent activity")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .trailing)
    }

    private func sessionRow(_ session: NotchActivity) -> some View {
        let copiesCommand = session.provider == .claude && session.host == nil
        let height = NotchRowStyle.height(session)
        let selected = presentation.content.selectedID == session.id
        return Button { onOpen(session) } label: {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(tint: session.phase.tint, pulsing: isWorking(session))
                    .frame(width: 9, height: 9)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.project)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(session.provider == .claude ? "Claude" : "Codex")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(session.provider.badgeColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(session.provider.badgeColor.opacity(0.16), in: Capsule())
                            .fixedSize()
                        if let badge = session.origin?.badge {
                            Text(badge)
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                                .fixedSize()
                                .help(session.origin?.title ?? "")
                        }
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            Text(NotchFormat.age(context.date.timeIntervalSince(session.updatedAt)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Image(systemName: copiesCommand ? "doc.on.doc" : "arrow.up.forward.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(width: 14, height: 14)
                    }
                    .frame(height: 15)
                    rowLine(symbol: session.phase.symbol, tint: session.phase.tint, text: phaseLine(session),
                            opacity: 0.78, elapsedFrom: session.phase == .running ? session.startedAt : nil)
                    if NotchRowStyle.hasDetail(session) {
                        if let message = session.message, session.phase != .waiting || session.prompt == nil {
                            rowLine(symbol: "text.bubble", tint: .white, text: NotchMarkdown.plain(message), opacity: 0.55)
                        } else if let prompt = session.prompt {
                            rowLine(symbol: "chevron.right", tint: .cyan, text: prompt, opacity: 0.55)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(.white.opacity(selected ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .accessibilityHint(copiesCommand ? "Copy resume command" : "Return to session")
        .contextMenu {
            if let link = session.link {
                Button("Copy session link") { copy(link.absoluteString) }
            }
            if session.provider == .claude, SessionFocus.copiesResume {
                Button("Copy resume command") { copy("claude --resume " + session.session.uuidString.lowercased()) }
            }
            if let message = session.message {
                Button("Copy last message") { copy(message) }
            }
        }
    }

    private func rowLine(symbol: String, tint: Color, text: String, opacity: Double,
                         elapsedFrom start: Date? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint.opacity(0.75))
                .frame(width: 10)
            Text(NotchText.clean(text, limit: 200, singleLine: true) ?? text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(opacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let start {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(NotchFormat.clock(context.date.timeIntervalSince(start)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize()
                }
            }
        }
        .frame(height: 13)
    }

    private func cardView(_ card: NotchCardContent) -> some View {
        let tap: (() -> Void)? = card.request == nil && card.openTitle != nil ? { onCardOpen(card.id) } : nil
        return VStack(alignment: .leading, spacing: NotchLayout.cardSpacing) {
            HStack(spacing: 6) {
                Circle()
                    .fill(card.provider?.badgeColor ?? .white.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(card.provider?.title ?? "Agent Meter")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
                if let project = card.project {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(project)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button { onCardDismiss(card.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle())
                .accessibilityLabel("Dismiss")
            }
            .frame(height: NotchLayout.cardHeaderHeight)

            HStack(spacing: 7) {
                Image(systemName: card.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(card.kind.tint)
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let trailing = card.trailing {
                    Text(trailing)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                }
            }
            .frame(height: NotchLayout.cardTitleHeight)
            .modifier(CardTap(action: tap))

            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: NotchLayout.cardSubtitleHeight,
                           maxHeight: NotchLayout.cardSubtitleHeight, alignment: .leading)
                    .modifier(CardTap(action: tap))
            }

            if !card.questions.isEmpty {
                let viewport = layout.cardBodyViewportHeight
                ScrollView(.vertical, showsIndicators: viewport + 1 < card.bodyHeight) {
                    NotchQuestionsBody(questions: card.questions, selections: presentation.content.selections) {
                        onToggleOption(card.id, $0, $1)
                    }
                    .padding(.trailing, 8)
                }
                .frame(height: viewport)
            } else if let text = card.body {
                let viewport = layout.cardBodyViewportHeight
                ScrollView(.vertical, showsIndicators: viewport + 1 < card.bodyHeight) {
                    NotchCardBodyText(text: text, code: card.bodyIsCode)
                        .foregroundStyle(.white.opacity(0.86))
                        .tint(.white)
                        .padding(.trailing, 8)
                        .modifier(CardTap(action: tap))
                }
                .frame(height: viewport)
            }

            if card.hasActions {
            HStack(spacing: 8) {
                if let deadline = card.deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Closes in \(max(1, Int(ceil(deadline.timeIntervalSince(context.date)))))s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                }
                if let request = card.request {
                    pill(request.kind == .question ? "Answer in terminal" : card.openTitle ?? "Open", primary: false) {
                        onCardOpen(card.id)
                    }
                    Spacer(minLength: 0)
                    if request.kind == .question {
                        let complete = card.questions.indices.allSatisfy {
                            presentation.content.selections[$0]?.isEmpty == false
                        }
                        pill("Submit", primary: true) { onDecide(card.id, .allow) }
                            .disabled(!complete)
                            .opacity(complete ? 1 : 0.4)
                    } else {
                        pill("Deny", primary: false) { onDecide(card.id, .deny) }
                        pill("Always allow", primary: false) { onDecide(card.id, .always) }
                        pill("Allow", primary: true) { onDecide(card.id, .allow) }
                    }
                } else {
                    Spacer(minLength: 0)
                    pill("Dismiss", primary: card.openTitle == nil) { onCardDismiss(card.id) }
                    if let title = card.openTitle {
                        pill(title, primary: true) { onCardOpen(card.id) }
                    }
                }
            }
            .frame(height: NotchLayout.cardActionsHeight)
            .padding(.top, 4)
            }
        }
        .padding(.horizontal, NotchLayout.expandedSideInset)
        .padding(.top, layout.topInset)
        .padding(.bottom, NotchLayout.cardBottomInset)
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(primary ? Color.black : .white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: NotchLayout.cardActionsHeight)
                .background(primary ? Color.white.opacity(0.92) : Color.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
    }

    private func isWorking(_ session: NotchActivity) -> Bool {
        session.phase == .running && Date.now.timeIntervalSince(session.updatedAt) < 600
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func phaseLine(_ session: NotchActivity) -> String {
        switch session.phase {
        case .running: return session.action ?? "Thinking…"
        case .permission: return session.action.map { "Approval needed · " + $0 } ?? "Approval needed"
        case .question: return session.request?.questions.first?.question ?? "Question"
        case .waiting: return session.message.map(NotchFormat.firstLine) ?? "Waiting for input"
        case .done:
            if let start = session.startedAt, session.updatedAt > start {
                return "Finished in " + NotchFormat.duration(session.updatedAt.timeIntervalSince(start))
            }
            return "Finished"
        case .failed: return session.message.map { "Error · " + NotchFormat.firstLine($0) } ?? "Stopped with an error"
        case .interrupted: return "Interrupted"
        case .ended: return "Ended"
        case .ready: return "Ready"
        case .recent: return "Recent"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct StatusDot: View {
    let tint: Color
    let pulsing: Bool

    var body: some View {
        ZStack {
            Circle().fill(tint)
            if pulsing {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    let cycle = 1.2
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    Circle()
                        .stroke(tint.opacity(0.6 * (1 - phase)), lineWidth: 1.5)
                        .scaleEffect(1 + phase * 1.3)
                }
            }
        }
        .frame(width: 7, height: 7)
    }
}

private struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct NotchShape: Shape {
    var size: CGSize
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), bottomRadius) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            bottomRadius = newValue.second
        }
    }

    func path(in canvas: CGRect) -> Path {
        let rect = CGRect(x: canvas.midX - size.width / 2, y: canvas.minY, width: size.width, height: size.height)
        let radius = min(bottomRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension Provider {
    var badgeColor: Color {
        self == .claude ? Color(red: 0.91, green: 0.54, blue: 0.40) : Color(red: 0.42, green: 0.78, blue: 0.84)
    }
}

extension NotchCard.Kind {
    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .permission: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .waiting: "ellipsis.bubble.fill"
        case .notice: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .done: NotchActivity.Phase.done.tint
        case .failed: NotchActivity.Phase.failed.tint
        case .permission, .question, .waiting: NotchActivity.Phase.permission.tint
        case .notice: .white.opacity(0.7)
        }
    }
}

extension NotchActivity.Phase {
    var tint: Color {
        switch self {
        case .permission, .question, .waiting: Color(red: 1.0, green: 0.62, blue: 0.24)
        case .running, .done: Color(red: 0.36, green: 0.84, blue: 0.55)
        case .failed: Color(red: 1.0, green: 0.38, blue: 0.36)
        default: .white.opacity(0.4)
        }
    }

    var symbol: String {
        switch self {
        case .running: "bolt.fill"
        case .permission: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .waiting: "ellipsis.bubble.fill"
        case .done: "checkmark"
        case .failed: "xmark"
        case .interrupted: "stop.fill"
        case .ready, .recent, .ended: "circle"
        }
    }
}

enum NotchDecision {
    case allow, deny, always
}

private struct CardTap: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.contentShape(Rectangle()).onTapGesture(perform: action)
        } else {
            content
        }
    }
}
