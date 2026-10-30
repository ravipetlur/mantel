import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// Tells where the pointer is on the menu bar: an icon, the front app's menus, the notch, empty space, or not on a bar that is on screen.
/// It is what the empty-space monitors and the rehide guards ask. It only holds what the other parts tell it and puts it to
/// `EmptySpace.classify`; the decisions are there.
///
/// - **Frames come from the session's last state** (the bars, what is drawn on them, and where Mantel's own items are: a button's own
///   window frame is never used, since it matches the slot only on the display that is active) and from the front app's menus, which are read
///   once for each front app. Both are kept here, so that classifying a mouse move takes nothing but arithmetic.
/// - **Which bars are on screen** is read from the window list, and no more often than `ShownBarsCache` allows.
/// - **Points are AppKit's** (`NSEvent.mouseLocation`) and are converted to CoreGraphics once, here.
final class PointerClassifier {
    private let windows: any WindowListReading
    private let layout: () -> DisplayLayout
    private var bars: [MenuBarGeometry] = []
    private var itemFrames: [CGRect] = []
    /// Where Mantel's own items are, by the slots the last read found them in.
    private var ownItems: [EmptySpace.OwnSlot] = []
    private var appMenuFrames: [CGRect] = []
    private var cache = ShownBarsCache()

    /// - Parameters:
    ///   - windows: the windows on screen.
    ///   - layout: the displays as they are now.
    init(windows: any WindowListReading, layout: @escaping () -> DisplayLayout) {
        self.windows = windows
        self.layout = layout
    }

    /// The bars and what is on them, as the session read them last.
    func update(inventory: Inventory) {
        bars = inventory.bars
        itemFrames = OverflowInputs.occupiedFrames(in: inventory)
        ownItems = EmptySpace.ownSlots(in: inventory)
    }

    /// Where the front app's menus are (CoreGraphics points).
    func update(appMenuFrames frames: [CGRect]) {
        appMenuFrames = frames
    }

    /// The bars the inventory has: where the front app's screen is looked for.
    var knownBars: [MenuBarGeometry] { bars }

    /// Where the point is (AppKit global points). The window list is read if the point is near the top of a bar and what was read last is
    /// old.
    func spot(atAppKit point: CGPoint, now: Date = Date()) -> EmptySpace.Spot {
        spot(atCG: layout().cgPoint(fromAppKit: point), now: now)
    }

    /// Where the point is (CoreGraphics global points: what an event's own `cgEvent.location` is).
    func spot(atCG point: CGPoint, now: Date = Date()) -> EmptySpace.Spot {
        let windows = windows
        let shown = cache.shownBars(at: point, bars: bars, now: now) { windows.onScreenWindows() }
        return EmptySpace.classify(point, bars: bars, shownBars: shown, itemFrames: itemFrames, appMenuFrames: appMenuFrames,
                                   ownItems: ownItems)
    }

    /// An AppKit global point in CoreGraphics' (what a panel's frame from `GroupPanelController.panelFrame` is compared in).
    func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        layout().cgPoint(fromAppKit: point)
    }

    /// The same, for a caller that has just read the window list itself: the read is used and kept.
    func spot(atAppKit point: CGPoint, windowsJustRead list: [WindowInfo], now: Date = Date()) -> EmptySpace.Spot {
        cache.note(windows: list, bars: bars, now: now)
        return spot(atAppKit: point, now: now)
    }
}
