import CoreGraphics
import MKCore

/// How much of one bar is free: the gap between what is on its left and the first icon on its right.
public enum RoomEstimate {
    /// The width of the free gap on `bar`, in points, never below 0.
    ///
    /// The gap runs from the right edge of the front app's menus (`appMenusMaxX`) or of the notch, whichever is further right, to
    /// the left edge of the left-most item in `visibleItemFrames` that is on this bar. With neither the menus nor a notch to go by it
    /// starts at the bar's left edge, and with no item on the bar it ends at the bar's right edge.
    ///
    /// **`visibleItemFrames` must hold everything that is drawn on the bar and takes room**: the frames of the items that are
    /// visible and not in the « overflow, and also the slots no item could be matched to (`Inventory.untiedSlots`), which are icons
    /// that are really there. Leaving those out makes the room look bigger than it is. Frames on other displays are ignored.
    /// `OverflowInputs.occupiedFrames(in:display:)` makes the list from an inventory.
    public static func freeWidth(bar: MenuBarGeometry, appMenusMaxX: CGFloat?, visibleItemFrames: [CGRect]) -> CGFloat {
        let edges = [appMenusMaxX, bar.notch?.maxX].compactMap { $0 }
        let start = edges.max() ?? bar.rect.minX
        let onThisBar = visibleItemFrames.filter { bar.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let end = onThisBar.map(\.minX).min() ?? bar.rect.maxX
        return max(0, end - start)
    }
}
