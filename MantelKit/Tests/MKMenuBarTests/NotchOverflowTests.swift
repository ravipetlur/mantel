import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What the matcher and `BarRegion` make of a notched display that has run out of room, as macOS 27 shows it.
///
/// The bar is made like one that was read from a laptop's built-in display (1496 points wide, a 160-point notch from x 668 to 828) with some
/// icons that don't fit, with made-up apps. What was learned of it:
/// - MenuBarAgent lists 12 slots, all of them for icons that are drawn, from x 871.5 to the right edge. It lists no « and no slot for an
///   icon that isn't drawn.
/// - The icons that aren't drawn say where they would be: on the bar (y 2.5), left of the notch (x 484 to 574), in none of the slots.
/// - The icons that are concealed say they are at the left edge, a dozen points above the bottom of the display (y 955).
/// - An icon that is drawn can be a point or two wider than its slot, and then it is claimed by none, though it is in it.
@Suite("Notch overflow", .timeLimit(.minutes(1)))
struct NotchOverflowTests {
    private let uuid = "display-1496"
    private let own = "com.example.mantel"
    private let host = "com.example.host"
    private let dns = "com.example.dns"
    private let launcher = "com.example.launcher"
    private let shot = "com.example.shot"
    private let vpn = "com.example.vpn"
    private let tunnel = "com.example.tunnel"
    private let calendar = "com.example.calendar"
    private let hidden = "com.example.hidden"
    // Sorts before the app whose slot its frame is nearly in, as the real one did.
    private let input = "com.example.input"

    private var layout: DisplayLayout {
        DisplayLayout(displays: [
            DisplayInfo(uuid: uuid, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1496, height: 967),
                        visibleFrame: CGRect(x: 0, y: 56, width: 1496, height: 882), scale: 2,
                        notch: CGRect(x: 668, y: 939.5, width: 160, height: 27.5), isBuiltIn: true, isMain: true)
        ])
    }

    private let barRect = CGRect(x: 0, y: 0, width: 1496, height: 28)

    private func slot(_ x: CGFloat, _ width: CGFloat = 38, name: String? = nil) -> AgentSlot {
        AgentSlot(frame: CGRect(x: x, y: 0, width: width, height: 28), identifier: name, role: nil, subrole: nil, description: nil,
                  ownerPID: nil, isOverflowChevron: false)
    }

    /// The window's slots: five third-party icons, then bluetooth, sound, an icon with no name, battery, Wi-Fi, Control Center, the clock.
    private var bar: MatchBar {
        MatchBar(displayUUID: uuid, rect: barRect, slots: [
            slot(871.5), slot(909.5), slot(947.5), slot(985.5), slot(1023.5),
            slot(1069.5, 16, name: "com.apple.menuextra.bluetooth"), slot(1101.5, 22, name: "com.apple.menuextra.sound"),
            slot(1131.5, 89), slot(1228.5, 26, name: "com.apple.menuextra.battery"), slot(1270.5, 22, name: "com.apple.menuextra.wifi"),
            slot(1308.5, 26, name: "com.apple.menuextra.controlcenter"), slot(1350.5, 125.5, name: "com.apple.menuextra.clock"),
        ])
    }

    /// What the menu bar's Accessibility tree gives for Mantel's two items: no name, and what each is called for the accessibility tools.
    private static func dotDescription(_ index: Int) -> String {
        index == 0 ? DotsCopy.hiddenDotDescription : DotsCopy.alwaysDotDescription
    }

    private func extras(_ pid: pid_t, _ bundleID: String, _ frames: [CGRect]) -> AppExtras {
        AppExtras(pid: pid, bundleID: bundleID, name: nil,
                  items: frames.enumerated().map { ExtraItem(index: $0.offset, frame: $0.element, identifier: nil, title: nil,
                                                        description: bundleID == own ? Self.dotDescription($0.offset) : nil) },
                  timedOut: false)
    }

    private func item(_ x: CGFloat, width: CGFloat = 24, y: CGFloat = 2.5) -> CGRect { CGRect(x: x, y: y, width: width, height: 24) }

    /// The read: what each app says of where its icons are.
    private func read(dots: [CGRect], menuFrames: [CGRect] = []) -> Inventory {
        let apps = [
            extras(1, own, dots),
            extras(2, host, [item(484, width: 22, y: 3.5), item(522, width: 22, y: 3.5)]),
            extras(3, dns, [item(559, width: 15)]),
            extras(4, launcher, [item(840, width: 34)]),
            extras(5, shot, [item(954)]),
            // Not drawn, and its frame is 37 wide at 956: in the slot of the icon at 954, which is 24 wide at 947.5 + 6.
            extras(10, input, [item(956, width: 37)]),
            extras(6, vpn, [item(984, width: 40)]),
            extras(7, tunnel, [item(1022, width: 40)]),
            // A little wider than its slot: claimed by none, and drawn.
            extras(8, calendar, [item(1130, width: 91)]),
            // Concealed: at the left edge, a dozen points above the bottom of the display.
            extras(9, hidden, [CGRect(x: 7, y: 955, width: 24, height: 24)]),
        ]
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: layout, bars: [bar], apps: apps,
                                                          ownBundleID: own), memory: &memory)
        return BarRegion.marking(inventory, menuFrames: menuFrames, draws: { _ in true })
    }

    private func overflowed(_ bundleID: String, in inventory: Inventory) -> Bool {
        inventory.items(ofApp: bundleID).allSatisfy(\.isOverflowed) && !inventory.items(ofApp: bundleID).isEmpty
    }

    private func notOverflowed(_ bundleID: String, in inventory: Inventory) -> Bool {
        inventory.items(ofApp: bundleID).allSatisfy { !$0.isOverflowed } && !inventory.items(ofApp: bundleID).isEmpty
    }

    // MARK: The read

    @Test func theIconsLeftOfTheNotchAreOverflowedAndTheDotsInTheirSlotsAreNot() {
        let inventory = read(dots: [item(916), item(878)])
        // The three icons that say they are at x 484 to 574 are out of the way; MenuBarAgent has no slot for them.
        #expect(overflowed(host, in: inventory))
        #expect(overflowed(dns, in: inventory))
        #expect(inventory.items(ofApp: host).allSatisfy { $0.inferredOverflowOn == [uuid] && $0.frames.isEmpty })
        // The dots are in two of the five slots, and so are the apps right of them.
        let dots = inventory.items(ofApp: own)
        #expect(dots.count == 2)
        #expect(dots.allSatisfy { !$0.isOverflowed && $0.frames[uuid] != nil })
        #expect(notOverflowed(shot, in: inventory))
        #expect(notOverflowed(vpn, in: inventory))
        #expect(notOverflowed(tunnel, in: inventory))
        // A little wider than its slot, and in it: drawn.
        #expect(notOverflowed(calendar, in: inventory))
        // Every icon that is drawn is tied to its slot, though three are two points wider than it and one is 40 in 38: it has a frame.
        for app in [shot, vpn, tunnel, calendar] {
            #expect(inventory.items(ofApp: app).allSatisfy { $0.frames[uuid] != nil }, "\(app) has its slot")
        }
        #expect(inventory.items(ofApp: shot).first?.frames[uuid]?.minX == 947.5, "and the one whose slot it is, not the icon that sorts first")
        #expect(inventory.items(ofApp: vpn).first?.frames[uuid]?.minX == 985.5)
        #expect(inventory.items(ofApp: tunnel).first?.frames[uuid]?.minX == 1023.5)
        #expect(inventory.items(ofApp: calendar).first?.frames[uuid]?.minX == 1131.5)
        // The one that sorts first, whose frame is as near to that slot but farther from its middle, has none.
        #expect(inventory.items(ofApp: input).allSatisfy { $0.frames.isEmpty })
        // Concealed is not overflowed.
        #expect(notOverflowed(hidden, in: inventory))
        #expect(inventory.items(ofApp: hidden).allSatisfy { $0.isConcealed && $0.strayFrames.isEmpty })
        // What the automatic overflow is given: the apps, and not the dots. (The launcher, at 840, says it is right of the notch's edge, at
        // 828, and in no slot. The capture shows it isn't drawn, but nothing in the geometry says so, and it isn't taken to be.)
        #expect(OverflowInputs.overflowedApps(in: inventory) == [host, dns])
        #expect(DotsRoom.verdict(in: inventory, shownBars: [uuid]) == DotsRoom.Verdict())
    }

    @Test func menusThatEndBeforeTheNotchChangeNothing() {
        // The front app's menus end at x 381: the icons at 484 and on are right of them, and only the notch is in the way.
        let menus = [CGRect(x: 0, y: 0, width: 30, height: 28), CGRect(x: 330, y: 0, width: 51, height: 28)]
        let inventory = read(dots: [item(916), item(878)], menuFrames: menus)
        #expect(OverflowInputs.overflowedApps(in: inventory) == [host, dns])
    }

    @Test func dotsThatSayTheyAreLeftOfTheNotchAreInTheMenuAndInferred() {
        // The state of the video: the dots are among the icons that don't fit, and the rest are as they were.
        let inventory = read(dots: [item(598), item(560)])
        let dots = inventory.items(ofApp: own)
        #expect(dots.count == 2)
        #expect(dots.allSatisfy { $0.overflowedOn == [uuid] && $0.inferredOverflowOn == [uuid] && $0.frames.isEmpty })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [uuid]) == DotsRoom.Verdict(trapped: [uuid], inferred: [uuid]))
        // The dots aren't in the room estimate, and the room they need is what they take.
        #expect(DotsRoom.neededWidth(on: uuid, in: inventory, widths: ItemWidthCache()) == 2 * DotsRoom.assumedWidth)
        #expect(!OverflowInputs.occupiedFrames(in: inventory, display: uuid).contains { $0.minX < 828 })
    }

    @Test func aDotInTheGapRightOfTheNotchIsOutOfTheWayAndAnAppThereIsLeftAlone() {
        // The gap between the notch (828) and the first icon that is drawn (871.5) is where the « sits: nothing is drawn there. A dot that says
        // it is there is out of the way; it is told by its place, and says so. An app's place there is no sign (a Hidden app's stale place
        // has the same look), and is nothing: the launcher at 840 is left alone, as before.
        let inventory = read(dots: [item(840), item(878)])
        let dots = inventory.items(ofApp: own)
        let gap = dots.filter { $0.overflowedOn == [uuid] }
        #expect(gap.count == 1)
        #expect(gap.allSatisfy { $0.inferredOverflowOn == [uuid] && $0.frames.isEmpty })
        #expect(DotsRoom.verdict(in: inventory, shownBars: [uuid]) == DotsRoom.Verdict(trapped: [uuid], inferred: [uuid]))
        #expect(OverflowInputs.overflowedApps(in: inventory) == [host, dns])
        #expect(notOverflowed(launcher, in: inventory))
        // The same place left of the first drawn icon on a display that has no notch is no gap: nothing says the dot isn't drawn there.
        var memory = IndexMemory()
        let plainLayout = DisplayLayout(displays: [
            DisplayInfo(uuid: uuid, name: "Plain", frame: CGRect(x: 0, y: 0, width: 1496, height: 967),
                        visibleFrame: CGRect(x: 0, y: 56, width: 1496, height: 882), scale: 2, notch: nil, isBuiltIn: false, isMain: true)
        ])
        let plain = InventoryMatcher.match(
            MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: plainLayout, bars: [bar],
                       apps: [extras(1, own, [item(840), item(878)])], ownBundleID: own), memory: &memory)
        #expect(plain.items(ofApp: own).allSatisfy { !$0.isOverflowed })
    }

    @Test func aBarThatIsNotShownHasNoDotsToMakeRoomFor() {
        let inventory = read(dots: [item(598), item(560)])
        #expect(DotsRoom.verdict(in: inventory, shownBars: []) == DotsRoom.Verdict())
    }

    @Test func anIconThePlanHidesIsNotOverflowedWhatItSays() {
        // An app's own frames often stay where they were when it is hidden: the plan doesn't draw it, so it is concealed, not overflowed.
        var memory = IndexMemory()
        let apps = [extras(1, own, [item(916), item(878)]), extras(2, host, [item(484, width: 22, y: 3.5)])]
        let matched = InventoryMatcher.match(MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: layout, bars: [bar], apps: apps,
                                                        ownBundleID: own), memory: &memory)
        let marked = BarRegion.marking(matched, menuFrames: [], draws: { $0.ownerBundleID == self.own })
        #expect(marked.items(ofApp: host).allSatisfy { !$0.isOverflowed && $0.strayFrames[uuid] != nil })
        #expect(OverflowInputs.overflowedApps(in: marked).isEmpty)
        let drawn = BarRegion.marking(matched, menuFrames: [], draws: { _ in true })
        #expect(OverflowInputs.overflowedApps(in: drawn) == [host])
    }

    @Test func theStrayPlacesAreOnlyThoseOnTheBarAndInNoSlot() {
        let inventory = read(dots: [item(916), item(878)])
        #expect(inventory.items(ofApp: host).map { $0.strayFrames[uuid]?.minX } == [484, 522])
        #expect(inventory.items(ofApp: launcher).map { $0.strayFrames[uuid]?.minX } == [840], "at the notch's edge, and not in a slot")
        #expect(inventory.items(ofApp: own).allSatisfy { $0.strayFrames.isEmpty }, "in slots")
        #expect(inventory.items(ofApp: calendar).allSatisfy { $0.strayFrames.isEmpty }, "wider than its slot, but in it")
        #expect(inventory.items(ofApp: hidden).allSatisfy { $0.strayFrames.isEmpty }, "off the bar")
    }

    @Test func anItemSavedBeforeThePlacesWereKeptStillDecodes() throws {
        let item = MenuBarItem(id: ItemID(bundleID: host, key: .identifier("main")), ownerBundleID: host, appName: nil, label: nil, frames: [:],
                               overflowedOn: [uuid], isMantel: false, strayFrames: [uuid: item(484)], inferredOverflowOn: [uuid])
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(try JSONDecoder().decode(MenuBarItem.self, from: encoded) == item)
        object["strayFrames"] = nil
        object["inferredOverflowOn"] = nil
        let old = try JSONDecoder().decode(MenuBarItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.strayFrames.isEmpty && old.inferredOverflowOn.isEmpty)
        #expect(old.overflowedOn == [uuid])
    }
}
