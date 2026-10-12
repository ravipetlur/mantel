import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Bar expectation", .timeLimit(.minutes(1)))
struct BarExpectationTests {
    private let own = "com.example.mantel"
    private let weather = "com.example.weather"
    private let notes = "com.example.notes"
    private let vpn = "com.example.vpn"
    private let frame = CGRect(x: 100, y: 0, width: 30, height: 30)
    private let elsewhere = "display-other"

    private func plan(visible: Set<String>, concealedSystem: Set<Int> = []) -> VisibilityPlan {
        VisibilityPlan(visibleBundleIDs: visible.union([own]), concealedBundleIDs: [],
                       visibleSystemItems: Set(VisibilityPlan.allSystemItems).subtracting(concealedSystem), concealedSections: [],
                       source: .sections)
    }

    /// An item of the app on the main display: drawn, concealed, or piled in the overflow.
    private func item(_ bundleID: String, _ name: String = "main", framed: Bool = true, overflowed: Bool = false) -> MenuBarItem {
        Fixtures.item(Fixtures.itemID(bundleID, name), frame: framed ? frame : nil, overflowed: overflowed, isMantel: bundleID == own)
    }

    private func system(_ module: String, framed: Bool = true) -> MenuBarItem {
        Fixtures.item(.system(module), frame: framed ? frame : nil)
    }

    private func count(_ plan: VisibilityPlan, _ inventory: Inventory, turnedOff: Set<String> = [],
                       _ expectation: BarExpectation = BarExpectation()) -> Int {
        expectation.slotCount(drawnBy: plan, in: inventory, on: Fixtures.display, turnedOff: turnedOff)
    }

    // MARK: What the plan draws

    @Test func theItemsOfTheAppsThatStayAreCountedConcealedOnesToo() {
        // The weather app's two icons are concealed now, and the plan shows them: there should be slots for them.
        let inventory = Fixtures.inventory([item(weather, "a", framed: false), item(weather, "b", framed: false), item(notes), item(vpn),
                                            item(own)])
        #expect(count(plan(visible: [weather, notes, vpn]), inventory) == 5)
        // The plan that conceals the VPN app and the weather app leaves the notes app's icon and Mantel's.
        #expect(count(plan(visible: [notes]), inventory) == 2)
    }

    @Test func systemItemsAreCountedByTheNumbersThePlanKeeps() {
        let inventory = Fixtures.inventory([system("clock"), system("battery"), system("wifi")])
        #expect(count(plan(visible: []), inventory) == 3)
        // Battery is number 0 and Wi-Fi number 6: the plan that takes them off the bar leaves the clock.
        #expect(count(plan(visible: [], concealedSystem: [0, 6]), inventory) == 1)
    }

    @Test func aSystemItemWithNoNumberIsCountedItStaysWhateverIsConcealed() {
        let inventory = Fixtures.inventory([system("airdrop"), system("audiovideo")])
        #expect(count(plan(visible: [], concealedSystem: Set(0...255)), inventory) == 2)
    }

    @Test func anAppThatIsNotInThePlanIsNotCounted() {
        // The plan's apps are the ones that are running: an icon left from an app that has quit isn't one the bar draws.
        let inventory = Fixtures.inventory([item(weather), item(notes)])
        #expect(count(plan(visible: [notes]), inventory) == 1)
    }

    // MARK: What is left out

    @Test func anIconPiledInTheOverflowOfTheBarIsNotCounted() {
        let inventory = Fixtures.inventory([item(weather, "a", overflowed: true), item(weather, "b"), item(notes)])
        #expect(count(plan(visible: [weather, notes]), inventory) == 2)
    }

    @Test func anIconThatIsOnlyOnAnotherDisplayIsNotOnThisBar() {
        let other = MenuBarItem(id: Fixtures.itemID(vpn), ownerBundleID: vpn, appName: nil, label: nil, frames: [elsewhere: frame],
                                overflowedOn: [], isMantel: false)
        let inventory = Fixtures.inventory([item(notes), other])
        #expect(count(plan(visible: [notes, vpn]), inventory) == 1)
        #expect(BarExpectation().slotCount(drawnBy: plan(visible: [notes, vpn]), in: inventory, on: elsewhere, turnedOff: []) == 1)
    }

    @Test func theAppsTurnedOffInSystemSettingsAreNotCounted() {
        let inventory = Fixtures.inventory([item(weather, "a", framed: false), item(weather, "b", framed: false), item(notes)])
        #expect(count(plan(visible: [weather, notes]), inventory, turnedOff: [weather]) == 1)
        #expect(count(plan(visible: [weather, notes]), inventory, turnedOff: ["com.example.other"]) == 3)
    }

    @Test func theSlotsNothingClaimedAreCounted() {
        let inventory = Fixtures.inventory([item(notes)], untiedSlots: [Fixtures.display: [frame, frame], elsewhere: [frame]])
        #expect(count(plan(visible: [notes]), inventory) == 3)
        // Not those of another display's bar, and none for a bar that has none.
        #expect(BarExpectation().slotCount(drawnBy: plan(visible: [notes]), in: inventory, on: "nowhere", turnedOff: []) == 0)
    }

    // MARK: A frame that is not on the bar

    /// The main display's bar, and a frame macOS reports for an icon it isn't drawing: far below the bar.
    private var bar: MenuBarGeometry { MenuBarGeometry(displayUUID: Fixtures.display, rect: CGRect(x: 0, y: 0, width: 3000, height: 30), notch: nil) }
    private let parked = CGRect(x: 7, y: 1878, width: 24, height: 24)

    private func parkedItem(_ module: String) -> MenuBarItem {
        Fixtures.item(.system(module), frame: parked)
    }

    @Test func anIconParkedOffTheBarIsLearnedAsNotDrawnAfterOneRead() {
        // AirDrop has no number, so the plan always draws it, and macOS parks its slot off the bar under any allowlist.
        let read = Fixtures.inventory([parkedItem("airdrop"), item(notes)], bars: [bar])
        let shown = plan(visible: [notes])
        var expectation = BarExpectation()
        #expect(count(shown, read, expectation) == 2, "an icon with a frame is waited for until it is known to be parked")

        expectation.learn(from: read, plan: shown)
        #expect(count(shown, read, expectation) == 1, "learned from one read; the look doesn't count a slot that is off the bar either")

        // Seen on the bar later, it is counted again.
        let back = Fixtures.inventory([Fixtures.item(.system("airdrop"), frame: frame), item(notes)], bars: [bar])
        expectation.learn(from: back, plan: shown)
        #expect(count(shown, read, expectation) == 2)
    }

    @Test func anIconOnTheBarIsNotLearnedAsNotDrawn() {
        let read = Fixtures.inventory([item(weather), item(notes)], bars: [bar])
        var expectation = BarExpectation()
        expectation.learn(from: read, plan: plan(visible: [weather, notes]))
        #expect(count(plan(visible: [weather, notes]), read, expectation) == 2)
    }

    @Test func anAppIconParkedOffTheBarIsTreatedAsOneWithNoFrame() {
        let off = MenuBarItem(id: Fixtures.itemID(weather), ownerBundleID: weather, appName: nil, label: nil,
                              frames: [Fixtures.display: parked], overflowedOn: [], isMantel: false)
        let read = Fixtures.inventory([off, item(notes)], bars: [bar])
        // The plan that conceals the weather app doesn't ask for it, and learns nothing of it.
        var expectation = BarExpectation()
        expectation.learn(from: read, plan: plan(visible: [notes]))
        #expect(count(plan(visible: [weather, notes]), read, expectation) == 2)
        // The plan that draws it finds it with no place on the bar, and learns that macOS isn't drawing it.
        expectation.learn(from: read, plan: plan(visible: [weather, notes]))
        #expect(count(plan(visible: [weather, notes]), read, expectation) == 1)
    }

    @Test func anUnclaimedSlotOffTheBarIsNotCounted() {
        let read = Fixtures.inventory([item(notes)], untiedSlots: [Fixtures.display: [frame, parked]], bars: [bar])
        #expect(count(plan(visible: [notes]), read) == 2, "the notes app's icon and the slot on the bar")
    }

    @Test func aFrameOnADisplayWhoseBarIsNotGivenIsTakenToBeOnIt() {
        // The read gives the bar of another display only.
        let other = MenuBarGeometry(displayUUID: elsewhere, rect: CGRect(x: 5000, y: 0, width: 1000, height: 30), notch: nil)
        let read = Fixtures.inventory([item(notes)], bars: [other])
        #expect(count(plan(visible: [notes]), read) == 1)
        var expectation = BarExpectation()
        expectation.learn(from: read, plan: plan(visible: [notes]))
        #expect(count(plan(visible: [notes]), read, expectation) == 1)
    }

    // MARK: What a read teaches

    @Test func anIconFoundNotDrawnThoughThePlanAskedForItIsLeftOut() {
        let shown = plan(visible: [weather, notes])
        let read = Fixtures.inventory([item(weather, framed: false), item(notes)])
        var expectation = BarExpectation()
        #expect(count(shown, read, expectation) == 2, "before anything is learned it is waited for")
        expectation.learn(from: read, plan: shown)
        #expect(count(shown, read, expectation) == 1, "macOS isn't drawing it, and a reveal doesn't bring it")

        // Seen on a bar later, it is counted again.
        expectation.learn(from: Fixtures.inventory([item(weather), item(notes)]), plan: shown)
        #expect(count(shown, read, expectation) == 2)
    }

    @Test func anIconThePlanConcealedIsNotLearnedAsNotDrawn() {
        // The weather app is Hidden: the read of the collapsed bar finds its icon concealed, as the plan asked. That says nothing of
        // whether macOS draws it when it is revealed.
        let collapsed = plan(visible: [notes])
        let read = Fixtures.inventory([item(weather, framed: false), item(notes)])
        var expectation = BarExpectation()
        expectation.learn(from: read, plan: collapsed)
        #expect(count(plan(visible: [weather, notes]), read, expectation) == 2)
    }

    @Test func anIconTheReadDoesNotHoldKeepsWhatWasLearned() {
        // The weather app didn't answer the second read: its icons are not in it, and nothing is learned or forgotten of them.
        let shown = plan(visible: [weather, notes])
        let first = Fixtures.inventory([item(weather, framed: false), item(notes)])
        var expectation = BarExpectation()
        expectation.learn(from: first, plan: shown)
        expectation.learn(from: Fixtures.inventory([item(notes)]), plan: shown)
        #expect(count(shown, first, expectation) == 1)
    }

    @Test func onlyTheIconsThePlanAskedForAreLearned() {
        // Read under a plan that draws the VPN app and the notes app: the weather app's icon has no place because the plan took it away,
        // and the VPN app's has none though the plan drew it.
        let read = Fixtures.inventory([item(weather, framed: false), item(vpn, framed: false), item(notes)])
        var expectation = BarExpectation()
        expectation.learn(from: read, plan: plan(visible: [vpn, notes]))
        #expect(count(plan(visible: [weather, vpn, notes]), read, expectation) == 2, "the weather app's and the notes app's")
    }
}
