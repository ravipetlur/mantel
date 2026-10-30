import CoreGraphics
import Foundation
import Testing

@testable import MKMenuBar

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

private func poll(_ watch: inout ClickMenuWatch, menuOfApp: Bool = false, anyMenuOpen: Bool = false, pointerInBar: Bool = false,
                  at seconds: Double) -> ClickMenuWatch.Phase {
    watch.handle(.poll(menuOfApp: menuOfApp, anyMenuOpen: anyMenuOpen, pointerInBar: pointerInBar, at: at(seconds)))
}

/// Where a click's menu is in its life, from what the window list says.
@Suite("Click menu watch")
struct ClickMenuWatchTests {
    @Test func opensThenCloses() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        #expect(poll(&watch, at: 0) == .waitingForMenu)
        #expect(poll(&watch, menuOfApp: true, anyMenuOpen: true, at: 0.2) == .menuOpen)
        #expect(poll(&watch, menuOfApp: true, anyMenuOpen: true, at: 0.4) == .menuOpen)
        #expect(poll(&watch, at: 3) == .menuClosed(at: at(3)))
        // Once closed it stays so.
        #expect(poll(&watch, menuOfApp: true, anyMenuOpen: true, at: 3.2) == .menuClosed(at: at(3)))
    }

    @Test func neverOpensTimesOut() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        #expect(poll(&watch, at: 0.2) == .waitingForMenu)
        #expect(poll(&watch, at: 1.4) == .waitingForMenu)
        #expect(watch.handle(.timeout(at: at(1.5))) == .menuClosed(at: at(1.5)))
    }

    @Test func closesOnFirstPollSeenClosed() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        _ = poll(&watch, menuOfApp: true, anyMenuOpen: true, at: 0.1)
        // A timeout after it opened changes nothing: the menu's life is not the wait for it.
        #expect(watch.handle(.timeout(at: at(1.5))) == .menuOpen)
        #expect(poll(&watch, at: 2) == .menuClosed(at: at(2)), "the first poll that sees none")
    }

    @Test func anyOpenMenuHolds() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        _ = poll(&watch, menuOfApp: true, anyMenuOpen: true, at: 0.1)
        // The app's own menu is gone but another is open (the person went to another icon's): the icon stays.
        #expect(poll(&watch, menuOfApp: false, anyMenuOpen: true, at: 0.5) == .menuOpen)
        #expect(poll(&watch, menuOfApp: false, anyMenuOpen: true, at: 5) == .menuOpen)
        #expect(poll(&watch, at: 5.2) == .menuClosed(at: at(5.2)))

        // A menu that a helper process draws is not the app's by its owner, but it is open at the timeout: it is taken for the icon's.
        var helper = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        _ = poll(&helper, menuOfApp: false, anyMenuOpen: true, at: 1.4)
        #expect(helper.handle(.timeout(at: at(1.5))) == .menuOpen)
        #expect(poll(&helper, at: 4) == .menuClosed(at: at(4)))
    }

    @Test func pointerInBarHolds() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        _ = poll(&watch, menuOfApp: true, anyMenuOpen: true, at: 0.1)
        #expect(poll(&watch, pointerInBar: true, at: 0.5) == .menuOpen, "the pointer is on the bar: the icons stay under it")
        #expect(poll(&watch, pointerInBar: false, at: 0.7) == .menuClosed(at: at(0.7)))

        // The same while no menu has come: the wait doesn't end with the pointer in the bar.
        var waiting = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        _ = poll(&waiting, pointerInBar: true, at: 1.4)
        #expect(waiting.handle(.timeout(at: at(1.5))) == .menuOpen)
    }

    @Test func menusNotSeenEndOnMouseDownOutside() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: false)
        #expect(watch.phase == .menuOpen, "a menu that isn't seen is taken to be open")
        // What the window list says is of no use.
        #expect(poll(&watch, at: 0.2) == .menuOpen)
        #expect(poll(&watch, at: 2) == .menuOpen)
        #expect(watch.handle(.mouseDownOutsideIcon(at: at(7))) == .menuClosed(at: at(7)))

        // The cap the caller sends ends it too.
        var capped = ClickMenuWatch(startedAt: start, menusAreSeen: false)
        #expect(capped.handle(.timeout(at: at(600))) == .menuClosed(at: at(600)))
    }

    @Test func aClickElsewhereEndsTheWaitForAMenuThatHasNotOpened() {
        var watch = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        #expect(watch.handle(.mouseDownOutsideIcon(at: at(0.3))) == .menuClosed(at: at(0.3)))
        // Once it has opened, the window list says when it closes: a mouse-down in the menu is no end.
        var open = ClickMenuWatch(startedAt: start, menusAreSeen: true)
        _ = poll(&open, menuOfApp: true, anyMenuOpen: true, at: 0.1)
        #expect(open.handle(.mouseDownOutsideIcon(at: at(0.3))) == .menuOpen)
    }

    @Test func aMenuIsNearItsItemWhenItIsAtMostTwelvePointsBelowTheBar() {
        // macOS 27 opens a menu 10 points below the bar, with its left within 5 points of the slot's.
        let slot = CGRect(x: 3000, y: 0, width: 36, height: 30)
        func menu(x: CGFloat, y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 220, height: 300) }
        #expect(ClickMenuRules.isNearItem(menu(x: 3002, y: 40), slot: slot), "10 below, 2 right of the slot's left edge")
        #expect(ClickMenuRules.isNearItem(menu(x: 2995, y: 42), slot: slot), "12 below, 5 left")
        #expect(!ClickMenuRules.isNearItem(menu(x: 3002, y: 43), slot: slot), "13 below")
        #expect(!ClickMenuRules.isNearItem(menu(x: 3006, y: 40), slot: slot), "6 right")
        #expect(!ClickMenuRules.isNearItem(menu(x: 3002, y: 20), slot: slot), "a window that overlaps the bar is no menu")
    }
}
