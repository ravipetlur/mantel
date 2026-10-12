import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// Tells where the pointer is on the menu bar: an icon, the front app's menus, the notch, empty space, or not on a bar that is on screen.
/// It is what the empty-space monitors and the rehide guards ask. It only holds what the other parts tell it and puts it to
/// `EmptySpace.classify`; the decisions are there.
///
/// - **Frames come from the session's last state** (the bars and what is drawn on them) and from the front app's menus, which are read
///   once for each front app. Both are kept here, so that classifying a mouse move takes nothing but arithmetic.
/// - **Which bars are on screen** is read from the window list, and no more often than `ShownBarsCache` allows.
/// - **Points are AppKit's** (`NSEvent.mouseLocation`) and are converted to CoreGraphics once, here.
final class PointerClassifier {
    private let windows: any WindowListReading
    private let layout: () -> DisplayLayout
    private var bars: [MenuBarGeometry] = []
    private var itemFrames: [CGRect] = []
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
        let point = layout().cgPoint(fromAppKit: point)
        let windows = windows
        let shown = cache.shownBars(at: point, bars: bars, now: now) { windows.onScreenWindows() }
        return EmptySpace.classify(point, bars: bars, shownBars: shown, itemFrames: itemFrames, appMenuFrames: appMenuFrames)
    }

    /// The same, for a caller that has just read the window list itself: the read is used and kept.
    func spot(atAppKit point: CGPoint, windowsJustRead list: [WindowInfo], now: Date = Date()) -> EmptySpace.Spot {
        cache.note(windows: list, bars: bars, now: now)
        return spot(atAppKit: point, now: now)
    }
}
