import AppKit

final class YearHeatmapView: NSView {
    struct Day {
        let date: Date
        let tokens: Int64?
        let sessions: Int
    }

    var values: [Day] = [] {
        didSet { rebuild() }
    }

    var selectedDate: Date? {
        didSet { if oldValue != selectedDate { needsDisplay = true } }
    }

    var onSelectDay: ((Day) -> Void)?
    var onHoverDay: ((Day?) -> Void)?

    private var grid: [[Day?]] = []
    private var cols = 0
    private var hoveredDate: Date? {
        didSet { if oldValue != hoveredDate { needsDisplay = true } }
    }

    private let topGutter: CGFloat = 16
    private let leftGutter: CGFloat = 30
    private let bottomGutter: CGFloat = 22
    private let gap: CGFloat = 3

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    private static let calendar = Calendar.current

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Activity heatmap")
    }
    required init?(coder: NSCoder) { fatalError() }


    private func rebuild() {
        guard let newest = values.first else {
            grid = []
            cols = 0
            needsDisplay = true
            return
        }
        let newestWeekday = (Self.calendar.component(.weekday, from: newest.date) + 5) % 7
        cols = 1 + ((values.count - 1) + (6 - newestWeekday)) / 7
        var g = Array(repeating: [Day?](repeating: nil, count: 7), count: cols)
        for (i, day) in values.enumerated() {
            let row = ((newestWeekday - i) % 7 + 7) % 7
            let col = cols - 1 - ((i + (6 - newestWeekday)) / 7)
            if col >= 0, col < cols { g[col][row] = day }
        }
        grid = g
        needsDisplay = true
        updateA11y()
    }

    private func updateA11y() {
        let active = values.filter { ($0.tokens ?? 0) > 0 }.count
        setAccessibilityValue("\(active) active days in the selected period")
    }

    private func metrics() -> (cell: CGFloat, ox: CGFloat, oy: CGFloat)? {
        guard cols > 0 else { return nil }
        let gridW = bounds.width - leftGutter
        let gridH = bounds.height - topGutter - bottomGutter
        let cell = min(
            (gridW - gap * CGFloat(cols - 1)) / CGFloat(cols),
            (gridH - gap * 6) / 7
        )
        guard cell > 2 else { return nil }
        let usedH = cell * 7 + gap * 6
        let oy = topGutter + max(0, (gridH - usedH) / 2)
        return (cell, leftGutter, oy)
    }

    private func cellRect(col: Int, row: Int, _ m: (cell: CGFloat, ox: CGFloat, oy: CGFloat)) -> NSRect {
        NSRect(
            x: m.ox + CGFloat(col) * (m.cell + gap),
            y: m.oy + CGFloat(row) * (m.cell + gap),
            width: m.cell, height: m.cell
        )
    }


    override func draw(_ dirtyRect: NSRect) {
        guard !grid.isEmpty, let m = metrics() else { return }
        let accent = Palette.accent
        let maxTok = max(values.compactMap(\.tokens).max() ?? 1, 1)
        let radius = max(2, min(3, m.cell * 0.23))
        let today = values.first?.date

        for col in 0..<cols {
            for row in 0..<7 {
                guard let day = grid[col][row] else { continue }
                let rect = cellRect(col: col, row: row, m)
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                if let tokens = day.tokens, tokens > 0 {
                    let normalized = log(Double(tokens) + 1) / log(Double(maxTok) + 1)
                    let intensity: CGFloat
                    switch normalized {
                    case ..<0.2: intensity = 0.08
                    case ..<0.4: intensity = 0.28
                    case ..<0.6: intensity = 0.52
                    case ..<0.8: intensity = 0.76
                    default: intensity = 1
                    }
                    accent.withAlphaComponent(intensity).setFill()
                } else {
                    NSColor.labelColor.withAlphaComponent(day.tokens == nil ? 0.045 : 0.13).setFill()
                }
                path.fill()
                if day.date == hoveredDate, day.date != selectedDate {
                    accent.withAlphaComponent(0.9).setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
                    ring.lineWidth = 1
                    ring.stroke()
                }
                if day.date == today, day.date != selectedDate {
                    NSColor.labelColor.withAlphaComponent(0.45).setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                    ring.lineWidth = 1
                    ring.stroke()
                }
                if day.date == selectedDate {
                    accent.setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
            }
        }

        drawWeekdayLabels(m)
        drawMonthLabels(m)
        drawLegend(accent: accent)
    }

    private func labelAttrs(_ alpha: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(alpha),
        ]
    }

    private func drawWeekdayLabels(_ m: (cell: CGFloat, ox: CGFloat, oy: CGFloat)) {
        let names = ["Mon", "", "Wed", "", "Fri", "", ""]
        for row in [0, 2, 4] {
            let s = NSAttributedString(string: names[row], attributes: labelAttrs())
            let r = cellRect(col: 0, row: row, m)
            let size = s.size()
            s.draw(at: NSPoint(x: max(0, m.ox - size.width - 6), y: r.midY - size.height / 2))
        }
    }

    private func drawMonthLabels(_ m: (cell: CGFloat, ox: CGFloat, oy: CGFloat)) {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.dateFormat = "MMM"
        var lastMonth = -1
        for col in 0..<cols {
            guard let rep = grid[col].compactMap({ $0 }).first else { continue }
            let month = Self.calendar.component(.month, from: rep.date)
            if month != lastMonth {
                lastMonth = month
                let s = NSAttributedString(string: fmt.string(from: rep.date), attributes: labelAttrs())
                let x = m.ox + CGFloat(col) * (m.cell + gap)
                s.draw(at: NSPoint(x: x, y: max(0, m.oy - 14)))
            }
        }
    }

    private func drawLegend(accent: NSColor) {
        let sw: CGFloat = 9, sgap: CGFloat = 3
        let levels: [CGFloat] = [0.08, 0.28, 0.52, 0.76, 1.0]
        let y = bounds.height - bottomGutter + 4
        let less = NSAttributedString(string: "Less", attributes: labelAttrs())
        let more = NSAttributedString(string: "More", attributes: labelAttrs())
        let swatchesW = CGFloat(levels.count) * sw + CGFloat(levels.count - 1) * sgap
        let totalW = less.size().width + 6 + swatchesW + 6 + more.size().width
        var x = bounds.width - totalW
        let lsize = less.size()
        less.draw(at: NSPoint(x: x, y: y + (sw - lsize.height) / 2))
        x += lsize.width + 6
        for lvl in levels {
            let rect = NSRect(x: x, y: y, width: sw, height: sw)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
            accent.withAlphaComponent(lvl).setFill()
            path.fill()
            x += sw + sgap
        }
        x += 6
        more.draw(at: NSPoint(x: x, y: y + (sw - more.size().height) / 2))
    }


    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func day(at p: NSPoint) -> Day? {
        guard let m = metrics() else { return nil }
        for col in 0..<cols {
            for row in 0..<7 {
                guard let day = grid[col][row] else { continue }
                if cellRect(col: col, row: row, m).insetBy(dx: -gap / 2, dy: -gap / 2).contains(p) {
                    return day
                }
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let d = day(at: convert(event.locationInWindow, from: nil))
        hoveredDate = d?.date
        onHoverDay?(d)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredDate = nil
        onHoverDay?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if let d = day(at: convert(event.locationInWindow, from: nil)) {
            onSelectDay?(d)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class SegmentedCompositionView: NSView {
    struct Segment { let label: String; let value: UInt64; let color: NSColor }
    var segments: [Segment] = [] {
        didSet {
            needsDisplay = true
            setAccessibilityLabel("Token composition")
            setAccessibilityValue(segments.map { "\($0.label) \($0.value.formatted())" }.joined(separator: ", "))
        }
    }

    override var isFlipped: Bool { true }
    private let barH: CGFloat = 12
    private let legendTop: CGFloat = 24
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        let total = segments.reduce(0.0) { $0 + Double($1.value) }
        let w = bounds.width
        let radius = barH / 2
        let barRect = NSRect(x: 0, y: 0, width: w, height: barH)
        let clip = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)

        Palette.track.setFill()
        clip.fill()

        if total > 0 {
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            var x: CGFloat = 0
            let divider: CGFloat = 1
            let drawn = segments.filter { $0.value > 0 }
            for (idx, seg) in drawn.enumerated() {
                let segW = w * CGFloat(Double(seg.value) / total)
                guard segW > 0 else { continue }
                seg.color.setFill()
                let isLast = idx == drawn.count - 1
                let fillW = isLast ? (w - x) : max(0, segW - divider)
                NSBezierPath(rect: NSRect(x: x, y: 0, width: fillW, height: barH)).fill()
                x += segW
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        var lx: CGFloat = 0
        let ly = legendTop
        let dot: CGFloat = 9
        for seg in segments {
            let pct = total > 0 ? Int((Double(seg.value) / total * 100).rounded()) : 0
            let swatch = NSBezierPath(roundedRect: NSRect(x: lx, y: ly + 1, width: dot, height: dot),
                                      xRadius: 2, yRadius: 2)
            seg.color.setFill()
            swatch.fill()
            lx += dot + 6
            let attr = NSMutableAttributedString(string: seg.label + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Palette.secondaryText,
            ])
            attr.append(NSAttributedString(string: "\(pct)%", attributes: [
                .font: Typography.mono(11, weight: .semibold),
                .foregroundColor: Palette.primaryText,
            ]))
            attr.draw(at: NSPoint(x: lx, y: ly))
            lx += attr.size().width + 16
        }
    }
}

final class ProjectBarRow: NSView {
    init(name: String, fraction: CGFloat, value: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let nameLbl = NSTextField(labelWithString: name)
        nameLbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLbl.textColor = Palette.primaryText
        nameLbl.lineBreakMode = .byTruncatingMiddle
        nameLbl.translatesAutoresizingMaskIntoConstraints = false
        nameLbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLbl.toolTip = name

        let bar = ProgressBarView()
        bar.value = Double(max(0, min(1, fraction)))
        bar.tint = Palette.accent
        bar.translatesAutoresizingMaskIntoConstraints = false

        let valLbl = NSTextField(labelWithString: value)
        valLbl.font = Typography.mono(11, weight: .medium)
        valLbl.textColor = Palette.secondaryText
        valLbl.alignment = .right
        valLbl.translatesAutoresizingMaskIntoConstraints = false
        valLbl.setContentHuggingPriority(.required, for: .horizontal)
        valLbl.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(nameLbl); addSubview(bar); addSubview(valLbl)
        NSLayoutConstraint.activate([
            nameLbl.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLbl.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLbl.widthAnchor.constraint(equalToConstant: 120),
            bar.leadingAnchor.constraint(equalTo: nameLbl.trailingAnchor, constant: Spacing.xs),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 5),
            valLbl.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Spacing.xs),
            valLbl.trailingAnchor.constraint(equalTo: trailingAnchor),
            valLbl.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
        setAccessibilityValue(value)
    }
    required init?(coder: NSCoder) { fatalError() }
}

