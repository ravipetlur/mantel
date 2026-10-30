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
}
