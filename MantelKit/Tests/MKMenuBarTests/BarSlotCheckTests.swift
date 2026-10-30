import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The bar is the one a read was of when the whole ordered list of its slots is the list the read had.
@Suite("Bar slot check", .timeLimit(.minutes(2)))
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

    // MARK: What moved

    private static let untrusted = "slots that aren't Mantel's came or went: no icon is known to be where it was"

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

    /// The laptop's bar, full at the «, with the dots side by side and an app's icon left of them: an icon that comes among the Shown ones
    /// pushes that icon into the «, and every icon between slides one slot. The dots slid to the stop: nothing is trusted.
    @Test func dotsSideBySideOnABarFullAtTheChevronThatSlidAreAllOrNothing() {
        let read = [slot(0), slot(40, name: OwnItems.hiddenDotName), slot(80, name: OwnItems.alwaysDotName), slot(120), slot(160), slot(200, width: 60, name: "clock")]
        let now = [slot(0, name: OwnItems.hiddenDotName), slot(40, name: OwnItems.alwaysDotName), slot(80), slot(120), slot(160), slot(200, width: 60, name: "clock")]
        let difference = BarSlotCheck.difference(read: read, now: snapshot(now))
        #expect(!difference.isTrusted)
        #expect(difference.unmoved.isEmpty)
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
}
