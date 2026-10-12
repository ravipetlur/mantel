import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What the matcher makes of Mantel's own icons when macOS has put them in the « menu.
///
/// The bar is made like one that was read from a laptop's built-in display with its lid open beside a desk, with made-up apps. What was
/// learned of it, in offsets from the notch:
/// - the slots that are in the « menu are piled at one place, a point right of the notch, and have the width they would have on the bar;
/// - the « is a slot of its own (a button), about 22 points right of the notch;
/// - an icon that is in the menu doesn't report that pile: it reports the place it has in the menu once it is opened, which is on the
///   bar, left of the notch, where none of the window's slots is;
/// - and an icon that is not drawn at all (concealed) reports a place far from every bar.
@Suite("Own icons in the « menu", .timeLimit(.minutes(1)))
struct OwnIconsInTheMenuTests {
    private let layout = DisplayLayout.deskWithLaptopOpen
    private let laptopUUID = DisplayFixtures.laptopRightOfDesk.uuid
    private let own = "com.example.mantel"
    private let weather = "com.example.weather"
    private let vpn = "com.example.vpn"

    private var notch: CGRect { layout.cgRect(fromAppKit: DisplayFixtures.laptopRightOfDesk.notch!) }
    private var barRect: CGRect {
        let area = layout.cgRect(fromAppKit: DisplayFixtures.laptopRightOfDesk.frame)
        return CGRect(x: area.minX, y: area.minY, width: area.width, height: 33)
    }

    private func slot(_ x: CGFloat, width: CGFloat = 38, name: String? = nil, role: String = "AXGroup") -> AgentSlot {
        AgentSlot(frame: CGRect(x: x, y: barRect.minY + 1, width: width, height: 30), identifier: name, role: role, subrole: nil,
                  description: nil, ownerPID: nil, isOverflowChevron: false)
    }

    /// The slots of the laptop's bar: `piled` of them in the « menu, the « (unless `menu` is false), two third-party slots and the clock.
    private func bar(piled: Int, menu: Bool = true) -> MatchBar {
        var slots: [AgentSlot] = (0..<piled).map { _ in slot(notch.maxX + 1) }
        if menu { slots.append(slot(notch.maxX + 22, width: 17.5, role: "AXButton")) }
        slots += [slot(notch.maxX + 47), slot(notch.maxX + 85), slot(barRect.maxX - 140, width: 110, name: "com.apple.menuextra.clock")]
        return MatchBar(displayUUID: laptopUUID, rect: barRect, slots: slots)
    }

    /// What the menu bar's Accessibility tree gives for Mantel's two items: no name, and what each is called for the accessibility tools.
    private static func dotDescription(_ index: Int) -> String {
        index == 0 ? DotsCopy.hiddenDotDescription : DotsCopy.alwaysDotDescription
    }

    private func extras(_ pid: pid_t, _ bundleID: String, frames: [CGRect]) -> AppExtras {
        AppExtras(pid: pid, bundleID: bundleID, name: nil,
                  items: frames.enumerated().map { ExtraItem(index: $0.offset, frame: $0.element, identifier: nil, title: nil,
                                                        description: bundleID == own ? Self.dotDescription($0.offset) : nil) },
                  timedOut: false)
    }

    /// Where an icon in the menu reports itself to be: on the bar, left of the notch, in none of the slots.
    private var inTheOpenedMenu: [CGRect] {
        [CGRect(x: barRect.minX + 581, y: barRect.minY + 5, width: 24, height: 24),
         CGRect(x: barRect.minX + 619, y: barRect.minY + 5, width: 24, height: 24)]
    }

    private func inside(_ slot: AgentSlot) -> CGRect { slot.frame!.insetBy(dx: 6, dy: 1) }

    private func read(_ bar: MatchBar, own ownFrames: [CGRect], weather weatherFrame: CGRect? = nil, vpn vpnFrame: CGRect? = nil,
                      others: [AppExtras] = []) -> Inventory {
        var apps = [extras(1, own, frames: ownFrames)]
        if let weatherFrame { apps.append(extras(2, weather, frames: [weatherFrame])) }
        if let vpnFrame { apps.append(extras(3, vpn, frames: [vpnFrame])) }
        var memory = IndexMemory()
        return InventoryMatcher.match(MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: layout, bars: [bar], apps: apps + others,
                                                 ownBundleID: own), memory: &memory)
    }

    // MARK: In the menu

    @Test func ownIconsReportingTheirPlaceInTheOpenedMenuAreInTheMenu() {
        let bar = bar(piled: 3)
        let inventory = read(bar, own: inTheOpenedMenu, weather: inside(bar.slots[4]), vpn: inside(bar.slots[5]))

        let dots = inventory.items.filter(\.isMantel)
        #expect(dots.count == 2)
        #expect(dots.allSatisfy { $0.overflowedOn == [laptopUUID] }, "in the « menu of the bar the frame is on")
        #expect(dots.allSatisfy { $0.frames.isEmpty }, "and drawn nowhere")
        // The apps that are drawn are not.
        let apps = inventory.items.filter { !$0.isMantel && !$0.id.isSystem }
        #expect(apps.count == 2)
        #expect(apps.allSatisfy { $0.overflowedOn.isEmpty && $0.frames[laptopUUID] != nil })
        // What the layout above makes of it: a dot is trapped on a bar that is shown, though no app overflows.
        #expect(OverflowInputs.overflowedApps(in: inventory).isEmpty)
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]) == DotsRoom.Verdict(trapped: [laptopUUID]))
        #expect(DotsRoom.verdict(in: inventory, shownBars: []) == DotsRoom.Verdict(), "a bar that a full-screen app has hidden has none")
    }

    @Test func oneDotInTheMenuIsEnoughAndTheOtherOnTheBarIsNot() {
        let bar = bar(piled: 3)
        // The hidden dot is drawn in the first slot right of the « and the other is in the menu.
        let inventory = read(bar, own: [inTheOpenedMenu[0], inside(bar.slots[4])], vpn: inside(bar.slots[5]))
        let dots = inventory.items(ofApp: own)
        #expect(dots.count == 2)
        #expect(dots.filter { $0.overflowedOn == [laptopUUID] }.count == 1)
        #expect(dots.filter { $0.frames[laptopUUID] != nil }.count == 1)
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]).trapped == [laptopUUID])
    }

    @Test func ownIconsInTheirSlotsAreNotInTheMenuWhateverElseIs() {
        // Apps are piled and the « shows, but both dots are drawn: right of it, in slots.
        let bar = bar(piled: 3)
        let inventory = read(bar, own: [inside(bar.slots[4]), inside(bar.slots[5])])
        let dots = inventory.items(ofApp: own)
        #expect(dots.allSatisfy { $0.overflowedOn.isEmpty && $0.frames[laptopUUID] != nil })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]) == DotsRoom.Verdict())
    }

    @Test func twoDotsReportingOneFrameInNoSlotAreNotTakenForAnything() {
        // As read in the middle of a display change: both of Mantel's icons gave one and the same frame, on the bar and in none of its
        // slots. A frame is one icon's, so what they say is out of date: they are not in the menu because of it, a « showing or not, and
        // Mantel says it can't tell.
        let bar = bar(piled: 3)
        let shared = inTheOpenedMenu[0]
        let inventory = read(bar, own: [shared, shared], vpn: inside(bar.slots[5]))
        let dots = inventory.items(ofApp: own)
        #expect(dots.count == 2)
        #expect(dots.allSatisfy { $0.overflowedOn.isEmpty && $0.frames.isEmpty && $0.strayFrames.isEmpty && $0.sharesFrameOn == [laptopUUID] })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]) == DotsRoom.Verdict(cantTell: [laptopUUID: .ownIconsShareAFrame]))
        // Nor does a place left of the notch make them overflowed, which is what the same frame on a bar with no « would otherwise say.
        let noMenu = read(self.bar(piled: 0, menu: false), own: [shared, shared])
        let marked = BarRegion.marking(noMenu, menuFrames: [], draws: { _ in true })
        #expect(marked.items(ofApp: own).allSatisfy { !$0.isOverflowed })
        #expect(DotsRoom.verdict(in: marked, shownBars: [laptopUUID]) == DotsRoom.Verdict(cantTell: [laptopUUID: .ownIconsShareAFrame]))
    }

    @Test func twoDotsReportingOneFrameInASlotAreOutOfDateToo() {
        // One of them claims the slot and the other has none; which is which can't be told, and neither is believed.
        let bar = bar(piled: 3)
        let one = inside(bar.slots[4])
        let inventory = read(bar, own: [one, one], vpn: inside(bar.slots[5]))
        let dots = inventory.items(ofApp: own)
        #expect(dots.count == 2)
        #expect(dots.allSatisfy { $0.overflowedOn.isEmpty && $0.sharesFrameOn == [laptopUUID] })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]) == DotsRoom.Verdict(cantTell: [laptopUUID: .ownIconsShareAFrame]))
    }

    @Test func dotsThatReportTwoFramesAreNotSharing() {
        let bar = bar(piled: 3)
        let inventory = read(bar, own: [inTheOpenedMenu[0], inTheOpenedMenu[1]])
        #expect(inventory.items(ofApp: own).allSatisfy { $0.sharesFrameOn.isEmpty })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]).trapped == [laptopUUID])
    }

    @Test func aPlaceOnTheBarWithNoMenuShowingIsNoMenu() {
        // The same frames on a bar that has no « (nothing is in a menu): the icons aren't placed, and nothing is said of a menu.
        let bar = bar(piled: 0, menu: false)
        let inventory = read(bar, own: inTheOpenedMenu)
        let dots = inventory.items(ofApp: own)
        #expect(dots.allSatisfy { $0.overflowedOn.isEmpty && $0.frames.isEmpty })
        // Nothing says they are out of the way, and nothing says where they are: that is said, and nothing is moved.
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]) == DotsRoom.Verdict(cantTell: [laptopUUID: .dotHasNoSlot]))
    }

    @Test func iconsThatAreNotDrawnAtAllAreConcealedNotInTheMenu() {
        // macOS reports a place far from every bar for an icon it isn't drawing. With a « showing, Mantel can't tell where the dots
        // are, and says so rather than moving anything.
        let bar = bar(piled: 3)
        let parked = [CGRect(x: 7, y: barRect.maxY + 1000, width: 24, height: 24), CGRect(x: -1, y: barRect.maxY + 1000, width: 24, height: 24)]
        let inventory = read(bar, own: parked, weather: inside(bar.slots[4]), vpn: inside(bar.slots[5]))
        let dots = inventory.items(ofApp: own)
        #expect(dots.allSatisfy { $0.overflowedOn.isEmpty && $0.frames.isEmpty })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]) == DotsRoom.Verdict(cantTell: [laptopUUID: .ownIconsNotPlaced]))
    }

    @Test func anIconThatIsNotDrawnIsNotInTheMenuOfABarBelowTheMainDisplay() {
        // macOS reports an icon it isn't drawing at the left edge, a dozen points above the bottom of the main display. A bar that is right
        // below that display has its top edge there: the icon's frame touches the bar and isn't on it.
        let below = MatchBar(displayUUID: laptopUUID, rect: CGRect(x: 0, y: 1890, width: 1728, height: 33), slots: [
            AgentSlot(frame: CGRect(x: 1000, y: 1891, width: 17.5, height: 30), identifier: nil, role: "AXButton", subrole: nil,
                      description: nil, ownerPID: nil, isOverflowChevron: false),
            AgentSlot(frame: CGRect(x: 1100, y: 1890, width: 38, height: 33), identifier: nil, role: "AXGroup", subrole: nil,
                      description: nil, ownerPID: nil, isOverflowChevron: false),
        ])
        let parked = [CGRect(x: 7, y: 1878, width: 24, height: 24), CGRect(x: -1, y: 1878, width: 24, height: 24)]
        let inventory = read(below, own: parked)
        let dots = inventory.items(ofApp: own)
        #expect(dots.count == 2)
        #expect(dots.allSatisfy { $0.overflowedOn.isEmpty && $0.frames.isEmpty })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [laptopUUID]).trapped.isEmpty)
    }

    @Test func onlyOwnIconsAreTakenToBeInTheMenuByTheirFrame() {
        // The rule rests on Mantel's icons never being concealed. An app's are: one that reports a place on the bar and in no slot may
        // have been hidden by an allowlist, and isn't taken to be in the menu.
        let bar = bar(piled: 3)
        let inventory = read(bar, own: [inside(bar.slots[4]), inside(bar.slots[5])],
                             others: [extras(9, "com.example.other", frames: [inTheOpenedMenu[0]])])
        let other = inventory.items(ofApp: "com.example.other")
        #expect(other.count == 1)
        #expect(other.allSatisfy { $0.overflowedOn.isEmpty })
        #expect(OverflowInputs.overflowedApps(in: inventory).isEmpty)
    }

    @Test func anIconInTheMenuTakesNoRoomOnTheBarItIsIn() {
        // The dots in the menu are not among the frames that take room, so a trial's room estimate isn't short by them.
        let bar = bar(piled: 3)
        let inventory = read(bar, own: inTheOpenedMenu, weather: inside(bar.slots[4]))
        let taken = OverflowInputs.occupiedFrames(in: inventory, display: laptopUUID)
        #expect(!taken.contains(where: { inTheOpenedMenu.contains($0) }))
        #expect(taken.contains(bar.slots[4].frame!), "a slot that is drawn is")
    }
}
