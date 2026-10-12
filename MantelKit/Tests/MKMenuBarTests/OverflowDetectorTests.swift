import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Overflow detector", .timeLimit(.minutes(1)))
struct OverflowDetectorTests {
    private func slot(_ frame: CGRect?, role: String = "AXGroup", identifier: String? = nil) -> AgentSlot {
        AgentSlot(frame: frame, identifier: identifier, role: role, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false)
    }

    /// The recorded laptop bar: eight slots piled at x 958 to 967, the « at (979, 1, 17.5, 30), and the clock right of it.
    private func pile() -> [AgentSlot] {
        var slots = (0..<8).map { slot(CGRect(x: 958 + 1.25 * CGFloat($0), y: 1, width: 24, height: 30)) }
        slots.append(slot(CGRect(x: 979, y: 1, width: 17.5, height: 30), role: "AXButton"))
        slots.append(slot(CGRect(x: 1600, y: 0, width: 80, height: 33), identifier: "com.apple.menuextra.clock"))
        return slots
    }

    @Test func chevronIsTheAXButtonSlot() {
        let slots = pile()
        #expect(OverflowDetector.chevronPosition(in: slots) == 8)
        #expect(OverflowDetector.isChevron(slots[8]))
        #expect(!OverflowDetector.isChevron(slots[0]))
        // Its text plays no part: the same slot in any language is the chevron, and a slot with the right text and the wrong role isn't.
        let described = AgentSlot(frame: CGRect(x: 1, y: 1, width: 10, height: 10), identifier: nil, role: "AXGroup", subrole: nil,
                                  description: "Show Hidden Menu Bar Items", ownerPID: nil, isOverflowChevron: true)
        #expect(OverflowDetector.chevronPosition(in: [described]) == nil)
        #expect(OverflowDetector.chevronPosition(in: [slots[0]]) == nil)
    }

    @Test func slotsLeftOfChevronAreOverflowed() {
        let slots = [slot(CGRect(x: 100, y: 0, width: 30, height: 30)), slot(CGRect(x: 500, y: 0, width: 30, height: 30)),
                     slot(CGRect(x: 900, y: 0, width: 30, height: 30)), slot(CGRect(x: 1000, y: 0, width: 30, height: 30)),
                     slot(CGRect(x: 1100, y: 0, width: 30, height: 30))]
        let chevron = CGRect(x: 950, y: 0, width: 20, height: 30)
        #expect(OverflowDetector.overflowed(slots: slots, chevron: chevron, notch: nil) == [0, 1, 2])
        // A slot whose midpoint is the chevron's is not left of it.
        let level = [slot(CGRect(x: 955, y: 0, width: 10, height: 30))]
        #expect(OverflowDetector.overflowed(slots: level, chevron: chevron, notch: nil) == [])
    }

    @Test func pileSharingOneXIsOverflowed() {
        let sameX = (0..<4).map { _ in slot(CGRect(x: 958, y: 1, width: 24, height: 30)) }
        let chevron = CGRect(x: 979, y: 1, width: 17.5, height: 30)
        #expect(OverflowDetector.overflowed(slots: sameX, chevron: chevron, notch: nil) == [0, 1, 2, 3])

        // The recorded pile: the eight are overflowed; the « and the clock right of it are not.
        #expect(OverflowDetector.overflowed(slots: pile(), chevron: chevron, notch: nil) == Set(0..<8))
    }

    @Test func slotWithNoFrameOrNoWidthIsOverflowed() {
        let slots = [slot(nil), slot(CGRect(x: 10, y: 0, width: 0, height: 30)), slot(CGRect(x: 2000, y: 0, width: 30, height: 30))]
        #expect(OverflowDetector.overflowed(slots: slots, chevron: nil, notch: nil) == [0, 1])
        #expect(OverflowDetector.overflowed(slots: slots, chevron: CGRect(x: 950, y: 0, width: 20, height: 30), notch: nil) == [0, 1])
    }

    @Test func noChevronNoOverflow() {
        // Nothing to compare with: slots with frames, anywhere, aren't overflowed.
        let slots = [slot(CGRect(x: 100, y: 0, width: 30, height: 30)), slot(CGRect(x: 960, y: 0, width: 24, height: 30))]
        #expect(OverflowDetector.overflowed(slots: slots, chevron: nil, notch: nil) == [])
        #expect(OverflowDetector.overflowed(slots: [], chevron: nil, notch: nil) == [])
    }

    @Test func slotIntersectingNotchIsOverflowed() {
        // The recorded notch, in CoreGraphics points: x 771.5 to 956.5, y 0 to 32.
        let notch = CGRect(x: 771.5, y: 0, width: 185, height: 32)
        let slots = [slot(CGRect(x: 700, y: 1, width: 40, height: 30)),   // left of it
                     slot(CGRect(x: 760, y: 1, width: 40, height: 30)),   // its left edge is in the notch
                     slot(CGRect(x: 800, y: 1, width: 40, height: 30)),   // inside
                     slot(CGRect(x: 940, y: 1, width: 40, height: 30))]   // its right edge is in the notch
        #expect(OverflowDetector.overflowed(slots: slots, chevron: nil, notch: notch) == [1, 2, 3])
    }

    @Test func slotRightOfNotchIsNot() {
        let notch = CGRect(x: 771.5, y: 0, width: 185, height: 32)
        let slots = [slot(CGRect(x: 956.5, y: 1, width: 40, height: 30)),   // touches the notch's right edge only
                     slot(CGRect(x: 1000, y: 1, width: 40, height: 30)),
                     slot(CGRect(x: 731.5, y: 1, width: 40, height: 30))]   // touches its left edge only
        #expect(OverflowDetector.overflowed(slots: slots, chevron: nil, notch: notch) == [])
    }

    @Test func overflowIsPerDisplay() {
        // The same items on two displays: the laptop's bar is full and has a notch, the other has room for everything. What is
        // overflowed on one isn't on the other, and each is answered on its own.
        let items = (0..<3).map { CGRect(x: 600 + 70 * CGFloat($0), y: 1, width: 40, height: 30) }
        let laptop = items.map { slot($0) }
        let laptopNotch = CGRect(x: 700, y: 0, width: 185, height: 32)
        let desk = items.map { slot($0.offsetBy(dx: 2000, dy: 0)) }
        #expect(OverflowDetector.overflowed(slots: laptop, chevron: nil, notch: laptopNotch) == [1, 2])
        #expect(OverflowDetector.overflowed(slots: desk, chevron: nil, notch: nil) == [])
    }

    @Test func theChevronItselfIsNeverAnItem() {
        // A chevron with no frame isn't an overflowed item either.
        let slots = [slot(nil, role: "AXButton"), slot(CGRect(x: 100, y: 0, width: 30, height: 30))]
        #expect(OverflowDetector.overflowed(slots: slots, chevron: nil, notch: nil) == [])
    }
}
