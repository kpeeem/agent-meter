import AppKit
import CoreText

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
}

enum Typography {
    static func registerBundled() {
        for face in ["Regular", "Medium", "SemiBold"] {
            guard let url = Bundle.main.url(forResource: "JetBrainsMono-\(face)", withExtension: "ttf",
                                           subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let face = weight >= .semibold ? "SemiBold" : weight >= .medium ? "Medium" : "Regular"
        return NSFont(name: "JetBrainsMono-\(face)", size: size)
            ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: text.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: Palette.secondaryText, .kern: 0.8]
        ))
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

enum Palette {
    static let primaryText = adaptive("primary", light: 0x141414, dark: 0xF5F5F5)
    static let secondaryText = adaptive("secondary", light: 0x61605E, dark: 0xB0AEAB)
    static let accent = adaptive("clay", light: 0xC2553A, dark: 0xE68A66)
    static let urgencyAmber = adaptive("amber", light: 0x925600, dark: 0xF2B33D)
    static let urgencyRed = adaptive("red", light: 0xBF3525, dark: 0xFF6B5E)
    static let cardSolid = adaptive("solid", light: 0xFFFFFF, dark: 0x2B2A28)
    static let hairline = NSColor(name: NSColor.Name("AgentMeter.hairline")) { appearance in
        dark(appearance) ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.09)
    }
    static let track = NSColor(name: NSColor.Name("AgentMeter.track")) { appearance in
        dark(appearance) ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.08)
    }

    static func dark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("AgentMeter.\(name)")) { appearance in
            let value = Palette.dark(appearance) ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255,
                           green: CGFloat(value >> 8 & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

func resolvedColor(_ color: NSColor, in view: NSView) -> CGColor {
    var resolved = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
    return resolved
}

func horizontalStack(_ views: [NSView], spacing: CGFloat = Spacing.xs,
                     alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = alignment
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

func verticalStack(_ views: [NSView], spacing: CGFloat = Spacing.xs,
                   alignment: NSLayoutConstraint.Attribute = .width) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

func flexibleSpacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    return view
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class MenubarCardView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        refreshColors()
    }

    convenience init(content: NSView, horizontal: CGFloat = Spacing.s, vertical: CGFloat = Spacing.s) {
        self.init()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontal),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let isDark = Palette.dark(effectiveAppearance)
        let fill = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? Palette.cardSolid : NSColor(white: 1, alpha: isDark ? 0.055 : 0.72)
        layer?.backgroundColor = resolvedColor(fill, in: self)
        layer?.borderColor = resolvedColor(Palette.hairline, in: self)
    }
}

final class DividerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() { layer?.backgroundColor = resolvedColor(Palette.hairline, in: self) }
}

final class ProgressBarView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = Palette.accent

    override func draw(_ dirtyRect: NSRect) {
        let corner = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner)
        Palette.track.setFill()
        track.fill()
        guard value > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: bounds.width * min(1, value), height: bounds.height)
        tint.setFill()
        NSBezierPath(roundedRect: fill, xRadius: corner, yRadius: corner).fill()
    }
}

final class FooterIconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?

    init(symbol: String, tooltip: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        toolTip = tooltip
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(tooltip)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

final class StatTileView: MenubarCardView {
    init(caption: String, value: String, valueColor: NSColor = Palette.primaryText) {
        super.init()
        let number = NSTextField(labelWithAttributedString: NSAttributedString(
            string: value,
            attributes: [.font: Typography.mono(25, weight: .semibold), .foregroundColor: valueColor, .kern: -0.3]
        ))
        let label = Typography.caption(caption)
        for field in [number, label] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            number.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.s),
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.s),
            number.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.s),
            label.topAnchor.constraint(equalTo: number.bottomAnchor, constant: Spacing.xxs),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.s),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.s),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.s),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(caption)
        setAccessibilityValue(value)
    }

    required init?(coder: NSCoder) { nil }
}

final class PillSegmentedControl: NSView {
    private var selectedIndex: Int
    private let onChange: (Int) -> Void
    private var segments: [NSButton] = []

    init(options: [String], selectedIndex: Int = 0, onChange: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false

        for (index, option) in options.enumerated() {
            let segment = NSButton(title: option, target: self, action: #selector(selected(_:)))
            segment.tag = index
            segment.isBordered = false
            segment.font = .systemFont(ofSize: 11.5, weight: .medium)
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 6
            segment.layer?.cornerCurve = .continuous
            segment.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                segment.widthAnchor.constraint(equalToConstant: segment.intrinsicContentSize.width + 14),
                segment.heightAnchor.constraint(equalToConstant: 22),
            ])
            segments.append(segment)
        }

        let stack = horizontalStack(segments, spacing: 2)
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityRole(.radioGroup)
        refreshColors()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selected(_ sender: NSButton) {
        guard selectedIndex != sender.tag else { return }
        selectedIndex = sender.tag
        refreshColors()
        onChange(sender.tag)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        layer?.backgroundColor = resolvedColor(Palette.track, in: self)
        layer?.borderColor = resolvedColor(Palette.hairline, in: self)
        for (index, segment) in segments.enumerated() {
            let selected = index == selectedIndex
            let fill = Palette.dark(effectiveAppearance) ? NSColor(white: 1, alpha: 0.14) : Palette.cardSolid
            segment.layer?.backgroundColor = resolvedColor(selected ? fill : .clear, in: self)
            segment.setAccessibilitySelected(selected)
            segment.attributedTitle = NSAttributedString(
                string: segment.title,
                attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                             .foregroundColor: selected ? Palette.primaryText : Palette.secondaryText]
            )
        }
    }
}

extension NSWorkspace {
    func openInBrowser(_ url: URL) {
        guard let firefox = urlForApplication(withBundleIdentifier: "org.mozilla.firefox") else {
            open(url)
            return
        }
        open([url], withApplicationAt: firefox, configuration: OpenConfiguration())
    }
}
