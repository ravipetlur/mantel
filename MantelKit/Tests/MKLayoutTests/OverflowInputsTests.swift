import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Overflow inputs", .timeLimit(.minutes(1)))
struct OverflowInputsTests {
    private let main = "display-main"
    private let other = "display-other"

    private func frame(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 1, width: 30, height: 30) }

    private func item(_ id: ItemID, frames: [String: CGRect] = [:], overflowedOn: Set<String> = [], isMantel: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil, frames: frames, overflowedOn: overflowedOn,
                    isMantel: isMantel)
    }

    @Test func overflowedAppsAreTheOwnersOfOverflowedItems() {
        let inventory = Fixtures.inventory([
            // An app with one icon in the overflow and one on the bar is an overflowed app.
            Fixtures.item(Fixtures.itemID("com.example.a", "one"), frame: frame(100), overflowed: true),
            Fixtures.item(Fixtures.itemID("com.example.a", "two"), frame: frame(500)),
            // Overflowed behind the notch, with no frame.
            Fixtures.item(Fixtures.itemID("com.example.b"), overflowed: true),
            // On the bar; and concealed, which isn't the overflow.
            Fixtures.item(Fixtures.itemID("com.example.c"), frame: frame(600)),
            Fixtures.item(Fixtures.itemID("com.example.d")),
            // Not apps the person sorts: Mantel's own icon, and a system item.
            Fixtures.item(Fixtures.itemID("com.example.mantel", "dot"), frame: frame(120), overflowed: true, isMantel: true),
            Fixtures.item(.system("wifi"), frame: frame(130), overflowed: true),
        ])
        #expect(OverflowInputs.overflowedApps(in: inventory) == ["com.example.a", "com.example.b"])
        #expect(OverflowInputs.overflowedApps(in: .empty).isEmpty)

        // On another display only: still overflowed, as the tracker counts overflow on any display.
        let elsewhere = Fixtures.inventory([item(Fixtures.itemID("com.example.e"), frames: [other: frame(100)], overflowedOn: [other])])
        #expect(OverflowInputs.overflowedApps(in: elsewhere) == ["com.example.e"])
    }

    @Test func aPlaceThatIsWhatItWasBeforeTheTrialIsNoSignOfHowItWent() {
        func inferred(_ bundleID: String, at x: CGFloat) -> MenuBarItem {
            MenuBarItem(id: Fixtures.itemID(bundleID), ownerBundleID: bundleID, appName: nil, label: nil, frames: [:], overflowedOn: [main],
                        isMantel: false, strayFrames: [main: frame(x)], inferredOverflowOn: [main])
        }
        let before = Fixtures.inventory([inferred("com.example.a", at: 484), inferred("com.example.b", at: 522)])
        let known = OverflowInputs.strayPlaces(ofApps: ["com.example.a", "com.example.b"], in: before)
        #expect(known.count == 2)

        // The same places: nothing new is known, and neither is overflowed by them.
        #expect(OverflowInputs.overflowedApps(in: before, ignoringUnchangedPlaces: known).isEmpty)
        #expect(OverflowInputs.overflowedApps(in: before) == ["com.example.a", "com.example.b"], "without it, both are")
        // One has moved: that is something said now, and it counts.
        let after = Fixtures.inventory([inferred("com.example.a", at: 484), inferred("com.example.b", at: 560)])
        #expect(OverflowInputs.overflowedApps(in: after, ignoringUnchangedPlaces: known) == ["com.example.b"])
        // One that a slot or a « puts out of the way is not told by a place: it counts whatever the place is.
        let slotted = MenuBarItem(id: Fixtures.itemID("com.example.a"), ownerBundleID: "com.example.a", appName: nil, label: nil, frames: [:],
                                  overflowedOn: [main], isMantel: false, strayFrames: [main: frame(484)])
        #expect(OverflowInputs.overflowedApps(in: Fixtures.inventory([slotted]), ignoringUnchangedPlaces: known) == ["com.example.a"])
        // An app that wasn't put on trial has nothing known.
        #expect(OverflowInputs.overflowedApps(in: Fixtures.inventory([inferred("com.example.z", at: 484)]), ignoringUnchangedPlaces: known)
            == ["com.example.z"])
    }

    @Test func placesAreTheSameToWithinAPoint() {
        let home: [String: CGRect] = ["one": frame(484), "two": frame(100)]
        #expect(OverflowInputs.isSamePlaces(home, home))
        #expect(OverflowInputs.isSamePlaces(home, ["one": frame(484.5), "two": frame(99.5)]))
        #expect(OverflowInputs.isSamePlaces(home, ["one": frame(485), "two": frame(100)]), "a point is the same")
        #expect(!OverflowInputs.isSamePlaces(home, ["one": frame(485.5), "two": frame(100)]))
        #expect(!OverflowInputs.isSamePlaces(home, ["one": frame(484)]), "a display fewer is another place")
        #expect(!OverflowInputs.isSamePlaces(home, ["one": frame(484), "three": frame(100)]))
        #expect(OverflowInputs.isSamePlaces([:], [:]))
        #expect(!OverflowInputs.isSamePlaces(home, [:]))
    }

    @Test func occupiedFramesAreTheDrawnItemsAndTheUntiedSlots() {
        let drawn = frame(900)
        let ownFrame = frame(1500)
        let clockFrame = frame(1600)
        let sharedFrame = frame(1000)
        let slot = CGRect(x: 800, y: 1, width: 28, height: 30)
        let slotElsewhere = CGRect(x: 700, y: 1, width: 28, height: 30)
        let inventory = Inventory(
            capturedAt: Fixtures.date(0), bars: [],
            items: [
                item(Fixtures.itemID("com.example.drawn"), frames: [main: drawn]),
                // In the overflow of this display: its frame is in the pile, which takes no room of its own.
                item(Fixtures.itemID("com.example.piled"), frames: [main: frame(958)], overflowedOn: [main]),
                // Concealed.
                item(Fixtures.itemID("com.example.concealed")),
                // Mantel's own icon and the system's take room like the others.
                item(Fixtures.itemID("com.example.mantel", "dot"), frames: [main: ownFrame], isMantel: true),
                item(.system("clock"), frames: [main: clockFrame]),
                // Drawn on the other display only.
                item(Fixtures.itemID("com.example.away"), frames: [other: frame(400)]),
                // In the overflow of the other display, and drawn on this one.
                item(Fixtures.itemID("com.example.shared"), frames: [main: sharedFrame, other: frame(950)], overflowedOn: [other]),
            ],
            chevrons: [:], reach: [], problems: [], untiedSlots: [main: [slot], other: [slotElsewhere]])

        #expect(OverflowInputs.occupiedFrames(in: inventory, display: main) == [drawn, ownFrame, clockFrame, sharedFrame, slot])
        #expect(OverflowInputs.occupiedFrames(in: inventory, display: other) == [frame(400), slotElsewhere])
        #expect(OverflowInputs.occupiedFrames(in: inventory, display: "display-unknown").isEmpty)
        #expect(OverflowInputs.occupiedFrames(in: .empty, display: main).isEmpty)
    }

    @Test func occupiedFramesOfEveryBarAreThoseOfEachDisplaysBar() {
        let mainBar = MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1728, height: 32), notch: nil)
        let otherBar = MenuBarGeometry(displayUUID: other, rect: CGRect(x: 1728, y: 0, width: 1800, height: 30), notch: nil)
        let slot = CGRect(x: 800, y: 1, width: 28, height: 30)
        let inventory = Inventory(
            capturedAt: Fixtures.date(0), bars: [mainBar, otherBar],
            items: [
                item(Fixtures.itemID("com.example.one"), frames: [main: frame(900)]),
                item(Fixtures.itemID("com.example.two"), frames: [other: frame(2000)]),
                // Piled on one display, drawn on the other: it counts where it is drawn.
                item(Fixtures.itemID("com.example.three"), frames: [main: frame(100), other: frame(2100)], overflowedOn: [main]),
            ],
            chevrons: [:], reach: [], problems: [], untiedSlots: [main: [slot]])

        #expect(OverflowInputs.occupiedFrames(in: inventory) == [frame(900), slot, frame(2000), frame(2100)])
        // No bar, no frames: a read that found none says nothing of where icons are.
        #expect(OverflowInputs.occupiedFrames(in: .empty).isEmpty)
    }

    @Test func occupiedFramesGiveTheRoomTheBarReallyHas() {
        let bar = MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1728, height: 32), notch: nil)
        let inventory = Inventory(
            capturedAt: Fixtures.date(0), bars: [bar],
            items: [item(Fixtures.itemID("com.example.drawn"), frames: [main: frame(1200)])],
            chevrons: [:], reach: [], problems: [], untiedSlots: [main: [CGRect(x: 800, y: 1, width: 28, height: 30)]])

        // The icon that has no name takes room too: 400 points are free, not 800.
        let frames = OverflowInputs.occupiedFrames(in: inventory, display: main)
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: frames) == 400)
    }
}
