import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The display whose bar the apps' own frames are on is the active one: the read says which.
@Suite("Active display", .timeLimit(.minutes(1)))
struct ActiveDisplayTests {
    private func read(_ fixture: InventoryFixtures.Fixture, concealed: Bool = false, notVoting: Set<String> = []) async -> Inventory {
        let reader = MenuBarReader(ax: fixture.ax, runningApps: { fixture.running }, clock: FakeClock())
        let snapshot = await reader.snapshot(layout: fixture.layout)
        var memory = IndexMemory()
        var input = snapshot.matchInput(ownBundleID: InventoryFixtures.ownBundleID)
        if concealed {
            input.concealedApps = Set(fixture.running.compactMap(\.bundleID))
        }
        input.notVoting = notVoting
        return InventoryMatcher.match(input, memory: &memory)
    }

    @Test func theBarThatHoldsTheAppsFramesIsActive() async throws {
        let first = await read(InventoryFixtures.desk(.init(listingDisplay: 0)))
        let second = await read(InventoryFixtures.desk(.init(listingDisplay: 1)))
        let layout = InventoryFixtures.desk().layout
        #expect(first.activeDisplay == layout.displays[0].uuid)
        #expect(second.activeDisplay == layout.displays[1].uuid)
    }

    @Test func aSingleBarIsTheActiveOne() async throws {
        let inventory = await read(InventoryFixtures.laptop())
        #expect(inventory.activeDisplay == InventoryFixtures.laptop().layout.displays[0].uuid)
    }

    @Test func noActiveDisplayWhenNoAppHasAFrameOnABar() async throws {
        // Every app is concealed, so what they report says nothing of where the key window is.
        let inventory = await read(InventoryFixtures.desk(), concealed: true)
        #expect(inventory.activeDisplay == nil)
    }

    @Test func appsThatWereConcealedUnderThePlanBeforeDoNotVote() async throws {
        let fixture = InventoryFixtures.desk(.init(listingDisplay: 1))
        let layout = fixture.layout
        let apps = Set(fixture.running.compactMap(\.bundleID))
        // Some of them don't vote: the rest still say which display it is.
        let some = await read(fixture, notVoting: [InventoryFixtures.weather])
        #expect(some.activeDisplay == layout.displays[1].uuid)
        // None of them does (just revealed, and reporting where they were): it can't be told.
        let none = await read(fixture, notVoting: apps)
        #expect(none.activeDisplay == nil)
    }

    @Test func whichDisplayIsActiveIsNotWhatMakesAReadAnotherRead() {
        let bar = MenuBarGeometry(displayUUID: "one", rect: CGRect(x: 0, y: 0, width: 800, height: 30), notch: nil)
        func inventory(_ active: String?) -> Inventory {
            Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [bar], items: [], chevrons: [:], reach: [], problems: [], activeDisplay: active)
        }
        #expect(inventory("one") == inventory("two"), "only the key window moved: nothing new to publish")
        let other = Inventory(capturedAt: Date(timeIntervalSince1970: 1), bars: [bar], items: [], chevrons: [:], reach: [], problems: [])
        #expect(inventory("one") != other)
    }

    @Test func theActiveDisplaySurvivesBeingSaved() throws {
        let bar = MenuBarGeometry(displayUUID: "one", rect: CGRect(x: 0, y: 0, width: 800, height: 30), notch: nil)
        let inventory = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [bar], items: [], chevrons: [:], reach: [], problems: [],
                                  activeDisplay: "one")
        let copy = try JSONDecoder().decode(Inventory.self, from: try JSONEncoder().encode(inventory))
        #expect(copy.activeDisplay == "one")
        #expect(copy == inventory)
        // One saved before it was kept has none.
        let plain = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [bar], items: [], chevrons: [:], reach: [], problems: [])
        let old = try JSONDecoder().decode(Inventory.self, from: try JSONEncoder().encode(plain))
        #expect(old.activeDisplay == nil)
    }
}
