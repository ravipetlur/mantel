import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKMenuBar

/// Whether an app's items are still where the read tied them (`ItemFrameCheck`).
struct ItemFrameCheckTests {
    private let display = "D1"

    /// Slots 36 wide, 44 apart; an app's own frame is six points inside its slot.
    private func slot(_ index: Int) -> CGRect { CGRect(x: 100 + CGFloat(index) * 44, y: 0, width: 36, height: 24) }
    private func frame(in index: Int) -> CGRect { slot(index).insetBy(dx: 6, dy: 1) }
    private var slots: [BarSlot] { (0..<6).map { BarSlot(frame: slot($0), name: nil) } }

    @Test func framesInTheSlotsTheReadGaveAreTied() {
        #expect(ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [frame(in: 2)]))
        #expect(ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [slot(2).offsetBy(dx: 0.3, dy: 0)]), "a frame is a frame to within a point")
    }

    @Test func aFrameThatHasSlidToTheNeighboursSlotIsNotTied() {
        // The read tied the app's item to slot 2, from a frame that was read before the bar moved by a slot.
        #expect(!ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [frame(in: 1)]))
        #expect(!ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [frame(in: 3)]))
    }

    @Test func aFrameThatIsGoneLeavesItsSlotUntied() {
        #expect(!ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: []))
        #expect(!ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [.zero]), "a frame with no area is no frame")
    }

    @Test func aFrameInNoSlotSaysNothing() {
        // An app that left a frame where macOS parks icons: it is in no slot of the bar.
        let parked = CGRect(x: 7, y: 700, width: 24, height: 24)
        #expect(ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [frame(in: 2), parked]))
        #expect(!ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [parked]), "and it isn't the one slot the read gave")
    }

    @Test func aFrameInAnotherItemsSlotIsNotTied() {
        // A second frame of the app, in a slot the read gave to someone else: not left alone as a frame in no slot is.
        #expect(!ItemFrameCheck.isTied(given: [slot(2)], slots: slots, framesNow: [frame(in: 2), frame(in: 4)]))
    }

    @Test func twoFramesInOneSlotAreNotTied() {
        #expect(!ItemFrameCheck.isTied(given: [slot(2), slot(3)], slots: slots, framesNow: [frame(in: 2), frame(in: 2)]))
    }

    @Test func anAppWithSeveralItemsIsComparedAsASet() {
        let given = [slot(1), slot(3)]
        #expect(ItemFrameCheck.isTied(given: given, slots: slots, framesNow: [frame(in: 1), frame(in: 3)]))
        #expect(ItemFrameCheck.isTied(given: given, slots: slots, framesNow: [frame(in: 3), frame(in: 1)]), "the app lists them in an order of its own")
        #expect(!ItemFrameCheck.isTied(given: given, slots: slots, framesNow: [frame(in: 1)]), "one of the slots has no frame now")
        #expect(!ItemFrameCheck.isTied(given: given, slots: slots, framesNow: [frame(in: 1), frame(in: 2)]))
    }

    @Test func aFrameIsNeverAMatchForASystemModulesSlot() {
        var named = slots
        named[3] = BarSlot(frame: slot(3), name: "com.apple.menuextra.clock")
        // The matcher gives no app's frame to the clock's slot: a frame there ties nothing, as one in no slot.
        #expect(ItemFrameCheck.isTied(given: [slot(2)], slots: named, framesNow: [frame(in: 2), frame(in: 3)]))
    }

    @Test func aSlotThatIsNotInTheReadsListIsNotTied() {
        #expect(!ItemFrameCheck.isTied(given: [slot(2).offsetBy(dx: 5, dy: 0)], slots: slots, framesNow: [frame(in: 2)]))
        #expect(!ItemFrameCheck.isTied(given: [], slots: slots, framesNow: [frame(in: 2)]), "an app with no slot in the read has nothing to keep")
    }

    // MARK: Over a read

    private func item(_ name: String, in index: Int) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: "com.example.\(name)", key: .identifier(name)), ownerBundleID: "com.example.\(name)", appName: nil,
                    label: nil, frames: [display: slot(index)], overflowedOn: [], isMantel: false, strayFrames: [:], ownKind: nil)
    }

    private func read() -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: [item("a", in: 1), item("b", in: 2), item("c", in: 3)],
                  chevrons: [:], reach: [], problems: [], barSlots: [display: slots])
    }

    private let all: Set<String> = ["com.example.a", "com.example.b", "com.example.c"]

    @Test func anUnchangedBarKeepsEveryApp() {
        let now = ["com.example.a": [frame(in: 1)], "com.example.b": [frame(in: 2)], "com.example.c": [frame(in: 3)]]
        #expect(ItemFrameCheck.appsStillTied(all, read: read(), display: display, framesNow: now) == all)
    }

    @Test func twoIconsOfOneWidthThatSwapPlacesAreSeen() {
        // The slots are where they were (and have no names to say otherwise); the apps' frames have traded places.
        let now = ["com.example.a": [frame(in: 1)], "com.example.b": [frame(in: 3)], "com.example.c": [frame(in: 2)]]
        #expect(ItemFrameCheck.appsStillTied(all, read: read(), display: display, framesNow: now) == ["com.example.a"])
    }

    @Test func anAppThatDidntAnswerIsLeftOut() {
        let now = ["com.example.a": [frame(in: 1)], "com.example.b": [frame(in: 2)]]
        #expect(ItemFrameCheck.appsStillTied(all, read: read(), display: display, framesNow: now) == ["com.example.a", "com.example.b"])
        #expect(ItemFrameCheck.appsStillTied(all, read: read(), display: display, framesNow: [:]).isEmpty)
    }

    @Test func theSystemsItemsAreKeptByTheNameOfTheirSlots() {
        func system(_ module: String, in index: Int) -> MenuBarItem {
            MenuBarItem(id: .system(module), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil, frames: [display: slot(index)],
                        overflowedOn: [], isMantel: false, strayFrames: [:], ownKind: nil)
        }
        func read(slotNames: [String?]) -> Inventory {
            Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: [system("wifi", in: 4), system("clock", in: 5)], chevrons: [:],
                      reach: [], problems: [],
                      barSlots: [display: (0..<6).map { BarSlot(frame: slot($0), name: slotNames[$0]) }])
        }
        let named: [String?] = [nil, nil, nil, nil, "com.apple.menuextra.wifi", "com.apple.menuextra.clock"]
        let system: Set<String> = [ItemID.systemBundleID]
        #expect(ItemFrameCheck.appsStillTied(system, read: read(slotNames: named), display: display, framesNow: [:]) == system, "no app is asked about them")
        // A slot with no name, or another's, says nothing of whose it is.
        #expect(ItemFrameCheck.appsStillTied(system, read: read(slotNames: [nil, nil, nil, nil, nil, "com.apple.menuextra.clock"]), display: display, framesNow: [:]).isEmpty)
        #expect(ItemFrameCheck.appsStillTied(system, read: read(slotNames: [nil, nil, nil, nil, "com.apple.menuextra.clock", "com.apple.menuextra.wifi"]),
                                             display: display, framesNow: [:]).isEmpty)
    }

    @Test func aModuleParkedOffTheBarDoesntCostTheOthersTheirPictures() {
        // macOS parks AirDrop below the bar while the allowlist holds: its frame is no slot of the bar, it is never cropped, and it says
        // nothing of the system's other items.
        func system(_ module: String, frame: CGRect) -> MenuBarItem {
            MenuBarItem(id: .system(module), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil, frames: [display: frame],
                        overflowedOn: [], isMantel: false, strayFrames: [:], ownKind: nil)
        }
        let names: [String?] = [nil, nil, nil, nil, "com.apple.menuextra.wifi", "com.apple.menuextra.clock"]
        let parked = CGRect(x: 7, y: 1878, width: 24, height: 24)
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [],
                             items: [system("wifi", frame: slot(4)), system("clock", frame: slot(5)), system("airdrop", frame: parked)],
                             chevrons: [:], reach: [], problems: [],
                             barSlots: [display: (0..<6).map { BarSlot(frame: slot($0), name: names[$0]) }])
        let system: Set<String> = [ItemID.systemBundleID]
        #expect(ItemFrameCheck.appsStillTied(system, read: read, display: display, framesNow: [:]) == system)
    }

    @Test func aReadWithNoSlotsForTheBarKeepsNothing() {
        let now = ["com.example.a": [frame(in: 1)]]
        #expect(ItemFrameCheck.appsStillTied(all, read: read(), display: "elsewhere", framesNow: now).isEmpty)
    }

    // MARK: A bar that the apps don't list their icons on

    @Test func anAppsFramesAreComparedWhereTheyAreWhenAnotherBarIsCaptured() {
        // The apps' frames are on D1's bar; D2's bar has the same icons in slots 1,000 points right.
        func slot2(_ index: Int) -> CGRect { slot(index).offsetBy(dx: 1000, dy: 0) }
        func item(_ app: String, in index: Int) -> MenuBarItem {
            MenuBarItem(id: ItemID(bundleID: "com.example.\(app)", key: .index(0)), ownerBundleID: "com.example.\(app)", appName: app, label: nil,
                        frames: [display: slot(index), "D2": slot2(index)], overflowedOn: [], isMantel: false)
        }
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: [item("a", in: 1), item("b", in: 2)], chevrons: [:],
                             reach: [], problems: [], barSlots: [display: slots, "D2": (0..<6).map { BarSlot(frame: slot2($0), name: nil) }])
        let now = ["com.example.a": [frame(in: 1)], "com.example.b": [frame(in: 2)]]
        let apps: Set<String> = ["com.example.a", "com.example.b"]

        #expect(ItemFrameCheck.appsStillTied(apps, read: read, display: "D2", framesDisplay: display, framesNow: now) == apps)
        #expect(ItemFrameCheck.appsStillTied(apps, read: read, display: "D2", framesNow: now).isEmpty, "against D2's own slots they are tied to nothing")
        // Where they are, a frame that has slid is still seen: the first app's is in the second's slot.
        let slid = ["com.example.a": [frame(in: 2)], "com.example.b": [frame(in: 2)]]
        #expect(ItemFrameCheck.appsStillTied(apps, read: read, display: "D2", framesDisplay: display, framesNow: slid) == ["com.example.b"])
        // And the bar that is captured is its own: an app with no icon on the bar the frames are on is compared on the one captured.
        #expect(ItemFrameCheck.appsStillTied(apps, read: read, display: display, framesDisplay: display, framesNow: now) == apps)
    }

    // MARK: What is said of an app that isn't tied

    @Test func anAppThatIsNotTiedSaysHowFarItsIconsAre() {
        let read = self.read()
        let a = "com.example.a"
        let given = read.items(ofApp: a).compactMap { $0.frames[display] }.first
        #expect(given != nil)
        let shift = Int((frame(in: 3).midX - (given?.midX ?? 0)).rounded())
        #expect(ItemFrameCheck.describeUntied(a, read: read, display: display, framesNow: [frame(in: 3)]) == "\(a)'s icons moved \(shift) pt right")
        #expect(ItemFrameCheck.describeUntied(a, read: read, display: display, framesNow: []) == "\(a) reports no icon now")
        #expect(ItemFrameCheck.describeUntied(a, read: read, display: display, framesNow: [frame(in: 1), frame(in: 2)])
            == "\(a) reports 2 icons where the read had 1")
    }
}
