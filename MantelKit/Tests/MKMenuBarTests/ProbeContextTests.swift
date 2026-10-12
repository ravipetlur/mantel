import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

private let mainUUID = DisplayFixtures.deskMain.uuid
private let portraitUUID = DisplayFixtures.deskPortrait.uuid

private func snapshot(_ fixture: InventoryFixtures.Fixture) async -> MenuBarSnapshot {
    await MenuBarReader(ax: fixture.ax, runningApps: { fixture.running }, clock: FakeClock())
        .snapshot(layout: fixture.layout, includeRawTree: false)
}

@Suite("Probe context: what a probe compares", .timeLimit(.minutes(1)))
struct ProbeContextTests {
    @Test func restoredCheckUsesItemIDs() async {
        // The same menu bar, read twice: other windows (three Spaces and five), and every window listing its slots in an order of its own.
        // A slot told by where it was listed would be somebody else's after the shuffle; told by what it is, it is the same.
        let before = await snapshot(InventoryFixtures.desk(.init(windowsPerDisplay: 5, seed: 1)))
        let now = await snapshot(InventoryFixtures.desk(.init(windowsPerDisplay: 3, seed: 7)))
        #expect(ProbeContext.isRestored(before: before, now: now, running: before.apps.map { .fake($0.pid, $0.bundleID) }))
        #expect(ProbeContext.framedKeys(before) == ProbeContext.framedKeys(now))

        // The system items are named by their IDs, on each display.
        let keys = ProbeContext.framedKeys(before)
        #expect(keys.contains("\(mainUUID)|\(ItemID.system("clock").string)"))
        #expect(keys.contains("\(portraitUUID)|\(ItemID.system("controlcenter").string)"))
        // The ones with a name of their own by that name.
        #expect(keys.contains("\(mainUUID)|weather.temp"))
        #expect(keys.contains("\(portraitUUID)|weather.temp"))
        #expect(keys.count == 17 + 17, "seventeen slots on each display")
    }

    @Test func aSlotThatIsGoneIsNotRestored() async {
        let before = await snapshot(InventoryFixtures.desk())
        let gone = await snapshot(InventoryFixtures.desk(.init(concealed: [InventoryFixtures.weather])))
        let running = before.apps.map { RunningApp.fake($0.pid, $0.bundleID) }
        #expect(!ProbeContext.isRestored(before: before, now: gone, running: running))
        #expect(ProbeContext.framedKeys(before) != ProbeContext.framedKeys(gone))
        #expect(ProbeContext.framedKeys(before).subtracting(ProbeContext.framedKeys(gone)).contains("\(mainUUID)|weather.temp"))
        // Back again, it is.
        let back = await snapshot(InventoryFixtures.desk(.init(seed: 4)))
        #expect(ProbeContext.isRestored(before: before, now: back, running: running))
    }

    @Test func aSlotWithoutANameIsToldByWhereItIs() async {
        // The notes app's item has no name on any slot, and nor have the sync app's two. Their keys are where they are, so the same
        // place is the same key, and hiding one (its slot has no frame then) is a change.
        let shown = await snapshot(InventoryFixtures.desk())
        let hidden = await snapshot(InventoryFixtures.desk(.init(concealed: [InventoryFixtures.notes])))
        let unnamed = ProbeContext.framedKeys(shown).filter { $0.contains("|@") && $0.hasPrefix(mainUUID) }
        #expect(unnamed.count == 3, "the notes and the sync app's two")
        #expect(ProbeContext.framedKeys(hidden).filter { $0.contains("|@") && $0.hasPrefix(mainUUID) }.count == 2)
        #expect(ProbeContext.framedKeys(shown) != ProbeContext.framedKeys(hidden))
    }

    @Test func aWindowThatLacksTheNamesTakesThemFromTheOthers() async {
        // Some of MenuBarAgent's windows lack the identifiers the others have, and which one is read is Accessibility's order. The
        // keys don't depend on it.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 5))
        let read = await snapshot(fixture)
        let nameless = read.agentWindows.firstIndex { window in !window.slots.contains { $0.identifier == "weather.temp" } }
        #expect(nameless != nil, "the fixture has windows without the names")
        var reordered = read.agentWindows
        if let nameless, let first = reordered.indices.first(where: { reordered[$0].frame == reordered[nameless].frame }) {
            reordered.swapAt(nameless, first)
        }
        let swapped = MenuBarSnapshot(capturedAt: read.capturedAt, layout: read.layout, agentWindows: reordered, apps: read.apps, rawAgentTree: nil)
        #expect(ProbeContext.framedKeys(swapped) == ProbeContext.framedKeys(read))
        #expect(ProbeContext.framedKeys(swapped).contains("\(mainUUID)|weather.temp"))
    }

    @Test func slotsAreKeptApartByDisplay() async {
        // The same item is drawn on each display, and each display's has a key of its own.
        let read = await snapshot(InventoryFixtures.desk())
        let keys = ProbeContext.framedKeys(read)
        #expect(keys.contains("\(mainUUID)|\(ItemID.system("clock").string)"))
        #expect(keys.contains("\(portraitUUID)|\(ItemID.system("clock").string)"))
        let frames = ProbeContext.framedFrames(read)
        #expect(Set(frames.keys) == keys)
        #expect(frames["\(mainUUID)|\(ItemID.system("clock").string)"] != frames["\(portraitUUID)|\(ItemID.system("clock").string)"])
        // The order is left to right on each display, the main one's first.
        let order = ProbeContext.framedOrder(read)
        #expect(order.count == keys.count)
        #expect(order.first?.hasPrefix(mainUUID) == true && order.last?.hasPrefix(portraitUUID) == true)
        let weather = order.firstIndex { $0.hasSuffix("weather.temp") }
        let clock = order.firstIndex { $0.hasSuffix(ItemID.system("clock").string) }
        #expect((weather ?? Int.max) < (clock ?? Int.min), "the weather item is left of the clock")
    }

    @Test func theItemsAShotShowsAreTheMatchersIDs() async {
        let shown = await snapshot(InventoryFixtures.desk())
        let items = ProbeContext.shownItems(shown, ownBundleID: InventoryFixtures.ownBundleID)
        #expect(items.count == 17)
        #expect(items.contains("com.example.weather::weather.temp"))
        #expect(items.contains("system:clock"))
        #expect(items.contains("com.example.sync#0"))

        // While the weather app is concealed, its items are not shown.
        let hidden = await snapshot(InventoryFixtures.desk(.init(concealed: [InventoryFixtures.weather])))
        let gone = items.subtracting(ProbeContext.shownItems(hidden, ownBundleID: InventoryFixtures.ownBundleID))
        #expect(gone == ["com.example.weather::weather.temp", "com.example.weather::weather.alerts"])
    }

    @Test func aClockTickDoesNotMoveTheKeysOfSlotsWithNoName() async {
        // The clock's text gets two points wider, and every slot to its left is two points further left. The slots that have no name
        // are told by their width and by how many of the same width are to their right, so none of their keys changes.
        let read = await snapshot(InventoryFixtures.desk())
        let moved = read.agentWindows.map { window in
            let clock = window.slots.first { $0.identifier == "com.apple.menuextra.clock" }?.frame
            let slots = window.slots.map { slot -> AgentSlot in
                guard let frame = slot.frame, let clock else { return slot }
                var changed = frame
                if slot.identifier == "com.apple.menuextra.clock" {
                    changed = CGRect(x: frame.minX - 2, y: frame.minY, width: frame.width + 2, height: frame.height)
                } else if frame.minX < clock.minX {
                    changed = frame.offsetBy(dx: -2, dy: 0)
                }
                return AgentSlot(frame: changed, identifier: slot.identifier, role: slot.role, subrole: slot.subrole,
                                 description: slot.description, ownerPID: slot.ownerPID, isOverflowChevron: slot.isOverflowChevron)
            }
            return AgentWindow(frame: window.frame, slots: slots)
        }
        let later = MenuBarSnapshot(capturedAt: read.capturedAt, layout: read.layout, agentWindows: moved, apps: read.apps, rawAgentTree: nil)
        let clockKey = "\(mainUUID)|\(ItemID.system("clock").string)"
        #expect(ProbeContext.framedFrames(later)[clockKey] != ProbeContext.framedFrames(read)[clockKey], "the clock did move")
        #expect(ProbeContext.framedKeys(later) == ProbeContext.framedKeys(read))
        #expect(ProbeContext.isRestored(before: read, now: later, running: read.apps.map { .fake($0.pid, $0.bundleID) }))
        // The three that have no name are by width and rank from the right.
        let unnamed = ProbeContext.framedKeys(read).filter { $0.hasPrefix(mainUUID) && $0.contains("|@") }
        #expect(unnamed == ["\(mainUUID)|@w72#0", "\(mainUUID)|@w72#1", "\(mainUUID)|@w72#2"])
        // And one that goes is still a change.
        let hidden = await snapshot(InventoryFixtures.desk(.init(concealed: [InventoryFixtures.notes])))
        #expect(ProbeContext.framedKeys(hidden) != ProbeContext.framedKeys(read))
        #expect(!ProbeContext.isRestored(before: read, now: hidden, running: read.apps.map { .fake($0.pid, $0.bundleID) }))
    }
}
