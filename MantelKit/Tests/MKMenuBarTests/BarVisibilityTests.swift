import CoreGraphics
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Bar visibility", .timeLimit(.minutes(1)))
struct BarVisibilityTests {
    private let main = DisplayFixtures.deskMain.uuid
    private let portrait = DisplayFixtures.deskPortrait.uuid
    private let laptop = DisplayFixtures.laptopRightOfDesk.uuid

    /// The three bars of the desk with the lid open, as MenuBarAgent's windows say (CoreGraphics points).
    private var bars: [MenuBarGeometry] {
        let layout = DisplayLayout.deskWithLaptopOpen
        return layout.displays.map { display in
            let area = layout.cgRect(fromAppKit: display.frame)
            return MenuBarGeometry(displayUUID: display.uuid, rect: CGRect(x: area.minX, y: area.minY, width: area.width, height: display.isBuiltIn ? 33 : 30),
                                   notch: nil)
        }
    }

    private func barWindow(_ number: Int, covering bar: MenuBarGeometry, layer: Int = WindowLevels.mainMenu, owner: String? = nil,
                           grownBy margin: CGFloat = 0) -> WindowInfo {
        WindowInfo(number: number, ownerPID: 60, ownerBundleID: owner, layer: layer, bounds: bar.rect.insetBy(dx: -margin, dy: -margin), alpha: 1)
    }

    @Test func shownBarIsShown() {
        // The window server's window at the main menu's level covers each bar that is on screen.
        let windows = bars.enumerated().map { barWindow($0.offset, covering: $0.element) }
        #expect(BarVisibility.shownBars(windows, bars: bars) == [main, portrait, laptop])
        // One display's window alone shows that display's bar alone.
        #expect(BarVisibility.shownBars([windows[0]], bars: bars) == [main])
        #expect(BarVisibility.shownBars([windows[2]], bars: bars) == [laptop])
        // Among the windows that are on screen all the time.
        let others = [WindowInfo(number: 90, ownerPID: 70, ownerBundleID: "com.example.notes", layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 1),
                      WindowInfo(number: 91, ownerPID: 71, ownerBundleID: nil, layer: WindowLevels.statusBar, bounds: bars[0].rect, alpha: 1)]
        #expect(BarVisibility.shownBars(others + [windows[1]], bars: bars) == [portrait])
    }

    @Test func fullScreenHiddenBarIsNotShown() {
        // A full-screen app has the main display and its bar is hidden: the window is gone from the list. The other displays' are there.
        let windows = [barWindow(1, covering: bars[1]), barWindow(2, covering: bars[2])]
        let shown = BarVisibility.shownBars(windows, bars: bars)
        #expect(shown == [portrait, laptop])
        #expect(!shown.contains(main))
        // Nothing at the main menu's level on screen at all.
        #expect(BarVisibility.shownBars([], bars: bars).isEmpty)
        // And no bars to ask about.
        #expect(BarVisibility.shownBars(windows, bars: []).isEmpty)
        // What else is on screen at the top of the display doesn't make the bar shown: a status item window at the next level up, a
        // window of an ordinary level, and the full-screen app's own window (which is as big as the display and at level 0).
        let fullScreen = WindowInfo(number: 5, ownerPID: 80, ownerBundleID: "com.example.notes", layer: 0, bounds: CGRect(x: 0, y: 0, width: 3360, height: 1890), alpha: 1)
        let statusItems = barWindow(6, covering: bars[0], layer: WindowLevels.statusBar)
        #expect(!BarVisibility.shownBars([fullScreen, statusItems], bars: bars).contains(main))
    }

    @Test func aWindowIsToldByItsLevelItsPlaceAndThatTheWindowServerOwnsIt() {
        // The window server's window has no bundle ID. A window at another level is not the bar, whoever owns it.
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], owner: nil)], bars: bars) == [main])
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], layer: 0, owner: nil)], bars: bars).isEmpty)
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], layer: WindowLevels.statusBar, owner: nil)], bars: bars).isEmpty)
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], layer: WindowLevels.popUpMenu, owner: nil)], bars: bars).isEmpty)
    }

    @Test func anAppsBarSizedWindowAtMainMenuLevelIsNotTheBar() {
        // A full-screen app has hidden the main display's bar. An app has a window of its own at the main menu's level as big as the bar
        // (a menu bar of its own, an overlay): it is not what the window server draws, so the bar is not shown for it.
        let app = barWindow(1, covering: bars[0], owner: "com.example.overlay")
        #expect(BarVisibility.shownBars([app], bars: bars).isEmpty)
        #expect(!BarVisibility.shownBars([app, barWindow(2, covering: bars[1])], bars: bars).contains(main))
        // The window server's, among others of apps, is still found.
        #expect(BarVisibility.shownBars([app, barWindow(3, covering: bars[0], owner: nil)], bars: bars) == [main])
        // Not even the menu bar's own agent, which has a bundle ID, stands for the bar.
        #expect(BarVisibility.shownBars([barWindow(4, covering: bars[0], owner: "com.apple.MenuBarAgent")], bars: bars).isEmpty)
    }

    @Test func theWindowCoversTheBarWithinTwoPoints() {
        // A window as big as the bar's rectangle, or a little smaller or bigger, is the bar's.
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], grownBy: 3)], bars: bars) == [main])
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], grownBy: -2)], bars: bars) == [main], "two points short of the rectangle on each edge")
        // More than two short on an edge isn't covering it.
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0], grownBy: -2.5)], bars: bars).isEmpty)
        let narrower = WindowInfo(number: 2, ownerPID: 60, ownerBundleID: nil, layer: WindowLevels.mainMenu,
                                  bounds: CGRect(x: 100, y: 0, width: 3260, height: 30), alpha: 1)
        #expect(BarVisibility.shownBars([narrower], bars: bars).isEmpty, "a window over a part of the bar")
        // A window over a different display's bar is not this one's: the main bar's window does not cover the portrait's.
        #expect(BarVisibility.shownBars([barWindow(1, covering: bars[0])], bars: bars) == [main])
        // One window that covers the bars of two displays shows both.
        let big = WindowInfo(number: 3, ownerPID: 60, ownerBundleID: nil, layer: WindowLevels.mainMenu,
                             bounds: bars[0].rect.union(bars[1].rect), alpha: 1)
        #expect(BarVisibility.shownBars([big], bars: bars) == [main, portrait])
    }
}
