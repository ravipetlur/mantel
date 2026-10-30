import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The bar is the one a read was of when the whole ordered list of its slots is the list the read had.
@Suite("Bar slot check")
struct BarSlotCheckTests {
    private func slot(_ x: CGFloat, width: CGFloat = 30, name: String? = nil) -> BarSlot {
        BarSlot(frame: CGRect(x: x, y: 0, width: width, height: 30), name: name)
    }

    private func snapshot(_ slots: [BarSlot], names: Bool = true) -> SlotSnapshot {
        SlotSnapshot(displayUUID: "d", slots: slots.map(\.frame), names: names ? slots.map(\.name) : [])
    }

    private let read = [BarSlot(frame: CGRect(x: 100, y: 0, width: 30, height: 30), name: "one"),
                        BarSlot(frame: CGRect(x: 140, y: 0, width: 40, height: 30), name: nil),
                        BarSlot(frame: CGRect(x: 190, y: 0, width: 30, height: 30), name: "three")]

    @Test func theSameListIsTheSameBar() {
        #expect(BarSlotCheck.isSame(read: read, now: snapshot(read)))
        let jitter = read.map { BarSlot(frame: $0.frame.offsetBy(dx: 0.4, dy: -0.3), name: $0.name) }
        #expect(BarSlotCheck.isSame(read: read, now: snapshot(jitter)), "to within half a point")
    }

    @Test func aSlotThatMovedByMoreThanHalfAPointIsAnotherBar() {
        var moved = read
        moved[1] = BarSlot(frame: read[1].frame.offsetBy(dx: 0.6, dy: 0), name: nil)
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(moved)))
    }

    @Test func aSlotThatChangedWidthIsAnotherBar() {
        // An icon that is wider by a few points (live text) slides everything to its left, and the one to its left is cropped across two.
        var wider = read
        wider[2] = BarSlot(frame: CGRect(x: 187, y: 0, width: 33, height: 30), name: "three")
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(wider)))
    }

    @Test func aSlotThatAppearsIsAnotherBarWhereverItIs() {
        let right = read + [slot(230)]
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(right)), "at the right end")
        let between = [read[0], slot(140), read[1], read[2]]
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(between)), "between two")
        // Inserted to the right of a slot, as wide as it, it sits exactly where that slot was: the whole list is what says so.
        let asWide = [read[0], read[1], slot(190, width: 30), BarSlot(frame: CGRect(x: 230, y: 0, width: 30, height: 30), name: nil)]
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(asWide)))
    }

    @Test func aSlotThatGoesIsAnotherBar() {
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(Array(read.dropLast()))))
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot([])))
    }

    @Test func aNameThatDiffersIsAnotherBar() {
        var renamed = read
        renamed[0] = BarSlot(frame: read[0].frame, name: "other")
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(renamed)))
    }

    @Test func aModulesNameOnOneSideOnlyIsAnotherBar() {
        // Every window names a system module's slot: a module named in one list and not in the other has traded places with a nameless
        // icon of its width.
        let withModule = [read[0], BarSlot(frame: read[1].frame, name: "com.apple.menuextra.wifi"), read[2]]
        var traded = withModule
        traded[1] = BarSlot(frame: read[1].frame, name: nil)
        #expect(!BarSlotCheck.isSame(read: withModule, now: snapshot(traded)))
        #expect(!BarSlotCheck.isSame(read: traded, now: snapshot(withModule)))
        #expect(BarSlotCheck.isSame(read: withModule, now: snapshot(withModule)))
    }

    @Test func aNameOneSideLacksSaysNothingAgainstTheBar() {
        // A window of MenuBarAgent's can lack the names another has.
        #expect(BarSlotCheck.isSame(read: read, now: snapshot(read, names: false)))
        var unnamed = read
        unnamed[0] = BarSlot(frame: read[0].frame, name: nil)
        #expect(BarSlotCheck.isSame(read: read, now: snapshot(unnamed)))
        #expect(BarSlotCheck.isSame(read: unnamed, now: snapshot(read)))
    }

    // MARK: What moved

    private static let untrusted = "slots that aren't Mantel's came or went: no icon is known to be where it was"

    @Test func mantelsOwnSlotThatComesLeftOfTheOthersMovesNoneOfThem() {
        // The bar is right-aligned: what comes at its left end slides nothing.
        let left = [slot(60, name: OwnItems.hiddenDotName)] + read
        let difference = BarSlotCheck.difference(read: read, now: snapshot(left))
        #expect(difference.isTrusted)
        #expect(difference.unmoved == [0, 1, 2])
        #expect(difference.summary == "slots 3 -> 4: 1 came at the left end (the first at x 60, 30 pt wide); Mantel's own came: mantel.dot.hidden")
    }

    @Test func aSlotOfAnyoneElsesThatComesLeftOfTheOthersIsAllOrNothing() {
        // A slot with no name, as wide as the ones it is left of, is what an icon that came between two looks like to the walk from the
        // right (each slot to its left slid into the frame of the one before): it can't be told from one at the left end.
        let left = [slot(60)] + read
        let difference = BarSlotCheck.difference(read: read, now: snapshot(left))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty)
        #expect(difference.summary == "slots 3 -> 4: 1 came at the left end (the first at x 60, 30 pt wide); \(Self.untrusted)")
        // A name that isn't Mantel's own item's is no better: it is an app's.
        let named = [slot(60, name: "mantel.fixture.one")] + read
        #expect(!BarSlotCheck.difference(read: read, now: snapshot(named)).isTrusted)
    }

    @Test func mantelsOwnSlotThatComesBetweenTwoMovesWhatIsLeftOfItAndNothingRightOfIt() {
        // A slot of 20 comes in between the first and the second: the first slides left by the 25 it takes, the rest are where they were.
        let between = [BarSlot(frame: read[0].frame.offsetBy(dx: -25, dy: 0), name: "one"), slot(115, width: 20, name: OwnItems.alwaysDotName),
                       read[1], read[2]]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(between))
        #expect(difference.isTrusted)
        #expect(difference.unmoved == [1, 2])
        #expect(difference.summary == "slots 3 -> 4: 1 left of x 130 differ (2 there now; the left end moved 25 pt left); Mantel's own came: mantel.dot.always")
    }

    @Test func aSlotOfAnyoneElsesThatComesBetweenTwoIsAllOrNothing() {
        let between = [BarSlot(frame: read[0].frame.offsetBy(dx: -25, dy: 0), name: "one"), slot(115, width: 20), read[1], read[2]]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(between))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty)
        #expect(difference.summary == "slots 3 -> 4: 1 left of x 130 differ (2 there now; the left end moved 25 pt left); \(Self.untrusted)")
    }

    @Test func aSlotThatComesAtTheRightEndMovesEveryOtherSlot() {
        // Everything left of it slides by what it takes, and nothing is where it was known to be.
        let shifted = read.map { BarSlot(frame: $0.frame.offsetBy(dx: -40, dy: 0), name: $0.name) }
        let difference = BarSlotCheck.difference(read: read, now: snapshot(shifted + [slot(230)]))
        #expect(difference.unmoved.isEmpty)
        #expect(difference.summary == "slots 3 -> 4: 3 left of x 220 differ (4 there now; the left end moved 40 pt left); \(Self.untrusted)")
        // Mantel's own slot there trusts nothing either: there is no slot right of it that is where it was.
        let own = BarSlotCheck.difference(read: read, now: snapshot(shifted + [slot(230, name: OwnItems.hiddenDotName)]))
        #expect(own.isTrusted && own.unmoved.isEmpty)
    }

    @Test func aSlotThatLiesWhereOneWasIsNotCountedWhenSomethingRightOfItDiffers() {
        // The first slot's frame is still a slot's, but the second has changed width: the list from the right end stops there, and the
        // slot that lies in the first's place may be any icon that slid into it. No slot came or went, so the run right of it is trusted.
        let lookalike = [slot(100), BarSlot(frame: CGRect(x: 135, y: 0, width: 45, height: 30), name: nil), read[2]]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(lookalike))
        #expect(difference.isTrusted)
        #expect(difference.unmoved == [2])
        #expect(difference.summary == "slots 3 -> 3: 2 left of x 180 differ (2 there now)")
    }

    @Test func aRunOfSlotsOfOneWidthWithNoNamesThatLosesOneIsAllOrNothing() {
        // Five icons of one width and no names; the one that was at the right end goes, and each of the others slides into its neighbour's
        // frame: every frame of the new list is a frame of the old one. The walk from the right matches all four, and what it calls the
        // first difference is the left end of the list, which is nowhere near where the icon went.
        func five(_ count: Int) -> [BarSlot] { (0..<count).map { slot(100 + CGFloat($0 + (5 - count)) * 40) } }
        let difference = BarSlotCheck.difference(read: five(5), now: snapshot(five(4)))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty, "the run the walk passed proves nothing of an icon in it")
        #expect(difference.summary == "slots 5 -> 4: 1 left of x 130 differ (none there now); \(Self.untrusted)")
        // And one that comes, the other way.
        #expect(!BarSlotCheck.difference(read: five(4), now: snapshot(five(5))).isTrusted)
    }

    @Test func dotsThatComeAmongNamelessSlotsOfTheirWidthAreMantelsOwnAndKeepWhatIsRightOfThem() {
        // The dots come in the middle of a run of icons of one width with no names. Each of them lies in the frame of an icon that slid
        // left of it. A name on one side only says nothing to `isSame`, but here it ends the walk: Mantel's slot is never paired with an
        // app's nameless one. What is left of the stop is the two icons that slid, and the two dots that came: the slots that aren't
        // Mantel's are the same ones, so what is right of the dots is where it was.
        let read = (0..<4).map { slot(100 + CGFloat($0) * 40) }
        let now = [slot(20), slot(60), slot(100, name: OwnItems.hiddenDotName), slot(140, name: OwnItems.alwaysDotName), slot(180), slot(220)]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(difference.isTrusted)
        #expect(difference.unmoved == [2, 3])
        #expect(difference.summary == "slots 4 -> 6: 2 left of x 170 differ (4 there now; the left end moved 80 pt left); Mantel's own came: mantel.dot.hidden, mantel.dot.always")
    }

    @Test func aDotAtTheLeftEndOfARunOfNamelessSlotsThatLosesOneOfThemIsAllOrNothing() {
        // The dots sit at the left end of a run of icons of their width, and the last icon of the run goes: each icon, and each dot, slides
        // right into the frame of its neighbour. Every pair has the same frame, and the dots have names the nameless icons lack, which
        // `isSame` would let pass: the walk stops at the dot instead, and what is left is one icon in the read and none now.
        let read = [slot(20, name: OwnItems.hiddenDotName), slot(60, name: OwnItems.alwaysDotName)] + (0..<3).map { slot(100 + CGFloat($0) * 40) }
            + [slot(220, width: 80)]
        let now = [slot(60, name: OwnItems.hiddenDotName), slot(100, name: OwnItems.alwaysDotName), slot(140), slot(180), slot(220, width: 80)]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty, "the icons that slid are not counted as unmoved")
        #expect(difference.summary == "slots 6 -> 5: 3 left of x 130 differ (2 there now; the left end moved 40 pt right); \(Self.untrusted)")
        // With one dot, the same.
        let one = Array(read.dropFirst())
        #expect(!BarSlotCheck.difference(read: one, now: snapshot(Array(now.dropFirst()))).isTrusted)
    }

    /// A dot that only slid to where the walk stops is no dot that came or went: what the walk passed slid with it. The last Hidden icon,
    /// just left of the dot, goes, and an icon comes among the Shown ones: the first Shown icon's slot now holds the second's icon, and
    /// the second's the new one.
    @Test func aDotThatSlidToTheStopWhileAnIconWentLeftOfItAndAnotherCameIsAllOrNothing() {
        let read = [slot(0), slot(40, width: 20), slot(70, name: OwnItems.hiddenDotName), slot(110), slot(150), slot(190), slot(230, width: 60, name: "clock")]
        let now = [slot(-10), slot(30, name: OwnItems.hiddenDotName), slot(70), slot(110), slot(150), slot(190), slot(230, width: 60, name: "clock")]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty, "the Shown icons slid: none is known to be where it was")
    }

    /// The same with a look that says no names: the dot can't be told from an app's icon there, and the stop proves nothing.
    @Test func aDotAtTheStopOfALookWithNoNamesIsAllOrNothing() {
        let read = [slot(0), slot(40, name: OwnItems.hiddenDotName), slot(80), slot(120), slot(160), slot(200, width: 60, name: "clock")]
        let now = [slot(40), slot(80), slot(120), slot(160), slot(200, width: 60)]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now, names: false))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty)
    }

    /// The laptop's bar, full at the «, with the dots side by side and an app's icon left of them: an icon that comes among the Shown ones
    /// pushes that icon into the «, and every icon between slides one slot. The dots slid to the stop: nothing is trusted.
    @Test func dotsSideBySideOnABarFullAtTheChevronThatSlidAreAllOrNothing() {
        let read = [slot(0), slot(40, name: OwnItems.hiddenDotName), slot(80, name: OwnItems.alwaysDotName), slot(120), slot(160), slot(200, width: 60, name: "clock")]
        let now = [slot(0, name: OwnItems.hiddenDotName), slot(40, name: OwnItems.alwaysDotName), slot(80), slot(120), slot(160), slot(200, width: 60, name: "clock")]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty)
    }

    @Test func aSlotThatWentAndAnotherThatCameLeftOfARunOfOneWidthIsAllOrNothing() {
        // One icon goes from a run of one width (here the one nearest the clock), and another, of another width, comes at the left end.
        // Each icon of the run slides into its neighbour's frame, so the walk passes the run, and the counts of the slots are equal; the
        // widths in order are not (the new icon is 25 wide where the first was 30).
        let read = [slot(90, width: 30, name: "L"), slot(120, width: 20), slot(140, width: 20), slot(160, width: 20), slot(180, width: 20)]
        let now = [slot(85, width: 25), slot(110, width: 30, name: "L"), slot(140, width: 20), slot(160, width: 20), slot(180, width: 20)]
        #expect(!BarSlotCheck.isSame(read: read, now: snapshot(now)))
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty, "the slot that slid into the one that went is not unmoved")
        #expect(difference.summary.hasSuffix(Self.untrusted), "\(difference.summary)")
    }

    @Test func aSlotThatChangedWidthAtTheStopIsStillTrustedWhateverIsLeftOfIt() {
        // The condition keeps the one case it was for: one slot's width changes, and the slots left of it (the same ones, of the same
        // widths) slide.
        let read = [slot(60, width: 20), slot(90, width: 30), slot(130, width: 30), slot(170, width: 30)]
        let now = [slot(50, width: 20), slot(80, width: 40), slot(130, width: 30), slot(170, width: 30)]
        let wider = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(wider.isTrusted)
        #expect(wider.unmoved == [2, 3])
        // The one nearest the stop is the one that may differ: another slot left of it that does is a slot that came or went.
        let other = [slot(50, width: 25), slot(80, width: 40), slot(130, width: 30), slot(170, width: 30)]
        #expect(!BarSlotCheck.difference(read: read, now: snapshot(other)).isTrusted)
    }

    @Test func mantelsOwnSlotsThatWentLeaveTheOnesRightOfThemWhereTheyWere() {
        let dots = [slot(20, name: OwnItems.hiddenDotName), slot(60, name: OwnItems.alwaysDotName)]
        let difference = BarSlotCheck.difference(read: dots + read, now: snapshot(read))
        #expect(difference.isTrusted)
        #expect(difference.unmoved == [2, 3, 4])
        #expect(difference.summary == "slots 5 -> 3: 2 left of x 90 differ (none there now); Mantel's own went: mantel.dot.hidden, mantel.dot.always")
    }

    @Test func mantelsOwnSlotsThatCameAndAnotherThatWentIsAllOrNothing() {
        // The counts of the slots that aren't Mantel's differ, whatever else came.
        let now = [slot(20, name: OwnItems.hiddenDotName)] + read.dropFirst()
        let difference = BarSlotCheck.difference(read: read, now: snapshot(Array(now)))
        #expect(!difference.isTrusted)
    }

    @Test func aSlotThatWentFromTheRightEndLeavesNothingWhereItWas() {
        let gone = Array(read.dropLast())
        let difference = BarSlotCheck.difference(read: read, now: snapshot(gone))
        #expect(difference.unmoved.isEmpty)
        #expect(difference.summary == "slots 3 -> 2: 3 left of x 220 differ (2 there now); \(Self.untrusted)")
        #expect(BarSlotCheck.difference(read: read, now: snapshot([])).summary
            == "slots 3 -> 0: 3 left of x 220 differ (none there now); \(Self.untrusted)")
    }

    @Test func aNameThatDiffersEndsTheRunOfSlotsThatAreWhereTheyWere() {
        var renamed = read
        renamed[1] = BarSlot(frame: read[1].frame, name: "other")
        #expect(BarSlotCheck.difference(read: [read[0], BarSlot(frame: read[1].frame, name: "two"), read[2]], now: snapshot(renamed)).unmoved == [2])
    }

    @Test func aSlotThatChangedWidthMovesWhatIsLeftOfItAndSaysHowFar() {
        var wider = read
        wider[1] = BarSlot(frame: CGRect(x: 137, y: 0, width: 43, height: 30), name: nil)
        wider[0] = BarSlot(frame: read[0].frame.offsetBy(dx: -3, dy: 0), name: "one")
        let difference = BarSlotCheck.difference(read: read, now: snapshot(wider))
        #expect(difference.unmoved == [2])
        #expect(difference.summary == "slots 3 -> 3: 2 left of x 180 differ (2 there now; the left end moved 3 pt left)")
    }

    @Test func aReadIsOfTheSlotsItsBarDraws() async throws {
        // What the matcher hands the read: every drawn slot of each bar in order with its name, the « left out.
        let fixture = InventoryFixtures.desk()
        let reader = MenuBarReader(ax: fixture.ax, runningApps: { fixture.running }, clock: FakeClock())
        let snapshot = await reader.snapshot(layout: fixture.layout, includeRawTree: false)
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(snapshot.matchInput(ownBundleID: InventoryFixtures.ownBundleID), memory: &memory)

        #expect(Set(inventory.barSlots.keys) == Set(inventory.bars.map(\.displayUUID)))
        for (display, slots) in inventory.barSlots {
            #expect(!slots.isEmpty)
            #expect(slots.map { $0.frame.minX } == slots.map { $0.frame.minX }.sorted(), "left to right")
            // Every frame an item has on this bar is among them.
            for item in inventory.items {
                if let frame = item.frames[display] { #expect(slots.contains { $0.frame == frame }) }
            }
        }
    }
}
