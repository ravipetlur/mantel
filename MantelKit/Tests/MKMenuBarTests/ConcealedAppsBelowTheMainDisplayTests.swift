import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// Apps the plan conceals, with the laptop's lid open and its bar right below the main display.
///
/// The layout is the owner's: a main display 3360 × 1890 and the laptop's screen below it, from x 830, so that its bar is at y 1890 to
/// 1923 and its notch (a 185-point gap) from x 1601.5 to 1786.5. An app that is concealed can report the last x it had, at the height of
/// the main display's bottom edge plus four and a half points, which is where the apps that are drawn on the laptop's bar say they are: on
/// that bar, in the places of other apps' icons or left of the notch. (Concealed apps are also read at the left edge, a dozen points above
/// the bottom of the main display, which is on no bar.)
@Suite("Concealed apps below the main display", .timeLimit(.minutes(1)))
struct ConcealedAppsBelowTheMainDisplayTests {
    private let mainUUID = "display-main"
    private let laptopUUID = "display-laptop"
    private let own = "com.example.mantel"
    // "aaa" sorts before Mantel's: the apps' frames are looked at in that order, so a concealed app's would claim first.
    private let parked = "com.example.aaa-parked"
    private let parkedLeft = "com.example.aaa-parkedleft"
    private let shown = "com.example.shown"

    private var layout: DisplayLayout {
        DisplayLayout(displays: [
            DisplayInfo(uuid: mainUUID, name: "Main", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                        visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860), scale: 2, notch: nil, isBuiltIn: false, isMain: true),
            DisplayInfo(uuid: laptopUUID, name: "Built-in", frame: CGRect(x: 830, y: -1117, width: 1728, height: 1117),
                        visibleFrame: CGRect(x: 830, y: -1117, width: 1728, height: 1084), scale: 2,
                        notch: CGRect(x: 1601.5, y: -32, width: 185, height: 32), isBuiltIn: true, isMain: false),
        ])
    }

    private func slot(_ x: CGFloat, y: CGFloat, _ width: CGFloat = 38, name: String? = nil, height: CGFloat) -> AgentSlot {
        AgentSlot(frame: CGRect(x: x, y: y, width: width, height: height), identifier: name, role: nil, subrole: nil, description: nil,
                  ownerPID: nil, isOverflowChevron: false)
    }

    /// The two bars: both have room, and the same icons: the dots in the first two slots, the shown app in the third, then the clock.
    private var bars: [MatchBar] {
        [MatchBar(displayUUID: mainUUID, rect: CGRect(x: 0, y: 0, width: 3360, height: 30), slots: [
            slot(3100, y: 0, height: 30), slot(3138, y: 0, height: 30), slot(3176, y: 0, height: 30),
            slot(3214, y: 0, 125.5, name: "com.apple.menuextra.clock", height: 30),
        ]),
         MatchBar(displayUUID: laptopUUID, rect: CGRect(x: 830, y: 1890, width: 1728, height: 33), slots: [
            slot(1933.5, y: 1890, height: 33), slot(1971.5, y: 1890, height: 33), slot(2009.5, y: 1890, height: 33),
            slot(2412.5, y: 1890, 125.5, name: "com.apple.menuextra.clock", height: 33),
        ])]
    }

    private func extras(_ pid: pid_t, _ bundleID: String, _ frames: [CGRect], descriptions: [String?] = []) -> AppExtras {
        AppExtras(pid: pid, bundleID: bundleID, name: nil,
                  items: frames.enumerated().map {
                      ExtraItem(index: $0.offset, frame: $0.element, identifier: nil, title: nil,
                                description: $0.offset < descriptions.count ? descriptions[$0.offset] : nil)
                  }, timedOut: false)
    }

    /// The apps list their items on the laptop's bar, six points inside the slots: 1894.5 is the main display's height plus four and a half.
    private var apps: [AppExtras] {
        [
            extras(1, own, [CGRect(x: 1939.5, y: 1894.5, width: 24, height: 24), CGRect(x: 1977.5, y: 1894.5, width: 24, height: 24)],
                   descriptions: [DotsCopy.hiddenDotDescription, DotsCopy.alwaysDotDescription]),
            extras(2, shown, [CGRect(x: 2015.5, y: 1894.5, width: 24, height: 24)]),
            // Concealed, at the last x they had and the height of the laptop's bar: in the place of the second dot, and left of the notch.
            extras(3, parked, [CGRect(x: 1978.5, y: 1894.5, width: 24, height: 24)]),
            extras(4, parkedLeft, [CGRect(x: 1200, y: 1894.5, width: 24, height: 24), CGRect(x: 1240, y: 1894.5, width: 24, height: 24)]),
        ]
    }

    private func read(concealed: Set<String>) -> Inventory {
        var input = MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: layout, bars: bars, apps: apps, ownBundleID: own)
        input.concealedApps = concealed
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input, memory: &memory)
        return BarRegion.marking(inventory, menuFrames: [], draws: { !concealed.contains($0.ownerBundleID) })
    }

    @Test func theDotsAndTheShownAppsPlacesSurviveTheConcealedAppsFrames() {
        let inventory = read(concealed: [parked, parkedLeft])
        // The dots and the shown app are in their slots on the laptop's bar.
        let dots = inventory.items(ofApp: own).sorted { ($0.frames[laptopUUID]?.minX ?? 0) < ($1.frames[laptopUUID]?.minX ?? 0) }
        #expect(dots.map { $0.frames[laptopUUID]?.minX } == [1933.5, 1971.5])
        #expect(dots.allSatisfy { $0.isDot && !$0.isOverflowed && $0.sharesFrameOn.isEmpty })
        #expect(inventory.items(ofApp: shown).first?.frames[laptopUUID]?.minX == 2009.5)
        // The concealed apps are concealed: they hold no slot, and are not overflowed, though they say they are left of the notch (what they say is kept, to be told from what they say later).
        for app in [parked, parkedLeft] {
            #expect(inventory.items(ofApp: app).allSatisfy { $0.isConcealed && !$0.isOverflowed }, "\(app)")
        }
        #expect(OverflowInputs.overflowedApps(in: inventory).isEmpty)
        #expect(DotsRoom.verdict(in: inventory, shownBars: [mainUUID, laptopUUID]) == DotsRoom.Verdict())
        #expect(!DotsRoom.mayHaveAVerdict(in: inventory))
    }

    @Test func aConcealedAppsFrameOnlyClaimsASlotNobodyElseHas() {
        // Told that they are concealed, the apps whose frames are not believed claim after everyone else. Nobody else has the slot that
        // the fourth icon is in here, so a concealed app's frame still ties it: it is drawn, and it is that app's (an engine that has
        // not hidden it yet leaves it there).
        var bars = self.bars
        bars[1] = MatchBar(displayUUID: laptopUUID, rect: bars[1].rect, slots: bars[1].slots + [slot(2047.5, y: 1890, height: 33)])
        var apps = self.apps
        apps.append(extras(5, "com.example.zzz-parked", [CGRect(x: 2053.5, y: 1894.5, width: 24, height: 24)]))
        var input = MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: layout, bars: bars, apps: apps, ownBundleID: own)
        input.concealedApps = [parked, parkedLeft, "com.example.zzz-parked"]
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input, memory: &memory)
        #expect(inventory.items(ofApp: "com.example.zzz-parked").first?.frames[laptopUUID]?.minX == 2047.5)
        #expect(inventory.items(ofApp: own).allSatisfy { $0.frames[laptopUUID] != nil })
        #expect(inventory.untiedSlots[laptopUUID, default: []].isEmpty)
    }

    @Test func withoutTheConcealedAppsTheFramesTakeTheDotsSlotAndLookOverflowed() {
        // What the plan's concealed apps are for: told nothing, the first of the frames (the app that sorts first) claims the second dot's
        // slot, the dot has none, and the one left of the notch is overflowed.
        let inventory = read(concealed: [])
        #expect(inventory.items(ofApp: parked).first?.frames[laptopUUID]?.minX == 1971.5)
        #expect(inventory.items(ofApp: own).contains { $0.frames[laptopUUID] == nil })
        #expect(OverflowInputs.overflowedApps(in: inventory) == [parkedLeft])
    }
}
