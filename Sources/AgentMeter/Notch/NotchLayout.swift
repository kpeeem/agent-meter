import CoreGraphics

struct NotchLayout: Equatable {
    enum Mode: Equatable { case idle, expanded, card }

    static let basicRowHeight: CGFloat = 44
    static let detailRowHeight: CGFloat = 60
    static let rowSpacing: CGFloat = 4
    static let visibleRows = 3
    static let expandedSideInset: CGFloat = 18
    static let expandedWidth: CGFloat = 440
    static let cardSpacing: CGFloat = 6
    static let cardHeaderHeight: CGFloat = 16
    static let cardTitleHeight: CGFloat = 18
    static let cardSubtitleHeight: CGFloat = 14
    static let cardActionsHeight: CGFloat = 22
    static let cardBottomInset: CGFloat = 14
    static let cardBodyMaxHeight: CGFloat = 220

    let screenFrame: CGRect
    let visibleScreenHeight: CGFloat
    let physicalNotch: CGSize?
    let mode: Mode
    let rowHeights: [CGFloat]
    let showsAll: Bool
    let canDismiss: Bool
    var cardHasSubtitle = false
    var cardHasActions = true
    var cardBodyHeight: CGFloat = 0

    var hoverFrame: CGRect {
        let size = physicalNotch.map { CGSize(width: $0.width + 20, height: $0.height) }
            ?? CGSize(width: 96, height: 18)
        return topCentered(size)
    }

    var interactionFrame: CGRect {
        let base = mode == .idle ? hoverFrame : frame.union(hoverFrame)
        return CGRect(x: base.minX, y: base.minY, width: base.width, height: base.height + 2)
    }

    var frame: CGRect {
        let size: CGSize
        switch mode {
        case .idle:
            size = physicalNotch ?? CGSize(width: 52, height: 12)
        case .expanded:
            size = CGSize(width: width, height: topInset + listHeight + footerSpace + bottomInset)
        case .card:
            size = CGSize(width: width, height: min(visibleScreenHeight - 28, topInset + cardContentHeight
                                                     + Self.cardBottomInset))
        }
        return topCentered(size)
    }

    var width: CGFloat { min(Self.expandedWidth, screenFrame.width) }
    var contentWidth: CGFloat { width - 2 * Self.expandedSideInset }
    var topInset: CGFloat { physicalNotch.map { max($0.height + 2, 30) } ?? 10 }
    var bottomInset: CGFloat { hasMore ? 4 : 18 }
    var sessionCount: Int { rowHeights.count }
    var hasMore: Bool { sessionCount > Self.visibleRows }
    var hasFooter: Bool { hasMore || canDismiss }
    var rowCount: Int { showsAll ? sessionCount : min(sessionCount, Self.visibleRows) }
    var cornerRadius: CGFloat { mode == .expanded || mode == .card ? 24 : physicalNotch == nil ? 12 : 10 }

    var rowsHeight: CGFloat {
        guard rowCount > 0 else { return 58 }
        return rowHeights.prefix(rowCount).reduce(0, +) + CGFloat(rowCount - 1) * Self.rowSpacing
    }

    var listHeight: CGFloat {
        min(rowsHeight, max(Self.detailRowHeight, visibleScreenHeight - 28 - topInset - footerSpace - bottomInset))
    }

    var cardContentHeight: CGFloat {
        var height = Self.cardHeaderHeight + Self.cardSpacing + Self.cardTitleHeight
        if cardHasSubtitle { height += Self.cardSpacing + Self.cardSubtitleHeight }
        if cardBodyHeight > 0 { height += Self.cardSpacing + cardBodyHeight }
        return cardHasActions ? height + Self.cardSpacing + 4 + Self.cardActionsHeight : height
    }

    var cardBodyViewportHeight: CGFloat {
        let available = visibleScreenHeight - 28 - topInset - Self.cardBottomInset - (cardContentHeight - cardBodyHeight)
        return max(0, min(cardBodyHeight, available))
    }

    private var footerSpace: CGFloat { hasFooter ? 20 : 0 }

    private func topCentered(_ size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}
