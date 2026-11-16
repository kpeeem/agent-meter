import AppKit
import SwiftUI
import UsageCore

struct NotchCard: Equatable, Identifiable {
    enum Kind: Int, Comparable {
        case permission, question, failed, waiting, done, notice

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init?(_ phase: NotchActivity.Phase) {
            switch phase {
            case .permission: self = .permission
            case .question: self = .question
            case .failed: self = .failed
            case .waiting: self = .waiting
            case .done: self = .done
            default: return nil
            }
        }

        var autoDismiss: TimeInterval? {
            switch self {
            case .done: 10
            case .failed: 20
            case .notice: 2.5
            case .permission, .question, .waiting: nil
            }
        }
    }

    let id: String
    let kind: Kind
    let activity: NotchActivity?
    let notice: String?
    let createdAt: Date

    init(activity: NotchActivity, kind: Kind, now: Date) {
        id = activity.request?.id ?? activity.id + "#" + String(activity.updatedAt.timeIntervalSinceReferenceDate)
        self.kind = kind
        self.activity = activity
        notice = nil
        createdAt = now
    }

    init(notice: String, now: Date) {
        id = "notice#" + String(now.timeIntervalSinceReferenceDate)
        kind = .notice
        activity = nil
        self.notice = notice
        createdAt = now
    }
}

struct NotchCardContent: Equatable {
    let id: String
    let kind: NotchCard.Kind
    let provider: Provider?
    let project: String?
    let title: String
    let trailing: String?
    let subtitle: String?
    let body: AttributedString?
    let bodyIsCode: Bool
    let bodyHeight: CGFloat
    let openTitle: String?
    let request: NotchRequest?
    var deadline: Date?

    var hasActions: Bool { kind != .notice }
    var questions: [NotchRequest.Question] { request?.kind == .question ? request?.questions ?? [] : [] }

    @MainActor
    init(card: NotchCard, width: CGFloat) {
        id = card.id
        kind = card.kind
        deadline = nil
        let activity = card.activity
        request = activity?.request
        provider = activity?.provider
        project = activity?.project
        var trailing: String?
        var subtitle: String?
        var text: String?
        var code = false
        switch card.kind {
        case .done:
            title = "Finished"
            if let activity, let start = activity.startedAt, activity.updatedAt > start {
                trailing = NotchFormat.duration(activity.updatedAt.timeIntervalSince(start))
            }
            subtitle = activity?.prompt
            text = activity?.message ?? activity?.action
        case .failed:
            title = "Stopped with an error"
            subtitle = activity?.prompt ?? activity?.action
            text = activity?.message
        case .permission:
            if let request = activity?.request {
                title = "Allow " + (request.tool.map(NotchFormat.toolName) ?? "this action") + "?"
                subtitle = activity?.prompt
                text = request.detail ?? activity?.action
            } else {
                title = "Approval needed"
                subtitle = activity?.message.map { NotchFormat.firstLine($0) }
                text = activity?.action
            }
            code = text != nil
        case .question:
            let header = activity?.request?.questions.first?.header
            title = header.map { $0 } ?? "Claude asks"
            subtitle = activity?.prompt
        case .waiting:
            title = activity?.message.map { NotchFormat.firstLine($0) } ?? "Waiting for your input"
            subtitle = activity?.prompt
            text = activity?.message.flatMap { $0.contains("\n") ? $0 : nil }
        case .notice:
            title = card.notice ?? ""
        }
        self.trailing = trailing
        self.subtitle = subtitle.map { "› " + $0 }
        bodyIsCode = code
        if let questions = activity?.request?.questions, activity?.request?.kind == .question {
            body = nil
            bodyHeight = NotchQuestionsBody.height(questions, width: width - 8)
        } else if let text {
            let rendered = code ? AttributedString(text) : NotchMarkdown.render(text)
            body = rendered
            bodyHeight = NotchMarkdown.height(of: rendered, code: code, width: width - 8)
        } else {
            body = nil
            bodyHeight = 0
        }
        openTitle = activity.map(NotchFormat.openTitle)
    }
}

enum NotchMarkdown {
    static func render(_ text: String) -> AttributedString {
        var lines: [String] = []
        var inFence = false
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                lines.append(raw)
                continue
            }
            var line = raw
            if let match = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(match)
                let title = line.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty && !title.contains("**") { line = "**" + title + "**" }
            } else if let match = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                let indent = line[match].prefix { $0 == " " }
                line.replaceSubrange(match, with: indent + "• ")
            }
            lines.append(line)
        }
        let cleaned = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }

    static func plain(_ text: String) -> String {
        String(render(text).characters)
    }

    @MainActor
    static func height(of text: AttributedString, code: Bool, width: CGFloat) -> CGFloat {
        let probe = NSHostingView(rootView: NotchCardBodyText(text: text, code: code)
            .frame(width: max(40, width), alignment: .leading))
        return min(NotchLayout.cardBodyMaxHeight, max(15, ceil(probe.fittingSize.height) + 2))
    }
}

enum NotchFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 10 { return "now" }
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86400 { return "\(total / 3600)h" }
        return "\(total / 86400)d"
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }

    static func toolName(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        return parts.count > 2 ? parts.dropFirst().joined(separator: " · ") : tool
    }

    static func openTitle(_ activity: NotchActivity) -> String {
        if activity.provider == .codex, activity.host == nil || activity.host == .codexApp { return "Open in Codex" }
        if let host = activity.host { return "Open in " + host.title }
        return activity.provider == .claude ? "Open in Claude" : "Open"
    }
}

struct NotchCardBodyText: View {
    let text: AttributedString
    let code: Bool

    var body: some View {
        Text(text)
            .font(code ? .system(size: 11, design: .monospaced) : .system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NotchQuestionsBody: View {
    let questions: [NotchRequest.Question]
    let selections: [Int: Set<Int>]
    let onToggle: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.question)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        optionRow(option, selected: selections[index]?.contains(optionIndex) == true,
                                  multiple: question.multiSelect) { onToggle(index, optionIndex) }
                    }
                }
            }
        }
    }

    private func optionRow(_ option: NotchRequest.Option, selected: Bool, multiple: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square")
                                           : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    static func height(_ questions: [NotchRequest.Question], width: CGFloat) -> CGFloat {
        let probe = NSHostingView(rootView: NotchQuestionsBody(questions: questions, selections: [:], onToggle: { _, _ in })
            .frame(width: max(40, width), alignment: .leading))
        return min(NotchLayout.cardBodyMaxHeight + 120, max(30, ceil(probe.fittingSize.height) + 2))
    }
}
