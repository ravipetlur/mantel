import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKLayout

/// Where a panel is put: under the slot the last read found an own item in, never by the frame of a button.
@Suite("Panel anchors", .timeLimit(.minutes(1)))
struct PanelAnchorsTests {
    private let desk = "desk-display"
    private let side = "side-display"
    private let pointer = CGPoint(x: 700, y: 300)
    private let group = GroupID(rawValue: "0a1b2c3d")

    /// Mantel's items as a read gives them: under the running app's own bundle ID, not the layout's `mantel`.
    private func own(_ name: String, kind: OwnItemKind, frames: [String: CGRect], overflowedOn: Set<String> = []) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier(name)), ownerBundleID: "com.example.mantel", appName: nil, label: nil,
                    frames: frames, overflowedOn: overflowedOn, isMantel: true, ownKind: kind)
    }

    private func inventory(_ items: [MenuBarItem]) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: items, chevrons: [:], reach: [], problems: [])
    }

    private var full: Inventory {
        inventory([
            own("mantel.dot.hidden", kind: .hiddenDot, frames: [desk: CGRect(x: 1500, y: 0, width: 30, height: 24)]),
            own("mantel.dot.always", kind: .alwaysDot, frames: [desk: CGRect(x: 1530, y: 0, width: 30, height: 24)]),
            own("mantel.group.\(group.rawValue)", kind: .group, frames: [desk: CGRect(x: 1400, y: 0, width: 40, height: 24)]),
        ])
    }

    @Test func underDotUsesTheSlotOfTheDotThatWasClicked() {
        let hidden = PanelAnchors.secondBar(.underDot, dot: .hidden, display: desk, inventory: full, pointer: pointer)
        #expect(hidden == .under(CGRect(x: 1500, y: 0, width: 30, height: 24)))
        let always = PanelAnchors.secondBar(.underDot, dot: .always, display: desk, inventory: full, pointer: pointer)
        #expect(always == .under(CGRect(x: 1530, y: 0, width: 30, height: 24)))
    }

    @Test func noSlotOnThatDisplayFallsBackToTheRightEdge() {
        // The dot is drawn on the desk display only: a click on the other display's bar has no slot to go under.
        #expect(PanelAnchors.secondBar(.underDot, dot: .hidden, display: side, inventory: full, pointer: pointer) == .rightAligned)
        // •• with nothing in Always Hidden isn't on the bar at all.
        let none = inventory([own("mantel.dot.hidden", kind: .hiddenDot, frames: [desk: CGRect(x: 1500, y: 0, width: 30, height: 24)])])
        #expect(PanelAnchors.secondBar(.underDot, dot: .always, display: desk, inventory: none, pointer: pointer) == .rightAligned)
        // With the dots hidden, nothing is found.
        #expect(PanelAnchors.secondBar(.underDot, dot: nil, display: desk, inventory: inventory([]), pointer: pointer) == .rightAligned)
    }

    @Test func aDotOutOfTheWayHasNoSlot() {
        let behindTheNotch = inventory([own("mantel.dot.hidden", kind: .hiddenDot, frames: [desk: CGRect(x: 1500, y: 0, width: 30, height: 24)],
                                            overflowedOn: [desk])])
        #expect(PanelAnchors.slotFrame(of: .hiddenDot, on: desk, in: behindTheNotch) == nil)
    }

    @Test func otherKindsOfAnchorIgnoreTheSlots() {
        #expect(PanelAnchors.secondBar(.pointer, dot: nil, display: desk, inventory: full, pointer: pointer) == .pointer(pointer))
        #expect(PanelAnchors.secondBar(.rightAligned, dot: .hidden, display: desk, inventory: full, pointer: pointer) == .rightAligned)
    }

    @Test func aGroupPanelGoesUnderItsOwnIcon() {
        #expect(PanelAnchors.group(group, display: desk, inventory: full) == .under(CGRect(x: 1400, y: 0, width: 40, height: 24)))
        #expect(PanelAnchors.group(GroupID(rawValue: "ffffffff"), display: desk, inventory: full) == .rightAligned)
        #expect(PanelAnchors.group(group, display: side, inventory: full) == .rightAligned)
    }

    @Test func aReadOlderThanTheLastChangeOfDisplaysHasNoSlot() {
        let changed = Date(timeIntervalSince1970: 100)
        let old = Inventory(capturedAt: Date(timeIntervalSince1970: 50), bars: [], items: full.items, chevrons: [:], reach: [], problems: [])
        let fresh = Inventory(capturedAt: Date(timeIntervalSince1970: 150), bars: [], items: full.items, chevrons: [:], reach: [], problems: [])
        #expect(PanelAnchors.secondBar(.underDot, dot: .hidden, display: desk, inventory: old, pointer: pointer, displaysChangedAt: changed) == .rightAligned)
        #expect(PanelAnchors.group(group, display: desk, inventory: old, displaysChangedAt: changed) == .rightAligned)
        #expect(PanelAnchors.secondBar(.underDot, dot: .hidden, display: desk, inventory: fresh, pointer: pointer, displaysChangedAt: changed)
                == .under(CGRect(x: 1500, y: 0, width: 30, height: 24)))
        // No change of displays on record: the read is as good as any.
        #expect(PanelAnchors.secondBar(.underDot, dot: .hidden, display: desk, inventory: old, pointer: pointer)
                == .under(CGRect(x: 1500, y: 0, width: 30, height: 24)))
    }

    @Test func aDotSharingItsFrameOnThatDisplayHasNoSlotThere() {
        let shared = MenuBarItem(id: ItemID(bundleID: OwnItems.owner, key: .identifier("mantel.dot.hidden")), ownerBundleID: OwnItems.owner,
                                 appName: nil, label: nil, frames: [desk: CGRect(x: 1500, y: 0, width: 30, height: 24)], overflowedOn: [],
                                 isMantel: true, sharesFrameOn: [desk], ownKind: .hiddenDot)
        #expect(PanelAnchors.slotFrame(of: .hiddenDot, on: desk, in: inventory([shared])) == nil)
        #expect(PanelAnchors.secondBar(.underDot, dot: .hidden, display: desk, inventory: inventory([shared]), pointer: pointer) == .rightAligned)
        // The other display's bar isn't the one that is confused.
        let elsewhere = MenuBarItem(id: shared.id, ownerBundleID: OwnItems.owner, appName: nil, label: nil,
                                    frames: [desk: CGRect(x: 1500, y: 0, width: 30, height: 24), side: CGRect(x: 100, y: 0, width: 30, height: 24)],
                                    overflowedOn: [], isMantel: true, sharesFrameOn: [desk], ownKind: .hiddenDot)
        #expect(PanelAnchors.slotFrame(of: .hiddenDot, on: side, in: inventory([elsewhere])) == CGRect(x: 100, y: 0, width: 30, height: 24))
    }

    @Test func aPanelIsPutUnderTheItemAgainByTheNewestRead() {
        let kept = PanelAnchorSpec.secondBar(.underDot, dot: .hidden, pointer: pointer)
        #expect(PanelAnchors.resolve(kept, display: desk, inventory: full) == .under(CGRect(x: 1500, y: 0, width: 30, height: 24)))
        // The read after it moved the dot.
        let moved = inventory([own("mantel.dot.hidden", kind: .hiddenDot, frames: [desk: CGRect(x: 1440, y: 0, width: 30, height: 24)])])
        #expect(PanelAnchors.resolve(kept, display: desk, inventory: moved) == .under(CGRect(x: 1440, y: 0, width: 30, height: 24)))
        // It went out of the way (behind the notch): against the right edge.
        let gone = inventory([own("mantel.dot.hidden", kind: .hiddenDot, frames: [desk: CGRect(x: 1440, y: 0, width: 30, height: 24)],
                                  overflowedOn: [desk])])
        #expect(PanelAnchors.resolve(kept, display: desk, inventory: gone) == .rightAligned)
        #expect(PanelAnchors.resolve(.group(group), display: desk, inventory: full) == .under(CGRect(x: 1400, y: 0, width: 40, height: 24)))
        #expect(PanelAnchors.resolve(.secondBar(.pointer, dot: nil, pointer: pointer), display: desk, inventory: full) == .pointer(pointer))
        #expect(PanelAnchors.resolve(.secondBar(.rightAligned, dot: .hidden, pointer: pointer), display: desk, inventory: full) == .rightAligned)
    }

    @Test func ownItemFramesAreEveryOwnItemsOnEveryBar() {
        let both = inventory([own("mantel.dot.hidden", kind: .hiddenDot,
                                  frames: [desk: CGRect(x: 1500, y: 0, width: 30, height: 24), side: CGRect(x: 100, y: 0, width: 30, height: 24)]),
                              MenuBarItem(id: ItemID(bundleID: "com.example.app", key: .identifier("main")), ownerBundleID: "com.example.app",
                                          appName: nil, label: nil, frames: [desk: CGRect(x: 10, y: 0, width: 30, height: 24)],
                                          overflowedOn: [], isMantel: false)])
        #expect(Set(PanelAnchors.ownItemFrames(in: both)) == [CGRect(x: 1500, y: 0, width: 30, height: 24), CGRect(x: 100, y: 0, width: 30, height: 24)])
    }

    @Test func eachEventSaysWhyARevealIsAskedFor() {
        #expect(RevealCause.of(.dotClicked(.always)) == RevealCause(trigger: .dot, dot: .always))
        #expect(RevealCause.of(.dotClicked(.hidden)) == RevealCause(trigger: .dot, dot: .hidden))
        #expect(RevealCause.of(.pointerEnteredEmptySpace)?.trigger == .hover)
        #expect(RevealCause.of(.emptySpaceClicked)?.trigger == .emptySpaceClick)
        #expect(RevealCause.of(.scrolled(down: true))?.trigger == .scroll)
        #expect(RevealCause.of(.toggle(.hidden))?.trigger == .hotkey)
        #expect(RevealCause.of(.show(.all))?.trigger == .command)
        // What can't begin a reveal says nothing, so it leaves the cause of the one before it.
        for event in [RevealEvent.pointerLeftEmptySpace, .toggleFocusMode, .setFocusMode(true), .revealConfirmed, .timerFired(.hover),
                      .timerFired(.rehide), .guardsChanged(RehideGuards())] {
            #expect(RevealCause.of(event) == nil, "\(event)")
        }
    }
}
