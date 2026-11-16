import AppKit
import UsageCore

@MainActor
final class ProjectsOutlineView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private final class ProjectItem: NSObject {
        let usage: ProjectUsage
        let sessions: [SessionItem]

        init(_ usage: ProjectUsage) {
            self.usage = usage
            sessions = usage.sessions.filter { !$0.isService }.map(SessionItem.init)
        }
    }

    private final class SessionItem: NSObject {
        let usage: SessionUsage
        init(_ usage: SessionUsage) { self.usage = usage }
    }

    var onOpenSession: ((SessionUsage) -> Void)?
    var onCopyResume: ((SessionUsage) -> Void)?
    private let outline = NSOutlineView()
    private var projects: [ProjectItem] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        documentView = outline
        heightAnchor.constraint(equalToConstant: 264).isActive = true
        outline.backgroundColor = .clear
        outline.rowHeight = 36
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.style = .fullWidth

        let name = makeColumn("name", title: "Project / session", width: 420)
        outline.addTableColumn(name)
        outline.addTableColumn(makeColumn("provider", title: "Provider", width: 118))
        outline.addTableColumn(makeColumn("tokens", title: "Tokens", width: 100))
        outline.outlineTableColumn = name
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClickedItem)

        let actions = NSMenu()
        actions.delegate = self
        let open = actions.addItem(withTitle: "Open session", action: #selector(openClickedItem), keyEquivalent: "")
        open.target = self
        actions.addItem(withTitle: "Copy resume command", action: #selector(copyClickedSession), keyEquivalent: "")
            .target = self
        outline.menu = actions
    }

    required init?(coder: NSCoder) { nil }

    func update(_ usage: [ProjectUsage]) {
        let expanded = Set(projects.filter { outline.isItemExpanded($0) }.map { $0.usage.id })
        projects = usage.map(ProjectItem.init)
        outline.reloadData()
        for project in projects where expanded.contains(project.usage.id) {
            outline.expandItem(project)
        }
    }

    private func makeColumn(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = id == "name" ? 180 : 80
        return column
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let project = item as? ProjectItem { return project.sessions.count }
        return item == nil ? projects.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let project = item as? ProjectItem { return project.sessions[index] }
        return projects[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is ProjectItem }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if let project = item as? ProjectItem {
            switch id {
            case "name": return projectLabel(project.usage)
            case "tokens": return tokenLabel(project.usage.tokens.total)
            default: return nil
            }
        }
        guard let session = item as? SessionItem else { return nil }
        switch id {
        case "name":
            return NSTextField(labelWithString: session.usage.lastActivity.formatted(.dateTime.month().day().hour().minute()))
        case "tokens": return tokenLabel(session.usage.tokens.total)
        default: return NSTextField(labelWithString: session.usage.provider.title)
        }
    }

    private func projectLabel(_ project: ProjectUsage) -> NSView {
        let name = NSTextField(labelWithString: project.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: (project.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 10)
        path.textColor = Palette.secondaryText
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = project.path
        let stack = verticalStack([name, path], spacing: 1, alignment: .width)
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func tokenLabel(_ tokens: Int64) -> NSView {
        let label = NSTextField(labelWithString: tokens.formatted(.number.notation(.compactName)))
        label.font = Typography.mono(11, weight: .medium)
        label.toolTip = tokens.formatted() + " tokens"
        return label
    }

    private var clickedItem: Any? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 && row < outline.numberOfRows ? outline.item(atRow: row) : nil
    }

    @objc private func openClickedItem() {
        if let session = clickedItem as? SessionItem {
            onOpenSession?(session.usage)
        } else if let project = clickedItem as? ProjectItem {
            if outline.isItemExpanded(project) { outline.collapseItem(project) }
            else { outline.expandItem(project) }
        }
    }

    @objc private func copyClickedSession() {
        guard let session = clickedItem as? SessionItem else { return }
        onCopyResume?(session.usage)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let session = clickedItem as? SessionItem else {
            menu.items.forEach { $0.isHidden = true }
            return
        }
        menu.items.forEach { $0.isHidden = false }
        menu.items.first?.isHidden = session.usage.provider == .claude
    }
}
