import CoreGraphics
import Foundation
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

    // MARK: Mantel's own items

    private let group = OwnItems.itemID(GroupID(rawValue: "0000000a"))
    private let spacer = OwnItems.itemID(SpacerID(rawValue: "00000001"))
    /// A read gives Mantel's items the running app's bundle ID, not the layout's `mantel`.
    private func read(_ layoutID: ItemID, frame: CGRect, bundleID: String = "com.example.mantel", kind: OwnItemKind) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: layoutID.key), ownerBundleID: bundleID, appName: nil, label: nil, frames: [main: frame],
                    overflowedOn: [], isMantel: true, ownKind: kind)
    }

    /// A group's icon at 3060...3100 and a spacer at 3100...3112 on the main bar, beside the ordinary items: the slots of a read that has
    /// them under the ID a read gives them.
    private var ownItems: [EmptySpace.OwnSlot] {
        EmptySpace.ownSlots(in: Inventory(
            capturedAt: Date(timeIntervalSince1970: 0), bars: bars,
            items: [read(group, frame: CGRect(x: 3060, y: 0, width: 40, height: 30), kind: .group),
                    read(spacer, frame: CGRect(x: 3100, y: 0, width: 12, height: 30), kind: .spacer)],
            chevrons: [:], reach: [], problems: [], unansweredApps: []))
    }

    private func classifyOwn(_ point: CGPoint, shown: Set<String>? = nil, items: [CGRect]? = nil) -> EmptySpace.Spot {
        EmptySpace.classify(point, bars: bars, shownBars: shown ?? allShown, itemFrames: items ?? self.items, appMenuFrames: menus,
                            ownItems: ownItems)
    }

    @Test func ownItemSpot() {
        #expect(classifyOwn(CGPoint(x: 3070, y: 15)) == .ownItem(group))
        #expect(classifyOwn(CGPoint(x: 3105, y: 15)) == .ownItem(spacer))
        // An own item owns its left edge and not its right one, as an ordinary item does.
        #expect(classifyOwn(CGPoint(x: 3060, y: 0)) == .ownItem(group))
        #expect(classifyOwn(CGPoint(x: 3112, y: 15)) == .empty(displayUUID: main))
        // Where an item's frame and an own item's overlap (the last read drew both), the own item is what the pointer is on.
        #expect(classifyOwn(CGPoint(x: 3070, y: 15), items: items + [CGRect(x: 3060, y: 0, width: 40, height: 30)]) == .ownItem(group))
        // Ordinary items are as they were.
        #expect(classifyOwn(CGPoint(x: 3010, y: 15)) == .item)
    }

    @Test func ownItemIsNotEmptySpace() {
        let spot = classifyOwn(CGPoint(x: 3070, y: 15))
        #expect(spot != .empty(displayUUID: main))
        #expect(EmptySpace.isInBar(spot), "the pointer is on the bar")
        // A click on one reveals nothing, and neither does resting on it; moving off it into empty space enters it.
        #expect(PointerReveal.clicked(at: spot) == nil)
        #expect(PointerReveal.moved(from: .empty(displayUUID: main), to: spot) == [.pointerLeftEmptySpace])
        #expect(PointerReveal.moved(from: spot, to: .empty(displayUUID: main)) == [.pointerEnteredEmptySpace])
        // On a bar that isn't on screen it is the hidden bar, as any item is.
        #expect(classifyOwn(CGPoint(x: 3070, y: 15), shown: [portrait, laptop]) == .hiddenBar)
        // The classification without own items' frames is unchanged (the ordinary item's frame covers this point).
        #expect(classify(CGPoint(x: 3070, y: 15)) == .item)
        #expect(classify(CGPoint(x: 3105, y: 15)) == .empty(displayUUID: main))
    }

    @Test func ownSlotsLeaveOutWhatIsOutOfTheWayOrCantBeTold() {
        func item(_ id: ItemID, kind: OwnItemKind, frames: [String: CGRect], overflowed: Set<String> = [], shares: Set<String> = []) -> MenuBarItem {
            MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: id.key), ownerBundleID: "com.example.mantel", appName: nil, label: nil,
                        frames: frames, overflowedOn: overflowed, isMantel: true, sharesFrameOn: shares, ownKind: kind)
        }
        let app = MenuBarItem(id: ItemID(bundleID: "com.example.app", key: .index(0)), ownerBundleID: "com.example.app", appName: nil,
                              label: nil, frames: [main: CGRect(x: 10, y: 0, width: 20, height: 30)], overflowedOn: [], isMantel: false)
        let inventory = Inventory(
            capturedAt: Date(timeIntervalSince1970: 0), bars: bars,
            items: [
                app,
                item(group, kind: .group, frames: [main: CGRect(x: 3060, y: 0, width: 40, height: 30)]),
                item(spacer, kind: .spacer, frames: [main: CGRect(x: 3100, y: 0, width: 12, height: 30)], overflowed: [main]),
                item(OwnItems.itemID(SpacerID(rawValue: "00000002")), kind: .spacer, frames: [main: CGRect(x: 3200, y: 0, width: 0, height: 30)]),
                item(OwnItems.itemID(SpacerID(rawValue: "00000003")), kind: .spacer, frames: [main: CGRect(x: 3300, y: 0, width: 12, height: 30)],
                     shares: [main]),
            ], chevrons: [:], reach: [], problems: [], unansweredApps: [])
        let slots = EmptySpace.ownSlots(in: inventory)
        #expect(slots == [EmptySpace.OwnSlot(item: group, frame: CGRect(x: 3060, y: 0, width: 40, height: 30))],
                "no app's, none in the « menu, none of no width, none that shares its frame with another")
    }

    @Test func ownSlotsNameTheItemAsTheLayoutDoes() {
        // A read of Mantel's own group icon says `com.example.mantel::mantel.group.0000000a`; the layout says `mantel::…`.
        let icon = read(group, frame: CGRect(x: 3060, y: 0, width: 40, height: 30), kind: .group)
        #expect(icon.id.bundleID == "com.example.mantel")
        #expect(OwnItems.layoutID(of: icon) == group)
        #expect(OwnItems.groupID(of: OwnItems.layoutID(of: icon)!) == GroupID(rawValue: "0000000a"))
        // A group icon told only by its description has an index for a key: it is on the bar, with no group ID.
        let described = MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .index(3)), ownerBundleID: "com.example.mantel", appName: nil,
                                    label: nil, frames: [main: CGRect(x: 3060, y: 0, width: 40, height: 30)], overflowedOn: [], isMantel: true,
                                    ownKind: .group)
        #expect(OwnItems.layoutID(of: described) == nil)
        let slots = EmptySpace.ownSlots(in: Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars, items: [described], chevrons: [:],
                                                      reach: [], problems: [], unansweredApps: []))
        #expect(slots.count == 1, "the icon is still an own item for the pointer")
        #expect(GroupHover.group(under: .ownItem(slots[0].item), among: [GroupID(rawValue: "0000000a")]) == nil, "and has no hover")
        // Not one of Mantel's, or a name that isn't an own item's: no layout identity.
        let other = MenuBarItem(id: ItemID(bundleID: "com.example.other", key: .identifier("mantel.group.0000000a")), ownerBundleID: "com.example.other",
                                appName: nil, label: nil, frames: [:], overflowedOn: [], isMantel: false)
        #expect(OwnItems.layoutID(of: other) == nil)
        let engine = MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.spacer.divider")), ownerBundleID: "com.example.mantel",
                                 appName: nil, label: nil, frames: [:], overflowedOn: [], isMantel: true)
        #expect(OwnItems.layoutID(of: engine) == nil)
    }

    @Test func hoverFindsTheGroupUnderThePointerInARead() {
        let id = GroupID(rawValue: "0000000a")
        let spot = classifyOwn(CGPoint(x: 3070, y: 15))
        #expect(GroupHover.group(under: spot, among: [id]) == id, "the spot a read's group icon gives names its group")
        #expect(GroupHover.group(under: spot, among: []) == nil, "a group that doesn't open on hover isn't")
        #expect(GroupHover.group(under: classifyOwn(CGPoint(x: 3105, y: 15)), among: [id]) == nil, "a spacer isn't")
        #expect(GroupHover.group(under: .item, among: [id]) == nil)
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
