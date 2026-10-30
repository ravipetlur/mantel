import CoreGraphics
import MKCore

/// Whether icons that are about to be revealed will have room on the menu bar, worked out before they are drawn.
///
/// It is cheap on purpose: the widths icons had when they were last drawn, and the last read of the bar. Nothing is read to make it, so
/// a reveal that is predicted not to fit can open the second bar at once, instead of waiting a couple of seconds to see the icons
/// pile up in macOS's « menu. A wrong prediction is corrected when the reveal's follow-up looks at the bar.
public enum RoomPrediction {
    /// Whether the apps fit on every shown bar beside what is drawn there now: the width they were last seen to take (the slots'
    /// widths, from the cache) against the free width of the bar (`RoomEstimate.freeWidth`: left of the front app's menus and of the
    /// notch, and up to the first icon that is drawn), less the room the dots need on that bar.
    ///
    /// - **An app of unknown width counts as fitting:** it adds nothing, and the follow-up of the reveal corrects the prediction.
    /// - **Only bars that are shown count** (`shownBars`: a full-screen app hides one, and nobody sees what doesn't fit on it).
    /// - **No bar known** (nothing has been read yet), or no bar shown: true.
    ///
    /// - Parameters:
    ///   - apps: the bundle IDs of the apps that the reveal brings onto the bar.
    ///   - inventory: the last read of the menu bar: the bars, and the icons that are drawn on them.
    ///   - widths: how wide each icon was when it was last on the bar.
    ///   - menuFrames: where the front app's menus are, in CoreGraphics global points (the ones on each bar count for that bar).
    ///   - shownBars: the displays whose bar is on screen.
    ///   - concealedForRoom: the Shown apps that have been concealed to make room: they were drawn when the inventory was read, and what
    ///     they took on a bar is free for the apps (their cached widths).
    public static func fits(_ apps: Set<String>, inventory: Inventory, widths: ItemWidthCache, menuFrames: [CGRect],
                            shownBars: Set<String>, concealedForRoom: Set<String> = []) -> Bool {
        let needed = apps.reduce(CGFloat.zero) { $0 + (widths.width(ofApp: $1, in: inventory) ?? 0) }
        return inventory.bars.filter { shownBars.contains($0.displayUUID) }.allSatisfy { bar in
            let menus = menuFrames.filter { bar.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            let free = RoomEstimate.freeWidth(bar: bar, appMenusMaxX: menus.map(\.maxX).max(),
                                              visibleItemFrames: OverflowInputs.occupiedFrames(in: inventory, display: bar.displayUUID))
            let freed = concealedForRoom.reduce(CGFloat.zero) { total, app in
                let isDrawnHere = inventory.items(ofApp: app).contains { $0.frames[bar.displayUUID] != nil && !$0.overflowedOn.contains(bar.displayUUID) }
                return total + (isDrawnHere ? widths.width(ofApp: app, in: inventory) ?? 0 : 0)
            }
            return free + freed >= needed + DotsRoom.neededWidth(on: bar.displayUUID, in: inventory, widths: widths)
        }
    }
}
