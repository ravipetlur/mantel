import CoreGraphics
import Foundation
import MKCore
import MKLayout

/// How wide each of Mantel's invisible spacer items is. A width of 0 is a spacer that is collapsed: it takes no room.
public struct SpacerWidths: Sendable, Equatable {
    /// The spacers that stand between the icons that are hidden and the ones that stay, left to right: the first is the divider
    /// (`mantel.spacer.divider`), and a display wider than one spacer can be made to cover has more of them. Empty: none exists.
    public var divider: [CGFloat]
    /// The spacer that conceals Always Hidden while Hidden shows (`mantel.spacer.always`).
    public var always: CGFloat

    public init(divider: [CGFloat], always: CGFloat) {
        self.divider = divider
        self.always = always
    }

    /// No spacer exists: what the engine shows when it is torn down.
    public static let removed = SpacerWidths(divider: [], always: 0)

    /// What each item of the divider is, as the app draws it. The divider that takes no room (the icons are revealed, or nothing is
    /// hidden) is where the person has to ⌘-drag icons to have them hidden, so it shows a thin line, and is a few points wide to hold
    /// it. The divider that hides stays as wide as its width says, and draws nothing. Only the first item of a divider that is several
    /// has a line; the others take no room.
    public var dividerItems: [SpacerItem] {
        divider.enumerated().map { index, width in
            if width > 0 { return SpacerItem(length: width, drawsLine: false) }
            return index == 0 ? SpacerItem(length: SpacerLayout.lineItemWidth, drawsLine: true) : SpacerItem(length: 0, drawsLine: false)
        }
    }
}

/// One item of the divider: how wide it is, and whether it draws the thin line (and nothing otherwise).
public struct SpacerItem: Sendable, Equatable {
    public let length: CGFloat
    public let drawsLine: Bool

    public init(length: CGFloat, drawsLine: Bool) {
        self.length = length
        self.drawsLine = drawsLine
    }
}

/// How wide the spacers have to be for a plan.
public enum SpacerLayout {
    /// The room that is left for the items that stay, from the right end of the bar: what a divider can't take.
    static let roomToKeep: CGFloat = 300

    /// How wide the divider's item is while it shows its line: a thin line (the app draws one about 1 × 14 points) with room around it.
    public static let lineItemWidth: CGFloat = 9

    /// A spacer can't be wider than half of the narrowest bar (less a point), so that no single item is wider than the bar it is on.
    public static func cap(for bars: [MenuBarGeometry]) -> CGFloat {
        guard let narrowest = bars.map(\.rect.width).min() else { return 0 }
        return max((narrowest / 2).rounded(.down) - 1, 0)
    }

    /// The widths a plan asks for on these bars.
    ///
    /// - The divider is as many spacers of the cap's width as it takes to cover the widest bar but for 300 points, and is that when the
    ///   plan conceals Hidden; otherwise they are all collapsed (still there, at width 0).
    /// - The Always Hidden spacer is the cap's width when the plan conceals Always Hidden and not Hidden, and collapsed otherwise: with
    ///   Hidden concealed, the divider already takes Always Hidden along.
    /// - Without a bar to measure, every spacer is collapsed.
    public static func widths(for plan: VisibilityPlan, bars: [MenuBarGeometry]) -> SpacerWidths {
        let cap = cap(for: bars)
        guard cap > 0, let widest = bars.map(\.rect.width).max() else {
            return SpacerWidths(divider: [0], always: 0)
        }
        let count = max(Int(((widest - roomToKeep) / cap).rounded(.up)), 1)
        let concealsHidden = plan.concealedSections.contains(.hidden)
        let concealsAlways = plan.concealedSections.contains(.alwaysHidden)
        return SpacerWidths(divider: Array(repeating: concealsHidden ? cap : 0, count: count),
                            always: concealsAlways && !concealsHidden ? cap : 0)
    }
}
