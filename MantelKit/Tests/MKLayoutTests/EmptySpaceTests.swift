import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Empty space", .timeLimit(.minutes(1)))
struct EmptySpaceTests {
    private let main = "display-main"
    private let portrait = "display-portrait"
    private let laptop = "display-laptop"

    /// The desk: the main display's bar (30 points), the portrait display's to its left (its bar is at the top of a display that is
    /// taller, so lower than the main one's), and the laptop's, right of the main display, 33 points tall and notched.
    private var bars: [MenuBarGeometry] {
        [
            MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 3360, height: 30), notch: nil),
            MenuBarGeometry(displayUUID: portrait, rect: CGRect(x: -1800, y: -491, width: 1800, height: 30), notch: nil),
            MenuBarGeometry(displayUUID: laptop, rect: CGRect(x: 3360, y: 773, width: 1728, height: 33),
                            notch: CGRect(x: 4131.5, y: 773, width: 185, height: 32)),
        ]
    }

    private var allShown: Set<String> { [main, portrait, laptop] }

    /// Icons on the main bar: two, with a gap of 10 points between them.
    private let items = [CGRect(x: 3000, y: 0, width: 40, height: 30), CGRect(x: 3050, y: 0, width: 40, height: 30)]
    /// The front app's menus, at the left of the main bar.
    private let menus = [CGRect(x: 10, y: 0, width: 30, height: 30), CGRect(x: 40, y: 0, width: 60, height: 30)]

    private func classify(_ point: CGPoint, shown: Set<String>? = nil, items: [CGRect]? = nil, menus: [CGRect]? = nil) -> EmptySpace.Spot {
        EmptySpace.classify(point, bars: bars, shownBars: shown ?? allShown, itemFrames: items ?? self.items, appMenuFrames: menus ?? self.menus)
    }

    @Test func gapBetweenItemsIsEmpty() {
        #expect(classify(CGPoint(x: 3045, y: 15)) == .empty(displayUUID: main))
        // Between the last menu and the first icon, and past the last icon.
        #expect(classify(CGPoint(x: 1500, y: 15)) == .empty(displayUUID: main))
        #expect(classify(CGPoint(x: 3300, y: 15)) == .empty(displayUUID: main))
    }

    @Test func itemIsNotEmpty() {
        #expect(classify(CGPoint(x: 3010, y: 15)) == .item)
        #expect(classify(CGPoint(x: 3060, y: 29)) == .item)
        // An item owns its left edge and not its right one: 3040 is the first point of the gap.
        #expect(classify(CGPoint(x: 3000, y: 0)) == .item)
        #expect(classify(CGPoint(x: 3040, y: 15)) == .empty(displayUUID: main))
        // A slot that no item claimed is one too: the caller passes it with the frames.
        #expect(classify(CGPoint(x: 3200, y: 15), items: items + [CGRect(x: 3190, y: 0, width: 30, height: 30)]) == .item)
    }

    @Test func appMenusAreNotEmpty() {
        #expect(classify(CGPoint(x: 20, y: 15)) == .appMenus)
        #expect(classify(CGPoint(x: 99, y: 15)) == .appMenus)
        // The edge of the last menu, and the gap to the left of the first, are empty.
        #expect(classify(CGPoint(x: 100, y: 15)) == .empty(displayUUID: main))
        #expect(classify(CGPoint(x: 5, y: 15)) == .empty(displayUUID: main))
        // Without the app's menus (an app with none) the same place is empty.
        #expect(classify(CGPoint(x: 20, y: 15), menus: []) == .empty(displayUUID: main))
    }

    @Test func notchIsNotEmpty() {
        // Behind the camera housing of the laptop's bar, whether or not there is an icon or a menu in the list there.
        #expect(classify(CGPoint(x: 4200, y: 780)) == .notch)
        #expect(classify(CGPoint(x: 4131.5, y: 773)) == .notch)
        // Either side of it the bar is empty again.
        #expect(classify(CGPoint(x: 4100, y: 780)) == .empty(displayUUID: laptop))
        #expect(classify(CGPoint(x: 4316.5, y: 780)) == .empty(displayUUID: laptop))
        // The notch is 32 points tall and the bar 33: the bar's last row is not behind it.
        #expect(classify(CGPoint(x: 4200, y: 805.5)) == .empty(displayUUID: laptop))
    }

    @Test func hiddenBarIsNeverEmptySpace() {
        // A full-screen app has hidden the main display's bar, and the pointer is pushed against the top of the screen, where the bar
        // would be: not empty space, so a hover or a click there reveals nothing...
        let pushedUp = CGPoint(x: 1500, y: 0)
        #expect(classify(pushedUp, shown: [portrait, laptop]) == .hiddenBar)
        #expect(classify(pushedUp, shown: []) == .hiddenBar)
        // ...whatever icon or menu frames are around (the last inventory still lists them).
        #expect(classify(CGPoint(x: 3010, y: 15), shown: [portrait, laptop]) == .hiddenBar)
        #expect(classify(CGPoint(x: 20, y: 15), shown: [portrait, laptop]) == .hiddenBar)
        // It is a hidden bar and not another display's: the other displays' bars are still shown.
        #expect(classify(CGPoint(x: -900, y: -480), shown: [portrait, laptop]) == .empty(displayUUID: portrait))
        // The notch of a hidden bar is no notch.
        #expect(classify(CGPoint(x: 4200, y: 780), shown: [main, portrait]) == .hiddenBar)
        // The same point with the bar on screen is empty.
        #expect(classify(pushedUp) == .empty(displayUUID: main))
    }

    @Test func outsideBarsIsOutside() {
        #expect(classify(CGPoint(x: 1500, y: 300)) == .outsideBars)
        // Just under a bar (the bottom edge isn't in it), and right of the last display.
        #expect(classify(CGPoint(x: 1500, y: 30)) == .outsideBars)
        #expect(classify(CGPoint(x: 6000, y: 15)) == .outsideBars)
        // Above the main display, where no display is.
        #expect(classify(CGPoint(x: 1500, y: -1)) == .outsideBars)
        // Left of the main display at the height of its bar: that is the portrait display's, whose bar is higher up.
        #expect(classify(CGPoint(x: -900, y: 15)) == .outsideBars)
        // The main bar owns its left edge and not its right one, where the laptop's display begins (with a bar that is lower).
        #expect(classify(CGPoint(x: 0, y: 0), shown: []) == .hiddenBar, "the corner is the main bar's first point")
        #expect(classify(CGPoint(x: 3360, y: 15)) == .outsideBars)
        // No bars at all.
        #expect(EmptySpace.classify(CGPoint(x: 10, y: 10), bars: [], shownBars: allShown, itemFrames: [], appMenuFrames: []) == .outsideBars)
    }

    @Test func portraitDisplayBarCounts() {
        // The portrait display's bar is at the top of a display that starts above the main one: in CoreGraphics points its y is negative.
        #expect(classify(CGPoint(x: -900, y: -480)) == .empty(displayUUID: portrait))
        #expect(EmptySpace.isInBar(classify(CGPoint(x: -900, y: -480))))
        #expect(classify(CGPoint(x: -1800, y: -491)) == .empty(displayUUID: portrait), "its top-left corner")
        // Items on it are items, found among the frames of every display.
        let onPortrait = CGRect(x: -400, y: -491, width: 50, height: 30)
        #expect(classify(CGPoint(x: -380, y: -480), items: items + [onPortrait]) == .item)
        // Its bar hidden: not a bar.
        #expect(classify(CGPoint(x: -900, y: -480), shown: [main, laptop]) == .hiddenBar)
    }

    @Test func isInBarExcludesHiddenBar() {
        for spot in [EmptySpace.Spot.item, .appMenus, .notch, .empty(displayUUID: main)] {
            #expect(EmptySpace.isInBar(spot), "\(spot) is in a bar")
        }
        // The pointer resting at the top of a screen whose bar a full-screen app hides must not hold a reveal open.
        #expect(!EmptySpace.isInBar(.hiddenBar))
        #expect(!EmptySpace.isInBar(.outsideBars))
        #expect(!EmptySpace.isInBar(classify(CGPoint(x: 1500, y: 0), shown: [portrait, laptop])))
        #expect(EmptySpace.isInBar(classify(CGPoint(x: 1500, y: 0))))
    }
}
