import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKLayout

/// Where Mantel's menu opens for a right click on a dot, on any display.
@Suite("Dot menu placement", .timeLimit(.minutes(1)))
struct DotMenuPlacementTests {
    private let displays = DisplayLayout.deskWithLaptopOpen
    private let desk = DisplayFixtures.deskMain
    private let side = DisplayFixtures.deskPortrait
    private let laptop = DisplayFixtures.laptopRightOfDesk

    /// The desk display's bar is 30 high at the top of the main display; the laptop's is 33, at CoreGraphics y = 773 (the main display is
    /// 1890 high and the laptop 1117, so its top is 773 down from the main display's top).
    private var deskBar: MenuBarGeometry { MenuBarGeometry(displayUUID: desk.uuid, rect: CGRect(x: 0, y: 0, width: 3360, height: 30), notch: nil) }
    private var laptopBar: MenuBarGeometry {
        MenuBarGeometry(displayUUID: laptop.uuid, rect: CGRect(x: 3360, y: 773, width: 1728, height: 33), notch: nil)
    }

    private func dot(_ kind: OwnItemKind, frames: [String: CGRect], overflowedOn: Set<String> = []) -> MenuBarItem {
        let name = kind == .alwaysDot ? "mantel.dot.always" : "mantel.dot.hidden"
        return MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier(name)), ownerBundleID: "com.example.mantel", appName: nil,
                           label: nil, frames: frames, overflowedOn: overflowedOn, isMantel: true, ownKind: kind)
    }

    /// A read with both dots on the desk display and on the laptop's bar, and the bars of both.
    private func inventory(laptopOverflowed: Set<String> = [], bars: [MenuBarGeometry]? = nil) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 100), bars: bars ?? [deskBar, laptopBar], items: [
            dot(.hiddenDot, frames: [desk.uuid: CGRect(x: 3000, y: 0, width: 30, height: 30),
                                     laptop.uuid: CGRect(x: 4800, y: 773, width: 30, height: 33)], overflowedOn: laptopOverflowed),
            dot(.alwaysDot, frames: [desk.uuid: CGRect(x: 3030, y: 0, width: 30, height: 30),
                                     laptop.uuid: CGRect(x: 4830, y: 773, width: 30, height: 33)]),
        ], chevrons: [:], reach: [], problems: [])
    }

    /// Where the dot's button is: on the desk display, under the slot macOS draws there (AppKit points).
    private let buttonOnDesk = CGRect(x: 3000, y: 1860, width: 30, height: 30)

    private func decide(_ kind: DotKind = .hidden, pointer: CGPoint, button: CGRect? = nil, inventory: Inventory?,
                        displaysChangedAt: Date? = nil) -> DotMenuPlacement.Decision {
        DotMenuPlacement.decide(dot: kind, pointer: pointer, buttonFrame: button ?? buttonOnDesk, displays: displays, inventory: inventory,
                                displaysChangedAt: displaysChangedAt)
    }

    @Test func aClickOnTheDisplayTheButtonIsOnIsLeftToTheStatusItem() {
        #expect(decide(pointer: CGPoint(x: 3010, y: 1880), inventory: inventory()) == .statusItem)
    }

    @Test func aClickOnAnotherDisplayOpensUnderTheDotsSlotThereAndBelowTheBar() {
        // On the laptop's bar: the pointer is near the top of its frame.
        let pointer = CGPoint(x: 4810, y: 1105)
        // Left edge of the slot (x = 4800); the bar's bottom is at CoreGraphics y = 806, which is 1890 - 806 = 1084 in AppKit, and the display's
        // visible frame begins a point lower, at 1083.
        #expect(decide(pointer: pointer, inventory: inventory()) == .popUp(at: CGPoint(x: 4800, y: 1083), under: .slot))
        // •• has a slot of its own, beside •.
        #expect(decide(.always, pointer: CGPoint(x: 4840, y: 1105), inventory: inventory()) == .popUp(at: CGPoint(x: 4830, y: 1083), under: .slot))
    }

    @Test func theSlotIsTheOneOfTheDisplayThatWasClickedNotTheButtons() {
        // The same read gives the dot a slot on the desk display too; the click was on the laptop's bar, so x = 4800 and not 3000.
        guard case .popUp(let point, _) = decide(pointer: CGPoint(x: 4820, y: 1100), inventory: inventory()) else {
            Issue.record("expected a pop-up"); return
        }
        #expect(point.x == 4800)
    }

    @Test func withNoSlotThereTheMenuOpensUnderTheBarAtTheClick() {
        let pointer = CGPoint(x: 4900, y: 1100)
        let expected = DotMenuPlacement.Decision.popUp(at: CGPoint(x: 4900, y: 1083), under: .click)
        // The dot is behind the notch or in « on that bar.
        #expect(decide(pointer: pointer, inventory: inventory(laptopOverflowed: [laptop.uuid])) == expected)
        // The read has nothing of the dots on that display.
        let onlyDesk = Inventory(capturedAt: Date(timeIntervalSince1970: 100), bars: [deskBar, laptopBar], items: [
            dot(.hiddenDot, frames: [desk.uuid: CGRect(x: 3000, y: 0, width: 30, height: 30)]),
        ], chevrons: [:], reach: [], problems: [])
        #expect(decide(pointer: pointer, inventory: onlyDesk) == expected)
        // The read is older than the last change of displays: its bar isn't gone by either, so the bar is the display's own top and its
        // own height (34 here, from its visible frame), which is 1083 in AppKit.
        #expect(decide(pointer: pointer, inventory: inventory(), displaysChangedAt: Date(timeIntervalSince1970: 200))
                == .popUp(at: CGPoint(x: 4900, y: 1083), under: .click))
    }

    @Test func withNoReadTheBarIsTheTopOfTheDisplayAndTheHeightItsOwnFrameSays() {
        // The laptop's frame is 34 above its visible frame (the notch is 32): 1117 - 34 = 1083 in AppKit, not 24 below the top.
        #expect(decide(pointer: CGPoint(x: 4900, y: 1105), inventory: nil) == .popUp(at: CGPoint(x: 4900, y: 1083), under: .click))
        // The portrait display reports no bar in its visible frame: the height AppKit says the bar is (24 here) stands in. Its top is 2381.
        #expect(decide(pointer: CGPoint(x: -290, y: 2370), inventory: nil) == .popUp(at: CGPoint(x: -290, y: 2357), under: .click))
    }

    @Test func aBarThatIsOnTheDisplayLeftOfTheOriginIsFoundToo() {
        // The portrait display is left of the main one, higher: its top is at CoreGraphics y = -491, and its bar, 30 high, ends at -461.
        let sideBar = MenuBarGeometry(displayUUID: side.uuid, rect: CGRect(x: -1800, y: -491, width: 1800, height: 30), notch: nil)
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 100), bars: [deskBar, sideBar], items: [
            dot(.hiddenDot, frames: [side.uuid: CGRect(x: -300, y: -491, width: 30, height: 30)]),
        ], chevrons: [:], reach: [], problems: [])
        // In AppKit the bar's bottom is 1890 - (-461) = 2351.
        #expect(decide(pointer: CGPoint(x: -290, y: 2370), inventory: read) == .popUp(at: CGPoint(x: -300, y: 2351), under: .slot))
    }

    @Test func aButtonWithNoWindowOrOnNoDisplayLeavesTheMenuToTheClickedDisplay() {
        let pointer = CGPoint(x: 4810, y: 1105)
        let expected = DotMenuPlacement.Decision.popUp(at: CGPoint(x: 4800, y: 1083), under: .slot)
        let missing = DotMenuPlacement.decide(dot: .hidden, pointer: pointer, buttonFrame: nil, displays: displays, inventory: inventory())
        #expect(missing == expected)
        let stale = DotMenuPlacement.decide(dot: .hidden, pointer: pointer, buttonFrame: CGRect(x: 90000, y: 90000, width: 30, height: 30),
                                            displays: displays, inventory: inventory())
        #expect(stale == expected)
    }

    @Test func aPointerOnNoDisplayIsLeftToTheStatusItem() {
        #expect(decide(pointer: CGPoint(x: 50000, y: 50000), inventory: inventory()) == .statusItem)
    }

    // MARK: The owner's three displays, as recorded in sitting 1

    /// The Samsung (3840×2160 at 1×, main, a 30-pt bar), the laptop **below** it at (471, -1329) (2056×1329, a 220×38 notch, a 39-pt bar)
    /// and the LG (1800×3200 portrait to the left, a 30-pt bar). The visible frames are the recorded ones (each a point lower than the bar,
    /// and the laptop's Dock at its bottom), so a display's own height is 31, 40 and 31. The UUIDs are made up.
    private enum Owner {
        static let samsung = DisplayInfo(uuid: "11111111-AAAA-4AAA-8AAA-000000000001", name: "Wide Display",
                                         frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 3840, height: 2129), scale: 1, notch: nil,
                                         isBuiltIn: false, isMain: true)
        static let laptop = DisplayInfo(uuid: "22222222-BBBB-4BBB-8BBB-000000000002", name: "Built-in Display",
                                        frame: CGRect(x: 471, y: -1329, width: 2056, height: 1329),
                                        visibleFrame: CGRect(x: 471, y: -1273, width: 2056, height: 1233), scale: 2,
                                        notch: CGRect(x: 1389, y: -38, width: 220, height: 38), isBuiltIn: true, isMain: false)
        static let lg = DisplayInfo(uuid: "33333333-CCCC-4CCC-8CCC-000000000003", name: "Tall Display",
                                    frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
                                    visibleFrame: CGRect(x: -1800, y: -819, width: 1800, height: 3169), scale: 2, notch: nil,
                                    isBuiltIn: false, isMain: false)
        static let layout = DisplayLayout(displays: [samsung, laptop, lg])
        /// The dot's button, on the Samsung (AppKit points).
        static let button = CGRect(x: 3052, y: 2130, width: 38, height: 30)
        static let laptopBar = MenuBarGeometry(displayUUID: laptop.uuid, rect: CGRect(x: 471, y: 2160, width: 2056, height: 39), notch: nil)
        static let lgBar = MenuBarGeometry(displayUUID: lg.uuid, rect: CGRect(x: -1800, y: -221, width: 1800, height: 30), notch: nil)
        static let samsungBar = MenuBarGeometry(displayUUID: samsung.uuid, rect: CGRect(x: 0, y: 0, width: 3840, height: 30), notch: nil)
    }

    private func ownerDot(_ kind: OwnItemKind, laptopX: CGFloat, lgX: CGFloat) -> MenuBarItem {
        dot(kind, frames: [Owner.laptop.uuid: CGRect(x: laptopX, y: 2160, width: 38, height: 39),
                           Owner.lg.uuid: CGRect(x: lgX, y: -221, width: 38, height: 30),
                           Owner.samsung.uuid: CGRect(x: kind == .alwaysDot ? 3052 : 3014, y: 0, width: 38, height: 30)])
    }

    private func ownerRead(bars: [MenuBarGeometry]? = nil, at: TimeInterval = 100) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: at), bars: bars ?? [Owner.samsungBar, Owner.laptopBar, Owner.lgBar], items: [
            ownerDot(.hiddenDot, laptopX: 1701.5, lgX: -825.5), ownerDot(.alwaysDot, laptopX: 1739.5, lgX: -787.5),
        ], chevrons: [:], reach: [], problems: [])
    }

    private func decideOnOwner(_ kind: DotKind = .always, pointer: CGPoint, inventory: Inventory?, displaysChangedAt: Date? = nil,
                               barHeight: CGFloat = 24) -> DotMenuPlacement.Decision {
        DotMenuPlacement.decide(dot: kind, pointer: pointer, buttonFrame: Owner.button, displays: Owner.layout, inventory: inventory,
                                displaysChangedAt: displaysChangedAt, barHeight: barHeight)
    }

    @Test func aRightClickOnTheLaptopsDotOpensUnderItAtItsBarOnTheDisplayBelowTheMainOne() {
        // The laptop's bar ends at CoreGraphics 2160 + 39 = 2199, which is 2160 - 2199 = -39 in AppKit: on the laptop, whose top is 0. Its visible
        // frame begins at -40, and the menu opens there.
        #expect(decideOnOwner(pointer: CGPoint(x: 1755, y: -20), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1739.5, y: -40), under: .slot))
        #expect(decideOnOwner(.hidden, pointer: CGPoint(x: 1720, y: -20), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1701.5, y: -40), under: .slot))
        // The pointer pushed against the top of the laptop's bar reads y = 0, the Samsung's bottom edge too: it is the laptop's.
        #expect(decideOnOwner(pointer: CGPoint(x: 1755, y: 0), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1739.5, y: -40), under: .slot))
    }

    @Test func aRightClickOnTheLGsDotOpensUnderItAtItsBar() {
        // The LG's bar ends at CoreGraphics -221 + 30 = -191, which is 2160 + 191 = 2351 in AppKit (its top is 2381); its visible frame begins
        // at 2350.
        #expect(decideOnOwner(pointer: CGPoint(x: -770, y: 2365), inventory: ownerRead()) == .popUp(at: CGPoint(x: -787.5, y: 2350), under: .slot))
        #expect(decideOnOwner(.hidden, pointer: CGPoint(x: -810, y: 2365), inventory: ownerRead()) == .popUp(at: CGPoint(x: -825.5, y: 2350), under: .slot))
    }

    @Test func aRightClickOnTheDisplayTheButtonIsOnStaysWithTheStatusItem() {
        #expect(decideOnOwner(pointer: CGPoint(x: 3060, y: 2145), inventory: ownerRead()) == .statusItem)
    }

    @Test func withNoBarInTheReadEachDisplayGoesByItsOwnBarHeight() {
        let noBars = ownerRead(bars: [])
        // 40 on the laptop (its frame is 40 above its visible frame; the notch is 38), 31 on the LG: y = 0 - 40 and 2381 - 31.
        #expect(decideOnOwner(pointer: CGPoint(x: 1755, y: -20), inventory: noBars) == .popUp(at: CGPoint(x: 1739.5, y: -40), under: .slot))
        #expect(decideOnOwner(pointer: CGPoint(x: -770, y: 2365), inventory: noBars) == .popUp(at: CGPoint(x: -787.5, y: 2350), under: .slot))
        #expect(decideOnOwner(pointer: CGPoint(x: 1755, y: -20), inventory: nil) == .popUp(at: CGPoint(x: 1755, y: -40), under: .click))
        // A laptop whose bar hides itself: nothing between its frame and its visible frame, and the notch (38) is deeper than the height
        // AppKit gives (24), so the menu opens below the notch.
        let laptopHiding = DisplayInfo(uuid: Owner.laptop.uuid, name: Owner.laptop.name, frame: Owner.laptop.frame,
                                       visibleFrame: Owner.laptop.frame, scale: 2, notch: Owner.laptop.notch, isBuiltIn: true, isMain: false)
        let laptopHidden = DotMenuPlacement.decide(dot: .always, pointer: CGPoint(x: 1755, y: -20), buttonFrame: Owner.button,
                                                   displays: DisplayLayout(displays: [Owner.samsung, laptopHiding, Owner.lg]),
                                                   inventory: nil, barHeight: 24)
        #expect(laptopHidden == .popUp(at: CGPoint(x: 1755, y: -38), under: .click))
        // A bar that hides itself leaves nothing between a frame and its visible frame: the height AppKit says the bar is stands in.
        let hiding = DisplayInfo(uuid: Owner.lg.uuid, name: Owner.lg.name, frame: Owner.lg.frame, visibleFrame: Owner.lg.frame, scale: 2,
                                 notch: nil, isBuiltIn: false, isMain: false)
        let layout = DisplayLayout(displays: [Owner.samsung, Owner.laptop, hiding])
        let hidden = DotMenuPlacement.decide(dot: .always, pointer: CGPoint(x: -770, y: 2365), buttonFrame: Owner.button, displays: layout,
                                             inventory: nil, barHeight: 28)
        #expect(hidden == .popUp(at: CGPoint(x: -770, y: 2353), under: .click))
    }

    @Test func aBarFromBeforeTheDisplaysMovedIsNotTheBarOfTheDisplayClicked() {
        // Docking: the laptop was alone and the main display, its bar at CoreGraphics (0, 0, 2056, 39). Went by as it was, the bar's bottom
        // is 2160 - 39 = 2121 in AppKit, which is on the Samsung, 9 points below its bar.
        let before = MenuBarGeometry(displayUUID: Owner.laptop.uuid, rect: CGRect(x: 0, y: 0, width: 2056, height: 39), notch: nil)
        let stale = ownerRead(bars: [Owner.samsungBar, before, Owner.lgBar], at: 100)
        let pointer = CGPoint(x: 1755, y: -20)
        // The read is older than the change: no slot, and the display's own top and height.
        #expect(decideOnOwner(pointer: pointer, inventory: stale, displaysChangedAt: Date(timeIntervalSince1970: 200))
                == .popUp(at: CGPoint(x: 1755, y: -40), under: .click))
        // A read taken after the change that caught the bar before it had moved (the dot's slot had): the bar isn't at the top of that
        // display, so the display's own top and height, under the slot.
        #expect(decideOnOwner(pointer: pointer, inventory: stale, displaysChangedAt: Date(timeIntervalSince1970: 50))
                == .popUp(at: CGPoint(x: 1739.5, y: -40), under: .slot))
        // A slot that isn't at the top of the clicked display (a read of the laptop's dot from before the move) isn't used either.
        let staleSlot = Inventory(capturedAt: Date(timeIntervalSince1970: 100), bars: [Owner.samsungBar, Owner.laptopBar, Owner.lgBar], items: [
            dot(.alwaysDot, frames: [Owner.laptop.uuid: CGRect(x: 1739.5, y: 0, width: 38, height: 39)]),
        ], chevrons: [:], reach: [], problems: [])
        #expect(decideOnOwner(pointer: pointer, inventory: staleSlot) == .popUp(at: CGPoint(x: 1755, y: -40), under: .click))
    }

    @Test func aPointerOutsideTheSlotMeansTheDotHasMovedAndTheMenuOpensAtTheClick() {
        // The slot is (1739.5, 38 wide); the pointer is 60 points left of it, as after a reveal that moved the dot along the bar.
        #expect(decideOnOwner(pointer: CGPoint(x: 1679, y: -20), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1679, y: -40), under: .click))
        // A few points' slack at either edge, for a pointer on the dot's edge.
        #expect(decideOnOwner(pointer: CGPoint(x: 1737, y: -20), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1739.5, y: -40), under: .slot))
        #expect(decideOnOwner(pointer: CGPoint(x: 1780, y: -20), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1739.5, y: -40), under: .slot))
        // Past the slack on the right (the slot ends at 1777.5, the slack at 1781.5): the dot has moved.
        #expect(decideOnOwner(pointer: CGPoint(x: 1782, y: -20), inventory: ownerRead()) == .popUp(at: CGPoint(x: 1782, y: -40), under: .click))
    }

    // MARK: Whole under the dot, on every display

    /// The bar's own window ends a point above where AppKit's visible frame begins on every display the owner has (39 against 40 on the
    /// laptop, 30 against 31 on the others), so a menu opened at the bar's bottom has its top a point above the area AppKit lays menus out
    /// in. On the laptop that is the menu that opened with a scroll arrow and its first items hidden: it must open no higher than the
    /// visible frame's top, whichever display and whatever the read says of the bar.
    @Test(arguments: [
        (display: "laptop", dot: DotKind.always, pointer: CGPoint(x: 1755, y: -20), top: -40.0),
        (display: "laptop", dot: DotKind.hidden, pointer: CGPoint(x: 1720, y: -20), top: -40.0),
        (display: "lg", dot: DotKind.always, pointer: CGPoint(x: -770, y: 2365), top: 2350.0),
        (display: "lg", dot: DotKind.hidden, pointer: CGPoint(x: -810, y: 2365), top: 2350.0),
    ])
    func aMenuOpensNoHigherThanTheVisibleFrameOfTheDisplayClicked(display: String, dot: DotKind, pointer: CGPoint, top: Double) throws {
        let shown = display == "laptop" ? Owner.laptop : Owner.lg
        for read in [ownerRead(), ownerRead(bars: []), nil] {
            guard case .popUp(let point, _) = decideOnOwner(dot, pointer: pointer, inventory: read) else {
                Issue.record("expected a pop-up on the \(display)"); return
            }
            #expect(Double(point.y) == top, "the \(display): the menu's top is the visible frame's, \(shown.visibleFrame.maxY)")
            #expect(point.y <= shown.visibleFrame.maxY)
            #expect(shown.frame.contains(CGPoint(x: point.x, y: point.y - 1)), "and it is on that display")
        }
    }

    @Test func theLogSaysWhereTheMenuWasPoppedUpUnderWhatAndOnWhichDisplay() {
        #expect(DotMenuPlacement.popUpLogLine(at: CGPoint(x: 1739.5, y: -40), under: .slot, displays: Owner.layout)
                == "the menu is popped up at (1739.5, -40.0) under the dot's slot on 22222222, whose visible frame's top is -40.0")
        #expect(DotMenuPlacement.popUpLogLine(at: CGPoint(x: -790, y: 2350), under: .click, displays: Owner.layout)
                == "the menu is popped up at (-790.0, 2350.0) under the click on 33333333, whose visible frame's top is 2350.0")
        #expect(DotMenuPlacement.popUpLogLine(at: CGPoint(x: 9000, y: 0), under: .click, displays: Owner.layout)
                == "the menu is popped up at (9000.0, 0.0) under the click on no display")
    }

    @Test func theSamsungsMenuIsNoHigherEitherWhenTheButtonIsOnAnotherDisplay() {
        // The dot's button is on the laptop (its display is the active one): a click on the Samsung's bar pops the menu up there.
        let button = CGRect(x: 1700, y: -39, width: 38, height: 39)
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 100), bars: [Owner.samsungBar, Owner.laptopBar, Owner.lgBar], items: [
            ownerDot(.alwaysDot, laptopX: 1739.5, lgX: -787.5),
        ], chevrons: [:], reach: [], problems: [])
        let decision = DotMenuPlacement.decide(dot: .always, pointer: CGPoint(x: 3060, y: 2145), buttonFrame: button, displays: Owner.layout,
                                               inventory: read)
        #expect(decision == .popUp(at: CGPoint(x: 3052, y: 2129), under: .slot), "the visible frame's top is 2129, the bar's bottom 2130")
    }

    @Test func aBarThatHidesItselfLeavesTheMenuWhereItWasPlaced() {
        // The visible frame reaches the frame's top while the bar hides: it says nothing then, and the menu isn't pulled up to it.
        let hiding = DisplayInfo(uuid: Owner.lg.uuid, name: Owner.lg.name, frame: Owner.lg.frame, visibleFrame: Owner.lg.frame, scale: 2,
                                 notch: nil, isBuiltIn: false, isMain: false)
        let layout = DisplayLayout(displays: [Owner.samsung, Owner.laptop, hiding])
        let decision = DotMenuPlacement.decide(dot: .always, pointer: CGPoint(x: -770, y: 2365), buttonFrame: Owner.button, displays: layout,
                                               inventory: ownerRead())
        #expect(decision == .popUp(at: CGPoint(x: -787.5, y: 2351), under: .slot), "the bar's own bottom, lower than the frame's top")
    }
}
