import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// Whether icons that are about to be revealed are predicted to fit, from the widths they had when last drawn.
@Suite("Room prediction", .timeLimit(.minutes(1)))
struct RoomPredictionTests {
    private let main = "main"
    private let side = "side"
    private let mainBar = MenuBarGeometry(displayUUID: "main", rect: CGRect(x: 0, y: 0, width: 1728, height: 32), notch: nil)
    private let notchedBar = MenuBarGeometry(displayUUID: "main", rect: CGRect(x: 0, y: 0, width: 1728, height: 32),
                                             notch: CGRect(x: 771.5, y: 0, width: 185, height: 32))
    private let sideBar = MenuBarGeometry(displayUUID: "side", rect: CGRect(x: 1728, y: 0, width: 1728, height: 32), notch: nil)

    private let first = "com.example.first"
    private let second = "com.example.second"
    private let shown = "com.example.shown"
    private let mantel = "com.example.mantel"

    private func frame(_ x: CGFloat, width: CGFloat = 36) -> CGRect {
        CGRect(x: x, y: 1, width: width, height: 30)
    }

    private func item(_ bundleID: String, frames: [String: CGRect] = [:], dot: Bool = false, overflowedOn: Set<String> = []) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier("main")), ownerBundleID: bundleID, appName: nil, label: nil,
                    frames: frames, overflowedOn: overflowedOn, isMantel: dot, isDot: dot)
    }

    private func inventory(_ items: [MenuBarItem], bars: [MenuBarGeometry]) -> Inventory {
        Inventory(capturedAt: Fixtures.date(0), bars: bars, items: items, chevrons: [:], reach: [], problems: [])
    }

    /// What the cache learns from a bar where the two revealed apps were drawn, each icon as wide as given.
    private func widths(first: CGFloat? = 40, second: CGFloat? = 40, dot: CGFloat? = nil) -> ItemWidthCache {
        var items: [MenuBarItem] = []
        if let first { items.append(item(self.first, frames: [main: frame(1500, width: first)])) }
        if let second { items.append(item(self.second, frames: [main: frame(1560, width: second)])) }
        if let dot { items.append(item(mantel, frames: [main: frame(1620, width: dot)], dot: true)) }
        var cache = ItemWidthCache()
        cache.update(from: inventory(items, bars: [mainBar]))
        return cache
    }

    /// The bar as it is now: the revealed apps are concealed (they have no frame), and the left-most icon that is drawn starts at `x`
    /// on the main bar (and at `sideX` on the other one, when there is one).
    private func now(shownAt x: CGFloat, sideX: CGFloat? = nil, bars: [MenuBarGeometry]? = nil, dotInOverflow: Bool = false) -> Inventory {
        var frames = [main: frame(x)]
        if let sideX { frames[side] = frame(sideX) }
        var items = [item(shown, frames: frames), item(first), item(second)]
        if dotInOverflow { items.append(item(mantel, frames: [main: frame(1000, width: 38)], dot: true, overflowedOn: [main])) }
        return inventory(items, bars: bars ?? (sideX == nil ? [mainBar] : [mainBar, sideBar]))
    }

    private let menusTo400 = [CGRect(x: 0, y: 0, width: 400, height: 30)]
    private let both: Set<String> = ["com.example.first", "com.example.second"]

    @Test func fitsWhenFreeRoomIsEnough() {
        // Menus end at 400 and the first icon that is drawn starts at 1000: 600 points are free, and the two apps take 80.
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 1000), widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // Exactly as much room as they take is enough.
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 480), widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // A point and a half short is not.
        #expect(!RoomPrediction.fits(both, inventory: now(shownAt: 478.5), widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // Revealing nothing takes no room.
        #expect(RoomPrediction.fits([], inventory: now(shownAt: 401), widths: widths(), menuFrames: menusTo400, shownBars: [main]))
    }

    @Test func notchBlocksTheRoom() {
        // The menus end at 400, but the notch runs to 956.5: from there to the icon at 1000 are 43.5 points, and the apps take 80.
        let notched = now(shownAt: 1000, bars: [notchedBar])
        #expect(!RoomPrediction.fits(both, inventory: notched, widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // The same bar without a notch has the room.
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 1000), widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // A single app that is narrow enough still fits left of the icon.
        #expect(RoomPrediction.fits([first], inventory: notched, widths: widths(), menuFrames: menusTo400, shownBars: [main]))
    }

    @Test func frontMenusBlockTheRoom() {
        // The front app's menus run to 960, which leaves 40 points before the icon at 1000.
        let wide = [CGRect(x: 0, y: 0, width: 960, height: 30)]
        #expect(!RoomPrediction.fits(both, inventory: now(shownAt: 1000), widths: widths(), menuFrames: wide, shownBars: [main]))
        // Menus on another display's bar are no business of this one's.
        let elsewhere = [CGRect(x: 1728, y: 0, width: 960, height: 30)]
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 1000), widths: widths(), menuFrames: elsewhere, shownBars: [main]))
    }

    @Test func dotsNeedTheirRoom() {
        // 100 points are free (the menus end at 400, the icon is at 500) and the apps take 80.
        let plain = now(shownAt: 500)
        #expect(RoomPrediction.fits(both, inventory: plain, widths: widths(dot: 38), menuFrames: menusTo400, shownBars: [main]))
        // A dot of Mantel's that macOS has put in the « menu needs 38 of them, which is more than is left.
        let trapped = now(shownAt: 500, dotInOverflow: true)
        #expect(!RoomPrediction.fits(both, inventory: trapped, widths: widths(dot: 38), menuFrames: menusTo400, shownBars: [main]))
        // A dot whose width was never seen is taken to need a slot's worth (38), and the same is true.
        #expect(!RoomPrediction.fits(both, inventory: trapped, widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // With room for them both, they fit.
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 520, dotInOverflow: true), widths: widths(dot: 38), menuFrames: menusTo400,
                                    shownBars: [main]))
    }

    @Test func unknownWidthFits() {
        // No room at all (the icon is where the menus end), and nothing is known of how wide the apps are: they are taken to fit, and
        // the look at the bar after the reveal corrects it if they don't.
        let tight = now(shownAt: 400)
        #expect(RoomPrediction.fits(both, inventory: tight, widths: ItemWidthCache(), menuFrames: menusTo400, shownBars: [main]))
        #expect(RoomPrediction.fits(["com.example.never-seen"], inventory: tight, widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // An app that is known is counted all the same: one of the two that is unknown adds nothing.
        #expect(!RoomPrediction.fits(both, inventory: now(shownAt: 430), widths: widths(second: nil), menuFrames: menusTo400, shownBars: [main]))
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 440), widths: widths(second: nil), menuFrames: menusTo400, shownBars: [main]))
    }

    @Test func everyShownBarMustFit() {
        // The main bar has 600 points free. The other has 60, from its left edge to the icon at 1788, and the apps take 80.
        let two = now(shownAt: 1000, sideX: 1788)
        #expect(!RoomPrediction.fits(both, inventory: two, widths: widths(), menuFrames: menusTo400, shownBars: [main, side]))
        // Where both have enough, they fit.
        #expect(RoomPrediction.fits(both, inventory: now(shownAt: 1000, sideX: 1828), widths: widths(), menuFrames: menusTo400,
                                    shownBars: [main, side]))
    }

    @Test func hiddenBarIgnored() {
        // The tight bar is one that a full-screen app has hidden: nobody sees what doesn't fit on it.
        let two = now(shownAt: 1000, sideX: 1788)
        #expect(RoomPrediction.fits(both, inventory: two, widths: widths(), menuFrames: menusTo400, shownBars: [main]))
        // With no bar shown there is nothing to fit on, and with no bar known (nothing read yet) nothing to go by.
        #expect(RoomPrediction.fits(both, inventory: two, widths: widths(), menuFrames: menusTo400, shownBars: []))
        #expect(RoomPrediction.fits(both, inventory: inventory([], bars: []), widths: widths(), menuFrames: [], shownBars: [main]))
    }
}
