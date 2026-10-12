import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// Which icons are out of the way because of where they say they are: behind the notch, or under the front app's menus.
@Suite("Bar region", .timeLimit(.minutes(1)))
struct BarRegionTests {
    /// A 1496-wide notched display: the notch runs from x 668 to 828 (the right auxiliary area starts there).
    private let notched = MenuBarGeometry(displayUUID: "notched", rect: CGRect(x: 0, y: 0, width: 1496, height: 28),
                                          notch: CGRect(x: 668, y: 0, width: 160, height: 27.5))
    /// A display with no notch.
    private let plain = MenuBarGeometry(displayUUID: "plain", rect: CGRect(x: 1496, y: 0, width: 1728, height: 33), notch: nil)

    private func place(_ x: CGFloat, width: CGFloat = 24, y: CGFloat = 2.5) -> CGRect { CGRect(x: x, y: y, width: width, height: 24) }

    private func item(_ bundleID: String, strays: [String: CGRect] = [:], overflowedOn: Set<String> = [], isMantel: Bool = false,
                      isDot: Bool = false) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier("main")), ownerBundleID: bundleID, appName: nil, label: nil, frames: [:],
                    overflowedOn: overflowedOn, isMantel: isMantel, isDot: isDot, strayFrames: strays)
    }

    private func inventory(_ items: [MenuBarItem], bars: [MenuBarGeometry]) -> Inventory {
        Inventory(capturedAt: Fixtures.date(0), bars: bars, items: items, chevrons: [:], reach: [], problems: [])
    }

    private func marked(_ inventory: Inventory, menus: [CGRect] = [], draws: @escaping (MenuBarItem) -> Bool = { _ in true }) -> Inventory {
        BarRegion.marking(inventory, menuFrames: menus, draws: draws)
    }

    private func overflowed(_ bundleID: String, in inventory: Inventory) -> Set<String> {
        inventory.items(ofApp: bundleID).first?.overflowedOn ?? []
    }

    // MARK: The notch

    @Test func itemsLeftOfTheNotchAreOverflowed() {
        let read = inventory([
            item("com.example.a", strays: ["notched": place(484, width: 22)]),
            item("com.example.b", strays: ["notched": place(522, width: 22)]),
            item("com.example.c", strays: ["notched": place(559, width: 15)]),
            // Under the notch itself, or starting in it.
            item("com.example.d", strays: ["notched": place(700)]),
            item("com.example.e", strays: ["notched": place(800)]),
            // Right of it: in the area the bar draws status items in.
            item("com.example.f", strays: ["notched": place(830)]),
            item("com.example.g", strays: ["notched": place(878)]),
        ], bars: [notched])
        let result = marked(read)
        for id in ["a", "b", "c", "d", "e"] {
            #expect(overflowed("com.example.\(id)", in: result) == ["notched"], "\(id)")
            #expect(result.items(ofApp: "com.example.\(id)")[0].inferredOverflowOn == ["notched"], "\(id) is told by where it is")
        }
        #expect(overflowed("com.example.f", in: result).isEmpty)
        #expect(overflowed("com.example.g", in: result).isEmpty)
        #expect(OverflowInputs.overflowedApps(in: result) == ["com.example.a", "com.example.b", "com.example.c", "com.example.d", "com.example.e"])
    }

    @Test func theEdgeOfTheNotchIsWhereTheRightAreaStarts() {
        // Two points of give: an icon that starts at the edge is in the area, one that starts a point or so inside the notch is a rounding.
        #expect(BarRegion.drawnFrom(bar: notched, menuFrames: []) == 828)
        #expect(!BarRegion.isOutOfTheWay(place(828), bar: notched, menuFrames: []))
        #expect(!BarRegion.isOutOfTheWay(place(826), bar: notched, menuFrames: []))
        #expect(BarRegion.isOutOfTheWay(place(825.9), bar: notched, menuFrames: []))
    }

    // MARK: The menus

    @Test func itemsUnderTheFrontAppsMenusAreOverflowed() {
        // A display with no notch; the front app's menus run from the left edge of its bar (x 1496) to x 2096.
        let menus = [CGRect(x: 1496, y: 0, width: 30, height: 33), CGRect(x: 1526, y: 0, width: 80, height: 33),
                     CGRect(x: 1606, y: 0, width: 250, height: 33), CGRect(x: 1856, y: 0, width: 240, height: 33)]
        let read = inventory([
            item("com.example.a", strays: ["plain": place(1700)]),
            // Overlapping the last menu.
            item("com.example.b", strays: ["plain": place(2080)]),
            // Beyond them.
            item("com.example.c", strays: ["plain": place(2100)]),
            item("com.example.d", strays: ["plain": place(2400)]),
        ], bars: [plain])
        let result = marked(read, menus: menus)
        #expect(overflowed("com.example.a", in: result) == ["plain"])
        #expect(overflowed("com.example.b", in: result) == ["plain"])
        #expect(overflowed("com.example.c", in: result).isEmpty)
        #expect(overflowed("com.example.d", in: result).isEmpty)
        // With no menus read there is nothing to go by on this display.
        #expect(OverflowInputs.overflowedApps(in: marked(read)).isEmpty)
    }

    @Test func aBarWithoutMenuFramesUsesTheNotchRuleOnly() {
        // The menus are the front app's, on the display it is on. The other display shows none of them (or the menus of another app), and
        // an icon there is judged by the notch only: this one has none.
        let menusOnTheNotchedDisplay = [CGRect(x: 0, y: 0, width: 400, height: 28)]
        let read = inventory([
            item("com.example.onNotched", strays: ["notched": place(300)]),
            item("com.example.nearNotch", strays: ["notched": place(500)]),
            item("com.example.onPlain", strays: ["plain": place(1600)]),
        ], bars: [notched, plain])
        let result = marked(read, menus: menusOnTheNotchedDisplay)
        #expect(overflowed("com.example.onNotched", in: result) == ["notched"], "under the menus, and left of the notch")
        #expect(overflowed("com.example.nearNotch", in: result) == ["notched"], "right of the menus, and still left of the notch: the notch counts")
        #expect(overflowed("com.example.onPlain", in: result).isEmpty, "no menus on this bar, and no notch")
        #expect(BarRegion.drawnFrom(bar: plain, menuFrames: menusOnTheNotchedDisplay) == nil)
        #expect(BarRegion.drawnFrom(bar: notched, menuFrames: menusOnTheNotchedDisplay) == 828, "the notch is further right than the menus")
        // The menus count where they are further right than the notch.
        #expect(BarRegion.drawnFrom(bar: notched, menuFrames: [CGRect(x: 0, y: 0, width: 900, height: 28)]) == 900)
    }

    // MARK: What isn't

    @Test func concealedFramesAreNotOverflowed() {
        // A concealed icon is off every bar: the matcher gives it no stray place, and nothing here makes it one.
        let read = inventory([
            item("com.example.concealed"),
            item("com.example.plainlyOnTheBar", strays: ["notched": place(884)]),
        ], bars: [notched])
        let result = marked(read)
        #expect(overflowed("com.example.concealed", in: result).isEmpty)
        #expect(result.items(ofApp: "com.example.concealed")[0].isConcealed)
        #expect(overflowed("com.example.plainlyOnTheBar", in: result).isEmpty)
        // Only a place on the bar is a stray place (the matcher decides that, and `NotchOverflowTests` has a concealed icon's real one),
        // so an item that has none is as it was.
        #expect(result.items(ofApp: "com.example.concealed")[0] == read.items(ofApp: "com.example.concealed")[0])
    }

    @Test func anIconThePlanHidesAndASystemIconAreNeverMarked() {
        let clock = MenuBarItem(id: .system("clock"), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil, frames: [:],
                                overflowedOn: [], isMantel: false, strayFrames: ["notched": place(100)])
        let read = inventory([
            item("com.example.hiddenByThePlan", strays: ["notched": place(484)]),
            item("com.example.drawn", strays: ["notched": place(522)]),
            clock,
        ], bars: [notched])
        let result = marked(read, draws: { $0.ownerBundleID == "com.example.drawn" })
        #expect(overflowed("com.example.hiddenByThePlan", in: result).isEmpty, "concealed by the plan: its place is a stale one")
        #expect(overflowed("com.example.drawn", in: result) == ["notched"])
        #expect(result.items.first { $0.id.isSystem }?.overflowedOn.isEmpty == true)
    }

    @Test func anIconThatHasASlotOnTheBarIsDrawnThereWhateverItsFrameSays() {
        // The slot is what the bar shows: a frame that is left of the notch, for an icon that is tied to a slot on that bar, is out of date.
        let tied = MenuBarItem(id: ItemID(bundleID: "com.example.tied", key: .identifier("main")), ownerBundleID: "com.example.tied",
                               appName: nil, label: nil, frames: ["notched": CGRect(x: 900, y: 0, width: 38, height: 28)], overflowedOn: [],
                               isMantel: true, isDot: true, strayFrames: ["notched": place(484)])
        let result = marked(inventory([tied], bars: [notched]))
        #expect(result.items[0].overflowedOn.isEmpty)
        #expect(result == inventory([tied], bars: [notched]))
    }

    @Test func aBarThatIsNotShownIsNotJudged() {
        let read = inventory([item("com.example.a", strays: ["notched": place(484)]), item("com.example.b", strays: ["plain": place(1600)])],
                             bars: [notched, plain])
        #expect(overflowed("com.example.a", in: BarRegion.marking(read, menuFrames: [], shownBars: ["plain"], draws: { _ in true })).isEmpty)
        #expect(overflowed("com.example.a", in: BarRegion.marking(read, menuFrames: [], shownBars: ["notched"], draws: { _ in true })) == ["notched"])
        #expect(overflowed("com.example.a", in: BarRegion.marking(read, menuFrames: [], shownBars: [], draws: { _ in true })).isEmpty)
        #expect(overflowed("com.example.a", in: BarRegion.marking(read, menuFrames: [], shownBars: nil, draws: { _ in true })) == ["notched"], "nil is all")
    }

    @Test func aPlaceOnADisplayWithNoBarIsLeftAlone() {
        let read = inventory([item("com.example.a", strays: ["elsewhere": place(100)])], bars: [notched])
        #expect(overflowed("com.example.a", in: marked(read)).isEmpty)
    }

    @Test func whatWasFoundBySlotsIsKeptAndNotCalledInferred() {
        // An item that the bar's slots already put in the overflow of this display is not told again by its place.
        let read = inventory([item("com.example.a", strays: ["notched": place(484)], overflowedOn: ["notched"])], bars: [notched])
        let result = marked(read)
        #expect(result == read)
        #expect(result.items[0].inferredOverflowOn.isEmpty)
    }

    @Test func dotsLeftOfTheNotchAreOverflowedLikeAnyOtherIcon() {
        let read = inventory([
            item("com.example.mantel", strays: ["notched": place(598)], isMantel: true, isDot: true),
            item("com.example.mantel2", strays: ["notched": place(560)], isMantel: true, isDot: true),
        ], bars: [notched])
        let result = marked(read)
        let verdict = DotsRoom.verdict(in: result, shownBars: ["notched"])
        #expect(verdict == DotsRoom.Verdict(trapped: ["notched"], inferred: ["notched"]))
        // Apps don't count the dots: it is the dots' own business.
        #expect(OverflowInputs.overflowedApps(in: result).isEmpty)
        // One dot found by its slot and one by its place: the menu is known by a slot, so what is said isn't "behind the notch".
        let mixed = inventory([
            item("com.example.mantel", overflowedOn: ["notched"], isMantel: true, isDot: true),
            item("com.example.mantel2", strays: ["notched": place(560)], isMantel: true, isDot: true),
        ], bars: [notched])
        #expect(DotsRoom.verdict(in: marked(mixed), shownBars: ["notched"]) == DotsRoom.Verdict(trapped: ["notched"]))
    }

    @Test func theLogSaysWhenItIsOnlyWhereTheDotsSayTheyAre() {
        #expect(DotsRoomLog.moved("com.example.a", kind: .builtIn, inferred: true)
            == "Mantel's dots were behind the notch or the menus on the built-in display; moved com.example.a to Hidden to make room")
        #expect(DotsRoomLog.moved("com.example.a", kind: .other, inferred: true)
            == "Mantel's dots were behind the notch or the menus on another display; moved com.example.a to Hidden to make room")
        // As before when it isn't.
        #expect(DotsRoomLog.moved("com.example.a", kind: .builtIn)
            == "Mantel's dots were in the « menu on the built-in display; moved com.example.a to Hidden to make room")

        // On a display with no notch there is none to be behind.
        #expect(DotsRoomLog.moved("com.example.a", kind: .other, inferred: true, notch: false)
            == "Mantel's dots were under the menus on another display; moved com.example.a to Hidden to make room")
        #expect(DotsRoomLog.nothingLeftToMove(kind: .other, inferred: true, notch: false)
            == "Mantel's dots are under the menus on another display, and no Shown app is left to move to Hidden to make room")
        #expect(DotsRoomLog.automaticOverflowIsOff(kind: .other, inferred: true, notch: false)
            == "Mantel's dots are under the menus on another display; \"Move icons that don't fit to Hidden\" is off, so no app was moved")
        var plainLog = DotsRoomLog()
        var plainOutcome = AutoOverflowTracker.Outcome()
        plainOutcome.movedForDots = [.init(bundleID: "com.example.a", displayUUID: "plain", isInferred: true)]
        #expect(plainLog.lines(verdict: DotsRoom.Verdict(trapped: ["plain"], inferred: ["plain"]), outcome: plainOutcome, automaticOverflowIsOn: true,
                               kind: { _ in .other }, hasNotch: { $0 == "notched" })
            == ["Mantel's dots were under the menus on another display; moved com.example.a to Hidden to make room"])

        var log = DotsRoomLog()
        var outcome = AutoOverflowTracker.Outcome()
        outcome.movedForDots = [.init(bundleID: "com.example.a", displayUUID: "x", isInferred: true)]
        outcome.noRoomToMakeFor = ["x"]
        let lines = log.lines(verdict: DotsRoom.Verdict(trapped: ["x"], inferred: ["x"]), outcome: outcome, automaticOverflowIsOn: true,
                              kind: { _ in .builtIn })
        #expect(lines == [
            "Mantel's dots were behind the notch or the menus on the built-in display; moved com.example.a to Hidden to make room",
            "Mantel's dots are behind the notch or the menus on the built-in display, and no Shown app is left to move to Hidden to make room",
        ])
        let off = log.lines(verdict: DotsRoom.Verdict(trapped: ["y"], inferred: ["y"]), outcome: nil, automaticOverflowIsOn: false,
                            kind: { _ in .other })
        #expect(off == ["Mantel's dots are behind the notch or the menus on another display; \"Move icons that don't fit to Hidden\" is off, so no app was moved"])
    }
}
