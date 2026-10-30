import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

private typealias Fixture = InventoryFixtures.Fixture

private let mainUUID = DisplayFixtures.deskMain.uuid
private let portraitUUID = DisplayFixtures.deskPortrait.uuid
private let laptopUUID = DisplayFixtures.laptopAlone.uuid

private func snapshot(of fixture: Fixture) async -> MenuBarSnapshot {
    let reader = MenuBarReader(ax: fixture.ax, runningApps: { fixture.running }, clock: FakeClock())
    return await reader.snapshot(layout: fixture.layout, includeRawTree: false)
}

private func inventory(of fixture: Fixture, memory: inout IndexMemory) async -> Inventory {
    let read = await snapshot(of: fixture)
    return InventoryMatcher.match(read.matchInput(ownBundleID: InventoryFixtures.ownBundleID), memory: &memory)
}

private func inventory(of fixture: Fixture) async -> Inventory {
    var memory = IndexMemory()
    return await inventory(of: fixture, memory: &memory)
}

/// The displays an item has a frame on.
private func displays(_ item: MenuBarItem?) -> Set<String> {
    Set(item?.frames.keys.map { $0 } ?? [])
}

private func item(_ id: String, in inventory: Inventory) -> MenuBarItem? {
    inventory.items.first { $0.id.string == id }
}

@Suite("Inventory matcher", .timeLimit(.minutes(1)))
struct InventoryMatcherTests {
    private let weatherTemp = "com.example.weather::weather.temp"
    private let weatherAlerts = "com.example.weather::weather.alerts"

    @Test func shuffledChildOrderGivesSameInventory() async {
        // MenuBarAgent lists a window's slots in an order of its own, different in every window and every read.
        let first = await inventory(of: InventoryFixtures.desk(.init(seed: 1)))
        let second = await inventory(of: InventoryFixtures.desk(.init(seed: 2)))
        let third = await inventory(of: InventoryFixtures.desk(.init(seed: 3)))
        #expect(first.items.count == 17)
        #expect(first == second)
        #expect(first == third)
    }

    @Test func tenWindowsGiveOneEntryPerItem() async throws {
        // Five Spaces on each of two displays: ten windows, and every item is still in the inventory once.
        let fixture = InventoryFixtures.desk(.init(windowsPerDisplay: 5))
        #expect(fixture.windows.map(\.count) == [5, 5])
        let inventory = await inventory(of: fixture)
        let ids = inventory.items.map(\.id)
        #expect(ids.count == Set(ids).count, "no item twice")
        // Ten of the apps' and seven of the system's.
        #expect(ids.filter(\.isSystem).count == 7)
        #expect(ids.filter { !$0.isSystem }.count == 10)
        #expect(inventory.bars.map(\.displayUUID) == [mainUUID, portraitUUID], "one bar for each display")
    }

    @Test func extrasInsetSixPointsMatchTheirSlot() async throws {
        let fixture = InventoryFixtures.desk()
        let read = await snapshot(of: fixture)
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(read.matchInput(ownBundleID: InventoryFixtures.ownBundleID), memory: &memory)

        // The weather app's first item is six points inside its slot: the item's frame is the slot's, not the app's.
        let weather = try #require(read.apps.first { $0.bundleID == InventoryFixtures.weather })
        let inside = try #require(weather.items.first { $0.identifier == "weather.temp" }?.frame)
        let temp = try #require(item(weatherTemp, in: inventory))
        let frame = try #require(temp.frames[mainUUID])
        #expect(frame == inside.insetBy(dx: -6, dy: -1))
        #expect(frame.contains(inside))
        #expect(frame.width > inside.width)
        // Every item of every app found its slot.
        for app in read.apps {
            for extra in app.items {
                let matched = inventory.items.filter { $0.ownerBundleID == app.bundleID }.contains { $0.frames[mainUUID]?.contains(extra.frame ?? .null) ?? false }
                #expect(matched, "\(app.bundleID ?? "") \(extra.index)")
            }
        }
    }

    @Test func aFrameIsMatchedByItsCenterAndNeedsToBeNoMuchWiderThanTheSlot() {
        let bar = CGRect(x: 0, y: 0, width: 1000, height: 30)
        func slot(_ x: CGFloat, width: CGFloat = 40) -> AgentSlot {
            AgentSlot(frame: CGRect(x: x, y: 0, width: width, height: 30), identifier: nil, role: "AXGroup", subrole: nil, description: nil,
                      ownerPID: nil, isOverflowChevron: false)
        }
        func app(_ frames: [CGRect]) -> AppExtras {
            AppExtras(pid: 7, bundleID: "com.example.app", name: "App",
                      items: frames.enumerated().map { ExtraItem(index: $0.offset, frame: $0.element, identifier: nil, title: nil, description: nil) },
                      timedOut: false)
        }
        func match(_ frames: [CGRect]) -> Inventory {
            var memory = IndexMemory()
            let input = MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .laptop,
                                   bars: [MatchBar(displayUUID: laptopUUID, rect: bar, slots: [slot(100), slot(300)])], apps: [app(frames)],
                                   ownBundleID: "com.example.mantel")
            return InventoryMatcher.match(input, memory: &memory)
        }
        // Six points in, the center is in the slot.
        #expect(match([CGRect(x: 106, y: 2, width: 28, height: 26)]).items.first?.isConcealed == false)
        // A center a point outside the slot's edge is still the slot's (the outset); ten points outside is nobody's.
        #expect(match([CGRect(x: 89, y: 2, width: 20, height: 26)]).items.first?.isConcealed == false)
        #expect(match([CGRect(x: 85, y: 2, width: 10, height: 26)]).items.first?.isConcealed == true)
        // A frame a few points wider than the slot is what the slot draws (real ones are 2 to 5 wider: 40 in 38, 91 in 89, 34 in 29);
        // one that is much wider is not.
        #expect(match([CGRect(x: 98, y: 2, width: 45, height: 26)]).items.first?.isConcealed == false)
        #expect(match([CGRect(x: 98, y: 2, width: 47, height: 26)]).items.first?.isConcealed == true)
        #expect(match([CGRect(x: 90, y: 2, width: 60, height: 26)]).items.first?.isConcealed == true)
        // One slot is one frame's.
        let two = match([CGRect(x: 106, y: 2, width: 28, height: 26), CGRect(x: 108, y: 2, width: 24, height: 26)])
        #expect(two.items.filter { !$0.isConcealed }.count == 1)
    }

    @Test func theFrameNearestASlotGetsItWhateverTheOrderOfTheApps() {
        // Two frames are in one slot: the one whose center is nearer the slot's is its, even when the other's app sorts first. (A frame
        // that was claimed first, by the order of the apps, took the slot from the icon that is drawn there.)
        let bar = MatchBar(displayUUID: mainUUID, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [
            AgentSlot(frame: CGRect(x: 100, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false),
            AgentSlot(frame: CGRect(x: 138, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false),
        ])
        func app(_ pid: pid_t, _ bundleID: String, _ x: CGFloat, width: CGFloat) -> AppExtras {
            AppExtras(pid: pid, bundleID: bundleID, name: nil,
                      items: [ExtraItem(index: 0, frame: CGRect(x: x, y: 2, width: width, height: 26), identifier: nil, title: nil, description: nil)],
                      timedOut: false)
        }
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(
            MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, bars: [bar],
                       apps: [app(1, "com.example.a", 124, width: 37), app(2, "com.example.b", 106, width: 24)], ownBundleID: "com.example.mantel"),
            memory: &memory)
        #expect(inventory.items(ofApp: "com.example.b").first?.frames[mainUUID]?.minX == 100, "the nearer frame has the slot")
        // The frame that lost has the next slot only if its center is in it: it is centered at 142.5, in the second slot.
        #expect(inventory.items(ofApp: "com.example.a").first?.frames[mainUUID]?.minX == 138)
        // Reversing the order the apps are given in changes nothing.
        var other = IndexMemory()
        let reversed = InventoryMatcher.match(
            MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, bars: [bar],
                       apps: [app(2, "com.example.b", 106, width: 24), app(1, "com.example.a", 124, width: 37)], ownBundleID: "com.example.mantel"),
            memory: &other)
        #expect(reversed.items.map { [$0.ownerBundleID: $0.frames[mainUUID]?.minX] } == inventory.items.map { [$0.ownerBundleID: $0.frames[mainUUID]?.minX] })
    }

    @Test func staleFrameDoesNotStealWonSlot() {
        // Two slots side by side, 100 to 138 and 138 to 176. The first is drawn by the notes app, whose frame is in it. A weather item that is
        // concealed reports a stale frame whose center is in the first slot, a point short of the second slot's edge: its outset reaches
        // the second slot, which no frame is in (nobody's icon is drawn there). It lost the first to the notes app's nearer frame, and it has
        // no slot: it doesn't take the neighbour's.
        let bar = MatchBar(displayUUID: mainUUID, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [
            AgentSlot(frame: CGRect(x: 100, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false),
            AgentSlot(frame: CGRect(x: 138, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false),
        ])
        func app(_ pid: pid_t, _ bundleID: String, _ x: CGFloat, width: CGFloat) -> AppExtras {
            AppExtras(pid: pid, bundleID: bundleID, name: nil,
                      items: [ExtraItem(index: 0, frame: CGRect(x: x, y: 2, width: width, height: 26), identifier: nil, title: nil, description: nil)],
                      timedOut: false)
        }
        // The notes app's frame is centered at 119, in the first slot; the stale one is centered at 137.5: in the first, 0.5 from its edge, and
        // within the outset of the second.
        let notes = app(1, "com.example.notes", 107, width: 24)
        let stale = app(2, "com.example.weather", 125.5, width: 24)
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(
            MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, bars: [bar], apps: [notes, stale], ownBundleID: "com.example.mantel"),
            memory: &memory)

        #expect(inventory.items(ofApp: "com.example.notes").first?.frames[mainUUID]?.minX == 100)
        #expect(inventory.items(ofApp: "com.example.weather").first?.frames[mainUUID] == nil, "it lost the slot it is in, and the next isn't its")
        // A frame that is in the second slot, as one that is drawn there, still has it.
        var other = IndexMemory()
        let drawn = InventoryMatcher.match(
            MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, bars: [bar],
                       apps: [notes, app(2, "com.example.weather", 144, width: 24)], ownBundleID: "com.example.mantel"), memory: &other)
        #expect(drawn.items(ofApp: "com.example.weather").first?.frames[mainUUID]?.minX == 138)
    }

    @Test func staleFrameOfAConcealedAppDoesNotStealWonSlot() {
        // The same bar and frames, and the weather app is one the plan conceals: its frames are believed last, after the notes app has won the
        // first slot (the group of apps that aren't concealed claims first). It lost that slot, and the neighbour's isn't its.
        let bar = MatchBar(displayUUID: mainUUID, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [
            AgentSlot(frame: CGRect(x: 100, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false),
            AgentSlot(frame: CGRect(x: 138, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false),
        ])
        func app(_ pid: pid_t, _ bundleID: String, _ x: CGFloat, width: CGFloat) -> AppExtras {
            AppExtras(pid: pid, bundleID: bundleID, name: nil,
                      items: [ExtraItem(index: 0, frame: CGRect(x: x, y: 2, width: width, height: 26), identifier: nil, title: nil, description: nil)],
                      timedOut: false)
        }
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(
            MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, bars: [bar],
                       apps: [app(1, "com.example.notes", 107, width: 24), app(2, "com.example.weather", 125.5, width: 24)],
                       ownBundleID: "com.example.mantel", concealedApps: ["com.example.weather"]),
            memory: &memory)

        #expect(inventory.items(ofApp: "com.example.notes").first?.frames[mainUUID]?.minX == 100)
        #expect(inventory.items(ofApp: "com.example.weather").first?.frames[mainUUID] == nil)
    }

    @Test func noAppFrameClaimsTheSlotOfASystemModule() {
        // An app that is hidden reports a place that is in Control Center's slot (and another in the clock's): the slots are the system's,
        // and are told by their names. The app's icon is none of them.
        let clock = AgentSlot(frame: CGRect(x: 800, y: 0, width: 125.5, height: 30), identifier: "com.apple.menuextra.clock", role: nil,
                              subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false)
        let control = AgentSlot(frame: CGRect(x: 760, y: 0, width: 26, height: 30), identifier: "com.apple.menuextra.controlcenter", role: nil,
                                subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false)
        let third = AgentSlot(frame: CGRect(x: 700, y: 0, width: 38, height: 30), identifier: nil, role: nil, subrole: nil, description: nil,
                              ownerPID: nil, isOverflowChevron: false)
        let bar = MatchBar(displayUUID: mainUUID, rect: CGRect(x: 0, y: 0, width: 1000, height: 30), slots: [third, control, clock])
        let host = AppExtras(pid: 3, bundleID: "com.example.aaa-host", name: nil, items: [
            ExtraItem(index: 0, frame: CGRect(x: 768, y: 2, width: 17, height: 24), identifier: nil, title: nil, description: nil),
            ExtraItem(index: 1, frame: CGRect(x: 850, y: 2, width: 24, height: 24), identifier: nil, title: nil, description: nil),
            ExtraItem(index: 2, frame: CGRect(x: 706, y: 2, width: 24, height: 24), identifier: nil, title: nil, description: nil),
        ], timedOut: false)
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, bars: [bar], apps: [host],
                                                          ownBundleID: "com.example.mantel"), memory: &memory)
        let controlCenter = item("system:controlcenter", in: inventory)
        #expect(controlCenter?.frames[mainUUID] == control.frame)
        #expect(item("system:clock", in: inventory)?.frames[mainUUID] == clock.frame)
        #expect(ClickReplayTargets.rects(in: inventory) == [clock.frame!], "the clock's click is still held where it is")
        // The app's own icon in the third slot is its; the two that lay in the system's slots are nobody's slot, and the app keeps them all.
        let items = inventory.items(ofApp: "com.example.aaa-host")
        #expect(items.count == 3)
        #expect(items.filter { $0.frames[mainUUID] != nil }.map { $0.frames[mainUUID]?.minX } == [700])
    }

    @Test func sameMenuBarOnAnotherMacGivesSameItemIDs() async {
        // Other process IDs, another order in which every window lists its slots, and one Space instead of five.
        let here = await inventory(of: InventoryFixtures.desk(.init(pidBase: 1000, windowsPerDisplay: 5, seed: 1)))
        let there = await inventory(of: InventoryFixtures.desk(.init(pidBase: 40_000, windowsPerDisplay: 1, seed: 99)))
        #expect(here.items.map(\.id) == there.items.map(\.id))
        #expect(here.items == there.items)
        // The text form of every ID is the same too: it is what a stored layout holds.
        #expect(here.items.map(\.id.string) == there.items.map(\.id.string))
    }

    @Test func namedItemsKeepTheirNamesAndUnnamedOnesAreToldByPlace() async {
        let inventory = await inventory(of: InventoryFixtures.desk())
        let ids = Set(inventory.items.map(\.id.string))
        #expect(ids.isSuperset(of: [weatherTemp, weatherAlerts, "com.example.mantel::mantel.dot.hidden",
                                    "com.example.mantel.testitem::mantel.fixture.one"]))
        // The notes app's one item has no name; the sync app's two have none and are told by where they are, from the left: the app
        // lists them right to left, so its second item is the first on the bar.
        #expect(ids.contains("com.example.notes#0"))
        #expect(ids.contains("com.example.sync#0"))
        #expect(ids.contains("com.example.sync#1"))
        #expect(item("com.example.sync#0", in: inventory)?.label == "Sync B")
        #expect(item("com.example.sync#1", in: inventory)?.label == "Sync A")
        let left = item("com.example.sync#0", in: inventory)?.frames[mainUUID]?.minX ?? 0
        let right = item("com.example.sync#1", in: inventory)?.frames[mainUUID]?.minX ?? 0
        #expect(left < right)
    }

    @Test func generatedNamesAreNotIdentity() async {
        // The VPN app's item is called _NS:93 by AppKit, and that name isn't what it is.
        let inventory = await inventory(of: InventoryFixtures.desk())
        #expect(item("com.example.vpn#0", in: inventory) != nil)
        #expect(!inventory.items.contains { $0.id.string.contains("_NS") })
        // Nor is it what ties one display's slot to another's (the same name could be another app's): its place is.
        #expect(displays(item("com.example.vpn#0", in: inventory)) == [mainUUID, portraitUUID])
    }

    @Test func concealedAppKeepsIndicesFromWhenVisible() async {
        var memory = IndexMemory()
        let shown = await inventory(of: InventoryFixtures.desk(), memory: &memory)
        let syncShown = shown.items(ofApp: InventoryFixtures.sync)
        #expect(syncShown.map(\.id.string) == ["com.example.sync#0", "com.example.sync#1"])
        #expect(syncShown.map(\.label) == ["Sync B", "Sync A"])

        // The same app, concealed: nothing says where its items are, and each keeps what it was.
        let concealed = await inventory(of: InventoryFixtures.desk(.init(concealed: [InventoryFixtures.sync])), memory: &memory)
        let syncHidden = concealed.items(ofApp: InventoryFixtures.sync)
        #expect(syncHidden.allSatisfy { $0.isConcealed })
        #expect(Set(syncHidden.map(\.id.string)) == ["com.example.sync#0", "com.example.sync#1"])
        #expect(syncHidden.first { $0.label == "Sync B" }?.id.string == "com.example.sync#0", "the item on the left is still the first")
        #expect(syncHidden.first { $0.label == "Sync A" }?.id.string == "com.example.sync#1")

        // An app never seen visible is told by the order its own list has: the first of its list is the first.
        var fresh = IndexMemory()
        let never = await inventory(of: InventoryFixtures.desk(.init(concealed: [InventoryFixtures.sync])), memory: &fresh)
        #expect(never.items(ofApp: InventoryFixtures.sync).first { $0.label == "Sync A" }?.id.string == "com.example.sync#0")
        #expect(never.items(ofApp: InventoryFixtures.sync).first { $0.label == "Sync B" }?.id.string == "com.example.sync#1")

        // Back again, they are as they were.
        let again = await inventory(of: InventoryFixtures.desk(), memory: &memory)
        #expect(again.items(ofApp: InventoryFixtures.sync).map(\.id.string) == ["com.example.sync#0", "com.example.sync#1"])
    }

    @Test func concealedFramesAreIgnored() async {
        // A concealed app's own frames are stale, at x = 7 and at x = -1, a dozen points above the bottom of the main display: on no bar.
        let fixture = InventoryFixtures.desk(.init(concealed: [InventoryFixtures.sync, InventoryFixtures.vpn]))
        let read = await snapshot(of: fixture)
        let stale = read.apps.filter { $0.bundleID == InventoryFixtures.sync || $0.bundleID == InventoryFixtures.vpn }.flatMap(\.items).compactMap(\.frame)
        #expect(Set(stale.map(\.minX)) == [7, -1])
        #expect(stale.allSatisfy { frame in fixture.bars.allSatisfy { frame.minY > $0.maxY || frame.maxX < $0.minX } }, "on no bar of any display")

        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(read.matchInput(ownBundleID: InventoryFixtures.ownBundleID), memory: &memory)
        for app in [InventoryFixtures.sync, InventoryFixtures.vpn] {
            let items = inventory.items(ofApp: app)
            #expect(!items.isEmpty)
            #expect(items.allSatisfy { $0.frames.isEmpty && $0.overflowedOn.isEmpty && $0.isConcealed }, "\(app)")
        }
        // Concealed items come after the ones on the bar, grouped by app; the others are where they were.
        let firstConcealed = inventory.items.firstIndex { $0.isConcealed }
        #expect(inventory.items[(firstConcealed ?? 0)...].allSatisfy { $0.isConcealed })
        #expect(inventory.items[(firstConcealed ?? 0)...].map(\.ownerBundleID) == [InventoryFixtures.sync, InventoryFixtures.sync, InventoryFixtures.vpn])
        #expect(item(weatherTemp, in: inventory)?.isConcealed == false)
    }

    @Test func aConcealedAppsStaleFrameLyingOnABarIsIgnored() async {
        // An app that is concealed can report the place it had on the bar, which no slot has any more. It isn't a place on the bar (nothing
        // is drawn there), and when the plan says the app is concealed it is not asked at all.
        let fixture = InventoryFixtures.desk(.init(concealed: [InventoryFixtures.sync, InventoryFixtures.vpn], concealedKeepTheirPlace: true))
        let read = await snapshot(of: fixture)
        let stale = read.apps.filter { $0.bundleID == InventoryFixtures.sync || $0.bundleID == InventoryFixtures.vpn }.flatMap(\.items).compactMap(\.frame)
        #expect(stale.count == 3)
        #expect(stale.allSatisfy { frame in fixture.bars.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } }, "each is on a bar")

        var input = read.matchInput(ownBundleID: InventoryFixtures.ownBundleID)
        input.concealedApps = [InventoryFixtures.sync, InventoryFixtures.vpn]
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input, memory: &memory)
        for app in [InventoryFixtures.sync, InventoryFixtures.vpn] {
            let items = inventory.items(ofApp: app)
            #expect(!items.isEmpty)
            #expect(items.allSatisfy { $0.frames.isEmpty && $0.overflowedOn.isEmpty && $0.isConcealed }, "\(app)")
        }
        // Everyone else is where they were.
        #expect(item(weatherTemp, in: inventory)?.frames.keys.sorted() == [mainUUID, portraitUUID].sorted())

        // Told nothing, the matcher takes the frame for a place on the bar that nothing draws.
        var told = IndexMemory()
        let without = InventoryMatcher.match(read.matchInput(ownBundleID: InventoryFixtures.ownBundleID), memory: &told)
        #expect(without.items(ofApp: InventoryFixtures.sync).allSatisfy { !$0.strayFrames.isEmpty })
    }

    @Test func systemSlotsBecomeSystemIDs() async throws {
        let inventory = await inventory(of: InventoryFixtures.desk())
        let modules = ["airdrop", "audiovideo", "sound", "wifi", "battery", "controlcenter", "clock"]
        for module in modules {
            let found = try #require(item("system:\(module)", in: inventory), "\(module)")
            #expect(found.id == ItemID.system(module))
            #expect(found.ownerBundleID == ItemID.systemBundleID)
            #expect(found.id.bundleID == ItemID.systemBundleID)
            #expect(found.appName == nil)
            #expect(!found.isMantel)
            // The same module is on every display, with its own frame there.
            #expect(Set(found.frames.keys) == [mainUUID, portraitUUID])
            #expect(found.frames[mainUUID] != found.frames[portraitUUID])
        }
        #expect(inventory.items.filter(\.id.isSystem).count == modules.count)
        // The clock is the right-most item on the main display.
        let clock = try #require(item("system:clock", in: inventory)?.frames[mainUUID])
        #expect(inventory.items.compactMap { $0.frames[mainUUID]?.minX }.max() == clock.minX)
    }

    @Test func mantelItemsAreMarked() async {
        let inventory = await inventory(of: InventoryFixtures.desk())
        let mantel = inventory.items(ofApp: InventoryFixtures.ownBundleID)
        #expect(mantel.map(\.id.string).sorted() == ["com.example.mantel::mantel.dot.always", "com.example.mantel::mantel.dot.hidden"])
        #expect(mantel.allSatisfy { $0.isMantel })
        // No one else's are: not the test item's, whose bundle ID only starts with Mantel's, and not the system's.
        #expect(inventory.items.filter(\.isMantel).count == 2)
        #expect(item("com.example.mantel.testitem::mantel.fixture.one", in: inventory)?.isMantel == false)
        #expect(!inventory.appsWithItems.contains(InventoryFixtures.ownBundleID))
        #expect(inventory.appsWithItems.contains(InventoryFixtures.testItemBundleID))
    }

    @Test func unmatchedSlotIsNotGuessed() async {
        // A slot that no app has a frame in, and that isn't a system item's, is left out, whatever it is called.
        let fixture = InventoryFixtures.desk()
        let read = await snapshot(of: fixture)
        var memory = IndexMemory()
        let input = read.matchInput(ownBundleID: InventoryFixtures.ownBundleID)
        let without = InventoryMatcher.matchCounting(input, memory: &memory)
        #expect(without.inventory.items.count == 17)
        #expect(without.unmatchedSlots == 0, "every slot of both displays is an item: the unnamed ones on the second display by their order")
        #expect(without.segmentsNotAligned == 0)

        var withGhost = input
        let ghost = AgentSlot(frame: CGRect(x: 100, y: 0, width: 40, height: 30), identifier: "com.example.weather.ghost", role: "AXGroup",
                              subrole: nil, description: nil, ownerPID: nil, isOverflowChevron: false)
        withGhost.bars[0] = MatchBar(displayUUID: input.bars[0].displayUUID, rect: input.bars[0].rect, slots: input.bars[0].slots + [ghost])
        let result = InventoryMatcher.matchCounting(withGhost, memory: &memory)
        #expect(result.inventory.items == without.inventory.items, "no item for it, and nothing else changed")
        #expect(result.unmatchedSlots == 1, "counted")
        // The stretch it is in has one slot more on the main display than on the portrait one, so that stretch isn't lined up.
        #expect(result.segmentsNotAligned == 1)
        #expect(result.inventory.untiedSlots[mainUUID] == [ghost.frame!])
    }

    /// The pieces of a hand-made menu bar: a slot, an app that lists one item at a frame, and a bar.
    private func slot(_ x: CGFloat, width: CGFloat = 40, name: String? = nil, frame: Bool = true, role: String = "AXGroup") -> AgentSlot {
        AgentSlot(frame: frame ? CGRect(x: x, y: 0, width: width, height: 30) : nil, identifier: name, role: role, subrole: nil,
                  description: nil, ownerPID: nil, isOverflowChevron: false)
    }

    private func app(_ pid: pid_t, _ bundleID: String, in slot: AgentSlot, identifier: String? = nil) -> AppExtras {
        let frame = slot.frame?.insetBy(dx: 6, dy: 1)
        return AppExtras(pid: pid, bundleID: bundleID, name: nil,
                         items: [ExtraItem(index: 0, frame: frame, identifier: identifier, title: nil, description: nil)], timedOut: false)
    }

    private func input(_ bars: [MatchBar], apps: [AppExtras], layout: DisplayLayout = .desk, reach: [AppReach] = []) -> MatchInput {
        MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: layout, bars: bars, apps: apps, ownBundleID: "com.example.mantel", reach: reach)
    }

    private func mainBar(_ slots: [AgentSlot]) -> MatchBar {
        MatchBar(displayUUID: mainUUID, rect: CGRect(x: 0, y: 0, width: 3360, height: 30), slots: slots)
    }

    private func portraitBar(_ slots: [AgentSlot]) -> MatchBar {
        MatchBar(displayUUID: portraitUUID, rect: CGRect(x: -1800, y: -491, width: 1800, height: 30), slots: slots)
    }

    @Test func aSlotNameTwoAppsShareTiesNothing() {
        // AppKit gives each app's first item the same name ("Item-0"), so on another display it says nothing of whose the slot is.
        // The slots of the portrait display are wider, so that they can't be lined up either: nothing says whose they are.
        let main = mainBar([slot(100, name: "Item-0"), slot(200, name: "Item-0"), slot(300, name: "Item-1")])
        let portrait = portraitBar([slot(-500, width: 50, name: "Item-0"), slot(-400, width: 50, name: "Item-0"), slot(-300, width: 50, name: "Item-1")])
        let apps = [app(1, "com.example.one", in: main.slots[0], identifier: "Item-0"), app(2, "com.example.two", in: main.slots[1], identifier: "Item-0"),
                    app(3, "com.example.three", in: main.slots[2], identifier: "Item-1")]
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input([main, portrait], apps: apps), memory: &memory)
        let inventory = result.inventory
        // The name only one app's slot has is its on both displays; the one two apps share is on the display the apps list it on, only.
        #expect(displays(inventory.items(ofApp: "com.example.three").first) == [mainUUID, portraitUUID])
        #expect(inventory.items(ofApp: "com.example.one").first?.frames.keys.sorted() == [mainUUID])
        #expect(inventory.items(ofApp: "com.example.two").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.segmentsNotAligned == 1, "the two slots with the shared name, which are wider")
    }

    @Test func aNameThatIsOnABarTwiceTiesNothing() {
        // The portrait display has "Item-0" twice. One of them could be the app's, and which isn't said: neither is tied (and as the
        // main display has one slot and the portrait one two, they can't be lined up either).
        let main = mainBar([slot(300, name: "Item-0")])
        let portrait = portraitBar([slot(-500, name: "Item-0"), slot(-400, name: "Item-0")])
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input([main, portrait], apps: [app(1, "com.example.one", in: main.slots[0])]), memory: &memory)
        #expect(inventory.items(ofApp: "com.example.one").first?.frames.keys.sorted() == [mainUUID])
        #expect(inventory.untiedSlots[portraitUUID]?.count == 2)
    }

    @Test func theSameItemOnEveryDisplayHasAFramePerDisplay() async throws {
        let inventory = await inventory(of: InventoryFixtures.desk())
        let temp = try #require(item(weatherTemp, in: inventory))
        #expect(Set(temp.frames.keys) == [mainUUID, portraitUUID])
        #expect(temp.frames[mainUUID] != temp.frames[portraitUUID], "never one frame for two displays")
        // The side display's bar is as wide as the display, the item sits at its right.
        let onPortrait = try #require(temp.frames[portraitUUID])
        #expect(onPortrait.maxX < 0)
        // The items with no name of their own are on the other display by their place there (`unnamedItemsAlignAcrossDisplaysByOrder`).
        #expect(displays(item("com.example.notes#0", in: inventory)) == [mainUUID, portraitUUID])
    }

    @Test func overflowIsPerDisplay() async throws {
        // The desk with the lid open: the laptop's bar is full (its items are piled at the «, and the notch is in the way) and the
        // other two have room. An item that is overflowed on the laptop is not on the others.
        let inventory = await inventory(of: InventoryFixtures.deskWithLaptopOpen())
        let temp = try #require(item(weatherTemp, in: inventory))
        #expect(Set(temp.frames.keys) == [mainUUID, portraitUUID, laptopUUID])
        #expect(temp.overflowedOn == [laptopUUID])
        #expect(temp.isOverflowed)
        // The items with no name are in the laptop's overflow too: told by their order, with nothing on the laptop's bar to say so.
        let notes = try #require(item("com.example.notes#0", in: inventory))
        #expect(notes.overflowedOn == [laptopUUID])
        #expect(Set(notes.frames.keys) == [mainUUID, portraitUUID], "no frame on the laptop: its slot is somewhere in the pile")
        #expect(inventory.items.filter { !$0.id.isSystem }.allSatisfy { $0.overflowedOn == [laptopUUID] })
        let clock = try #require(item("system:clock", in: inventory))
        #expect(clock.overflowedOn.isEmpty && !clock.isOverflowed)
        #expect(Set(clock.frames.keys) == [mainUUID, portraitUUID, laptopUUID])
        // The bars are the agent's windows: 33 points on the laptop.
        #expect(inventory.bars.map(\.height) == [30, 30, 33])
        #expect(inventory.chevrons.keys.sorted() == [laptopUUID])
    }

    @Test func piledSlotsOfTheLaptopAreEachAnItemAndOverflowed() async throws {
        let fixture = InventoryFixtures.laptop()
        let inventory = await inventory(of: fixture)
        let piled = inventory.items.filter(\.isOverflowed)
        #expect(piled.count == 8, "eight items at the «")
        #expect(piled.allSatisfy { $0.overflowedOn == [laptopUUID] })
        #expect(Set(piled.compactMap { $0.frames[laptopUUID]?.minX }).count == 8, "each at a place of its own")
        #expect(piled.compactMap { $0.frames[laptopUUID]?.minX }.allSatisfy { $0 >= 958 && $0 <= 967 })
        // The system items right of the « are not.
        #expect(inventory.items.filter(\.id.isSystem).allSatisfy { !$0.isOverflowed })
        // The « is a slot but not an item: it is where it is, and no item is made of it.
        #expect(inventory.chevrons[laptopUUID] == CGRect(x: 979, y: 1, width: 17.5, height: 30))
        #expect(inventory.items.count == 8 + 7)
        #expect(inventory.bars == [MenuBarGeometry(displayUUID: laptopUUID, rect: CGRect(x: 0, y: 0, width: 1728, height: 33),
                                                   notch: CGRect(x: 771.5, y: 0, width: 185, height: 32))])
    }

    @Test func itemsAreInOrderByXOnTheMainDisplay() async {
        let inventory = await inventory(of: InventoryFixtures.desk())
        let onMain = inventory.items.compactMap { $0.frames[mainUUID]?.minX }
        #expect(onMain == onMain.sorted())
        #expect(onMain.count == 17)
        #expect(inventory.items.first?.id.string == weatherTemp)
        #expect(inventory.items.last?.id.string == "system:clock")
    }

    @Test func aSlotLeftWithoutAFrameIsAConcealedItemOfItsOwn() {
        // A system item macOS has no frame for, on every display, isn't drawn: it is concealed, and not in anyone's overflow.
        let battery = slot(0, name: "com.apple.menuextra.battery", frame: false)
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input([mainBar([battery])], apps: []), memory: &memory)
        #expect(inventory.items.map(\.id) == [ItemID.system("battery")])
        #expect(inventory.items.first?.isConcealed == true)
        #expect(inventory.items.first?.overflowedOn == [])
        #expect(inventory.untiedSlots.isEmpty)
    }

    @Test func concealedSystemItemIsNotOverflowed() {
        // AirDrop under any assertion, or a module hidden through the system's own switch: its slot has no frame on any display.
        let airdrop = "com.apple.menuextra.airdrop"
        let clock = "com.apple.menuextra.clock"
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(
            input([mainBar([slot(3000, name: airdrop, frame: false), slot(3300, width: 50, name: clock)]),
                   portraitBar([slot(-100, name: airdrop, frame: false), slot(-60, width: 50, name: clock)])], apps: []), memory: &memory)
        let concealed = inventory.items.first { $0.id == ItemID.system("airdrop") }
        #expect(concealed?.isConcealed == true)
        #expect(concealed?.overflowedOn == [], "framed nowhere: not drawn, which isn't being in the overflow")
        #expect(concealed?.isOverflowed == false)
        #expect(inventory.items.first { $0.id == ItemID.system("clock") }?.overflowedOn == [])
    }

    @Test func framelessOnOneDisplayButFramedOnAnotherIsOverflowedThere() {
        // The same item has a frame on the main display and none on the portrait one: macOS has put it in the overflow there.
        let battery = "com.apple.menuextra.battery"
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(
            input([mainBar([slot(3000, name: battery)]), portraitBar([slot(-100, name: battery, frame: false)])], apps: []), memory: &memory)
        let item = inventory.items.first { $0.id == ItemID.system("battery") }
        #expect(displays(item) == [mainUUID])
        #expect(item?.overflowedOn == [portraitUUID])
        #expect(item?.isConcealed == false)
        #expect(item?.isOverflowed == true)
    }

    @Test func anAppItemFramedNowhereIsConcealedNotOverflowed() {
        // An app's item that no slot of any display has a frame in: its slots (nameless, so not tied to it anyway) don't make it
        // overflowed; it is concealed.
        let stale = AppExtras(pid: 1, bundleID: "com.example.one", name: nil,
                              items: [ExtraItem(index: 0, frame: CGRect(x: 7, y: 0, width: 24, height: 30), identifier: nil, title: nil, description: nil)],
                              timedOut: false)
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input([mainBar([slot(100, frame: false)]), portraitBar([slot(-500, frame: false)])], apps: [stale]),
                                               memory: &memory)
        let item = inventory.items(ofApp: "com.example.one").first
        #expect(item?.isConcealed == true)
        #expect(item?.overflowedOn == [])
    }

    @Test func inventoryHelpers() async {
        let inventory = await inventory(of: InventoryFixtures.desk())
        #expect(inventory.appsWithItems == [InventoryFixtures.weather, InventoryFixtures.notes, InventoryFixtures.vpn, InventoryFixtures.sync,
                                            InventoryFixtures.testItemBundleID])
        #expect(inventory.items(ofApp: InventoryFixtures.weather).count == 2)
        #expect(inventory.agentAnswered)
        #expect(Inventory.empty.items.isEmpty && Inventory.empty.bars.isEmpty)
        #expect(!Inventory(capturedAt: .now, bars: [], items: [], chevrons: [:], reach: [], problems: [.agentNotRunning]).agentAnswered)
        #expect(!Inventory(capturedAt: .now, bars: [], items: [], chevrons: [:], reach: [], problems: [.agentHasNoWindows]).agentAnswered)
        #expect(Inventory(capturedAt: .now, bars: [], items: [], chevrons: [:], reach: [], problems: [.accessibilityNotGranted]).agentAnswered)
    }

    @Test func anInventoryRoundTripsThroughJSON() async throws {
        let inventory = await inventory(of: InventoryFixtures.deskWithLaptopOpen())
        let data = try JSONEncoder().encode(inventory)
        #expect(try JSONDecoder().decode(Inventory.self, from: data) == inventory)
        // The IDs are their text in it.
        #expect(String(decoding: data, as: UTF8.self).contains("\"system:clock\""))
    }

    // MARK: Lining up the displays

    @Test func unnamedItemsAlignAcrossDisplaysByOrder() async {
        // The notes app's item, the VPN's (whose name is AppKit's) and the sync app's two have no name on any slot. The apps list them on
        // the main display; on the portrait one they are told by where they are in the order, between the items that are known there.
        for stripped in [false, true] {
            let inventory = await inventory(of: InventoryFixtures.desk(.init(stripThirdPartyNames: stripped)))
            let ids = ["com.example.notes#0", "com.example.vpn#0", "com.example.sync#0", "com.example.sync#1"]
            for id in ids {
                #expect(displays(item(id, in: inventory)) == [mainUUID, portraitUUID], "\(id), names stripped: \(stripped)")
            }
            // On the portrait display they are in the order they are on the main one, and as wide.
            let onPortrait = ids.compactMap { item($0, in: inventory)?.frames[portraitUUID] }
            let onMain = ids.compactMap { item($0, in: inventory)?.frames[mainUUID] }
            #expect(onPortrait.map(\.minX) == onPortrait.map(\.minX).sorted())
            #expect(onPortrait.map(\.width) == onMain.map(\.width))
            #expect(inventory.items.allSatisfy { Set($0.frames.keys) == [mainUUID, portraitUUID] })
            #expect(inventory.untiedSlots.isEmpty)
        }
    }

    /// Main: A (named "a"), two unnamed apps' items, B (named "b"); portrait: the same with `portraitMiddle` between its A and B.
    private func twoBarsWithAMiddle(portraitMiddle: [AgentSlot]) -> (MatchInput, [AgentSlot]) {
        let main = mainBar([slot(100, name: "a"), slot(200), slot(300), slot(400, name: "b")])
        let portrait = portraitBar([slot(-900, name: "a")] + portraitMiddle + [slot(-500, name: "b")])
        let apps = [app(1, "com.example.a", in: main.slots[0], identifier: "a"), app(2, "com.example.one", in: main.slots[1]),
                    app(3, "com.example.two", in: main.slots[2]), app(4, "com.example.b", in: main.slots[3], identifier: "b")]
        return (input([main, portrait], apps: apps), portraitMiddle)
    }

    @Test func alignmentRefusesWhenCountsDiffer() {
        let (input, middle) = twoBarsWithAMiddle(portraitMiddle: [slot(-800)])
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input, memory: &memory)
        // Two unnamed on one display and one on the other: which of them is missing isn't said, so neither is tied.
        #expect(result.inventory.items(ofApp: "com.example.one").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.inventory.items(ofApp: "com.example.two").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.segmentsNotAligned == 1)
        #expect(result.inventory.untiedSlots[portraitUUID] == middle.compactMap(\.frame))
        // The ones that are named are still on both.
        #expect(displays(result.inventory.items(ofApp: "com.example.a").first) == [mainUUID, portraitUUID])
    }

    @Test func alignmentRefusesWhenWidthsDiffer() {
        // As many on each, but not as wide: they aren't the same items.
        let (input, middle) = twoBarsWithAMiddle(portraitMiddle: [slot(-800), slot(-700, width: 60)])
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input, memory: &memory)
        #expect(result.inventory.items(ofApp: "com.example.one").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.inventory.items(ofApp: "com.example.two").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.segmentsNotAligned == 1)
        #expect(result.inventory.untiedSlots[portraitUUID]?.count == middle.count)

        // Within a point is the same width.
        let (near, _) = twoBarsWithAMiddle(portraitMiddle: [slot(-800, width: 40.5), slot(-700, width: 39.5)])
        var again = IndexMemory()
        let aligned = InventoryMatcher.matchCounting(near, memory: &again)
        #expect(aligned.segmentsNotAligned == 0)
        #expect(displays(aligned.inventory.items(ofApp: "com.example.one").first) == [mainUUID, portraitUUID])
        #expect(displays(aligned.inventory.items(ofApp: "com.example.two").first) == [mainUUID, portraitUUID])
        // And in the order they are in.
        #expect(aligned.inventory.items(ofApp: "com.example.one").first?.frames[portraitUUID]?.minX == -800)
        #expect(aligned.inventory.items(ofApp: "com.example.two").first?.frames[portraitUUID]?.minX == -700)
    }

    @Test func oneDisplayWithAnExtraItemRefusesOnlyThatSegment() {
        // The portrait display has an item more between A and B. The stretch between B and C is the same on both and is lined up.
        let main = mainBar([slot(100, name: "a"), slot(200), slot(300), slot(400, name: "b"), slot(500), slot(600, name: "c")])
        let portrait = portraitBar([slot(-900, name: "a"), slot(-800), slot(-700), slot(-600), slot(-500, name: "b"), slot(-400), slot(-300, name: "c")])
        let apps = [app(1, "com.example.a", in: main.slots[0], identifier: "a"), app(2, "com.example.one", in: main.slots[1]),
                    app(3, "com.example.two", in: main.slots[2]), app(4, "com.example.b", in: main.slots[3], identifier: "b"),
                    app(5, "com.example.three", in: main.slots[4]), app(6, "com.example.c", in: main.slots[5], identifier: "c")]
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input([main, portrait], apps: apps), memory: &memory)
        #expect(result.segmentsNotAligned == 1)
        #expect(result.inventory.items(ofApp: "com.example.one").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.inventory.items(ofApp: "com.example.two").first?.frames.keys.sorted() == [mainUUID])
        #expect(displays(result.inventory.items(ofApp: "com.example.three").first) == [mainUUID, portraitUUID])
        #expect(result.inventory.items(ofApp: "com.example.three").first?.frames[portraitUUID]?.minX == -400)
        #expect(result.inventory.untiedSlots[portraitUUID]?.count == 3, "the three slots between A and B")
    }

    @Test func overflowedPileOnNotchBarIsTheReferenceItemsLeftOfTheAlignedOnes() async throws {
        // The laptop's bar is full: seven of the ten third-party items are piled at the «, and three are shown right of it. No slot has
        // a name. The three shown are lined up with the last three of the main display's; the first seven are in the overflow, as many
        // as there are piled slots, and that is all that is known of them.
        let fixture = InventoryFixtures.deskWithLaptopOpen(.init(stripThirdPartyNames: true, visibleOnPileBar: 3))
        let inventory = await inventory(of: fixture)
        let thirdParty = inventory.items.filter { !$0.id.isSystem }
        #expect(thirdParty.count == 10)
        let shown = thirdParty.filter { $0.frames[laptopUUID] != nil }
        let piled = thirdParty.filter { $0.frames[laptopUUID] == nil }
        #expect(shown.count == 3)
        #expect(piled.count == 7)
        #expect(piled.allSatisfy { $0.overflowedOn == [laptopUUID] })
        #expect(shown.allSatisfy { $0.overflowedOn.isEmpty }, "shown: right of the «")
        // The shown are the right-most of the main display's, in order.
        let byMainX = thirdParty.sorted { ($0.frames[mainUUID]?.minX ?? 0) < ($1.frames[mainUUID]?.minX ?? 0) }
        #expect(Set(byMainX.suffix(3).map(\.id)) == Set(shown.map(\.id)))
        #expect(Set(byMainX.prefix(7).map(\.id)) == Set(piled.map(\.id)))
        let chevron = try #require(inventory.chevrons[laptopUUID])
        #expect(shown.allSatisfy { ($0.frames[laptopUUID]?.minX ?? 0) > chevron.maxX })
        // Every item is on the main and the portrait display, whatever the laptop shows.
        #expect(thirdParty.allSatisfy { Set($0.frames.keys).isSuperset(of: [mainUUID, portraitUUID]) })
    }

    @Test func overflowIsRefusedWhenTheCountsOfThePileDoNotMatch() async {
        // One piled slot too many: the reference's items left of the aligned ones are not as many as the pile, so none is marked.
        let fixture = InventoryFixtures.deskWithLaptopOpen(.init(stripThirdPartyNames: true, visibleOnPileBar: 3))
        let read = await snapshot(of: fixture)
        var input = read.matchInput(ownBundleID: InventoryFixtures.ownBundleID)
        let laptop = input.bars.count - 1
        input.bars[laptop] = MatchBar(displayUUID: input.bars[laptop].displayUUID, rect: input.bars[laptop].rect,
                                      slots: input.bars[laptop].slots + [AgentSlot(frame: CGRect(x: 3360 + 962, y: 1, width: 24, height: 30),
                                                                                   identifier: nil, role: "AXGroup", subrole: nil, description: nil,
                                                                                   ownerPID: nil, isOverflowChevron: false)])
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input, memory: &memory)
        #expect(result.segmentsNotAligned >= 1)
        #expect(result.inventory.items.filter { !$0.id.isSystem }.allSatisfy { $0.overflowedOn.isEmpty })
        #expect(result.inventory.items.filter { !$0.id.isSystem && $0.frames[laptopUUID] != nil }.isEmpty, "nothing was tied there either")
    }

    @Test func accountedPileSlotsAreNotUntied() async throws {
        // The laptop's bar is full: seven of the ten third-party items are piled at the « and three are shown right of it, and no
        // slot has a name. The three shown are lined up with the main display's last three, and the seven piled slots are the other
        // seven's: all that is known of them is how many there are, and that is said (they are overflowed). They are accounted for, so
        // they are not slots that nobody claimed.
        let fixture = InventoryFixtures.deskWithLaptopOpen(.init(stripThirdPartyNames: true, visibleOnPileBar: 3))
        let read = await snapshot(of: fixture)
        let input = read.matchInput(ownBundleID: InventoryFixtures.ownBundleID)
        var memory = IndexMemory()
        let accounted = InventoryMatcher.matchCounting(input, memory: &memory)
        #expect(accounted.segmentsNotAligned == 0)
        #expect(accounted.unmatchedSlots == 0)
        #expect(accounted.inventory.untiedSlots.isEmpty)
        #expect(accounted.inventory.items.filter { $0.overflowedOn == [laptopUUID] }.count == 7, "and the items they hold are said to be in the overflow")

        // One piled slot too many: the pile isn't what the main display's items say it is, so nothing is accounted for. The three
        // shown are not lined up either, and all eleven slots of the laptop are said to be nobody's.
        var mismatched = input
        let laptop = mismatched.bars.count - 1
        mismatched.bars[laptop] = MatchBar(displayUUID: mismatched.bars[laptop].displayUUID, rect: mismatched.bars[laptop].rect,
                                           slots: mismatched.bars[laptop].slots + [slot(3360 + 962, width: 24)])
        var again = IndexMemory()
        let refused = InventoryMatcher.matchCounting(mismatched, memory: &again)
        #expect(refused.segmentsNotAligned >= 1)
        #expect(refused.unmatchedSlots == 11)
        #expect(refused.inventory.untiedSlots[laptopUUID]?.count == 11)
    }

    @Test func pileItemInsidePairedSuffixRefusesTheStretch() {
        // The main display shows two unnamed items and AirDrop, then the clock. On the portrait display AirDrop is in the overflow (its
        // slot has no frame) and the two items are shown, so the portrait display's two shown slots are the two items. Taking the
        // right-most two of each as the same would pair the first item with the second one's slot and AirDrop with the other: AirDrop
        // is known to be in the pile there, so it can't be among those lined up, and nothing is tied.
        let airdrop = "com.apple.menuextra.airdrop"
        let clock = "com.apple.menuextra.clock"
        let main = mainBar([slot(100), slot(200), slot(300, name: airdrop), slot(3300, width: 50, name: clock)])
        let portrait = portraitBar([slot(-900), slot(-800), slot(-700, name: airdrop, frame: false), slot(-60, width: 50, name: clock)])
        let apps = [app(1, "com.example.one", in: main.slots[0]), app(2, "com.example.two", in: main.slots[1])]
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input([main, portrait], apps: apps), memory: &memory)
        #expect(result.segmentsNotAligned == 1)
        #expect(result.inventory.items(ofApp: "com.example.one").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.inventory.items(ofApp: "com.example.two").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.inventory.untiedSlots[portraitUUID]?.count == 2, "the two slots that were not lined up are said to be nobody's")
        #expect(result.unmatchedSlots == 2)

        // AirDrop in the part that is left over (the main display's first slot, not one of its last two) says nothing against it: the
        // two items are lined up, and the pile's slot is accounted for.
        let leftOver = mainBar([slot(50, name: airdrop), slot(100), slot(200), slot(3300, width: 50, name: clock)])
        let apps2 = [app(1, "com.example.one", in: leftOver.slots[1]), app(2, "com.example.two", in: leftOver.slots[2])]
        var other = IndexMemory()
        let lined = InventoryMatcher.matchCounting(input([leftOver, portrait], apps: apps2), memory: &other)
        #expect(lined.segmentsNotAligned == 0)
        #expect(lined.inventory.items(ofApp: "com.example.one").first?.frames[portraitUUID]?.minX == -900)
        #expect(lined.inventory.items(ofApp: "com.example.two").first?.frames[portraitUUID]?.minX == -800)
        #expect(lined.unmatchedSlots == 0)
    }

    @Test func skippedTieRefusesTheStretch() {
        // The portrait display has item E before item A1, where the main display has it after. The longest run of items that are in
        // the same order leaves E out, and the stretch between A1 and A2 holds E on the main display and two slots on the portrait
        // one. Pairing them would tie the first of those slots to E, which the portrait display already has a slot for (the one
        // named "e"): that can't be done, so the stretch isn't lined up at all, and nothing else in it is tied (not the item
        // after E either).
        let main = mainBar([slot(100, name: "a1"), slot(200, name: "e"), slot(300), slot(400, name: "a2"), slot(500, name: "f")])
        let portrait = portraitBar([slot(-900, name: "e"), slot(-800, name: "a1"), slot(-700), slot(-600), slot(-500, name: "a2"), slot(-400, name: "f")])
        let apps = [app(1, "com.example.a1", in: main.slots[0], identifier: "a1"), app(2, "com.example.e", in: main.slots[1], identifier: "e"),
                    app(3, "com.example.u", in: main.slots[2]), app(4, "com.example.a2", in: main.slots[3], identifier: "a2"),
                    app(5, "com.example.f", in: main.slots[4], identifier: "f")]
        var memory = IndexMemory()
        let result = InventoryMatcher.matchCounting(input([main, portrait], apps: apps), memory: &memory)
        #expect(result.segmentsNotAligned == 2, "the stretch before A1, which has a slot more on the portrait display, and the one between A1 and A2")
        #expect(result.inventory.items(ofApp: "com.example.u").first?.frames.keys.sorted() == [mainUUID])
        #expect(result.inventory.items(ofApp: "com.example.e").first?.frames[portraitUUID]?.minX == -900, "E keeps the slot it has")
        #expect(result.inventory.untiedSlots[portraitUUID]?.count == 2)
        // The ones that are named are on both displays all the same.
        #expect(displays(result.inventory.items(ofApp: "com.example.a2").first) == [mainUUID, portraitUUID])
        #expect(displays(result.inventory.items(ofApp: "com.example.f").first) == [mainUUID, portraitUUID])
    }

    @Test func appsReportingFramesOnTheSecondDisplayAreStillAligned() async {
        // The apps list their items on the portrait display, not the main one: that is the reference then, and the main display's slots
        // are lined up with it. The result is the one there is when the apps list them on the main display.
        let onMain = await inventory(of: InventoryFixtures.desk(.init(stripThirdPartyNames: true, listingDisplay: 0)))
        let onPortrait = await inventory(of: InventoryFixtures.desk(.init(stripThirdPartyNames: true, listingDisplay: 1)))
        #expect(onPortrait.items.count == 17)
        #expect(onPortrait.items.allSatisfy { Set($0.frames.keys) == [mainUUID, portraitUUID] })
        #expect(onPortrait.untiedSlots.isEmpty)
        #expect(onPortrait.items == onMain.items)
    }

    @Test func untiedSlotsAreReportedPerDisplay() {
        // The slots that have a frame and that no item has: not the «, not a system item's, not one an app has, not one with no frame.
        let chevron = slot(10, width: 20, role: "AXButton")
        let ghost = slot(200)
        let clock = slot(3300, width: 50, name: "com.apple.menuextra.clock")
        let main = mainBar([chevron, slot(100), ghost, clock, slot(400, frame: false)])
        let portrait = portraitBar([slot(-1700, width: 20, role: "AXButton"), slot(-500), slot(-400), slot(-800, frame: false),
                                      slot(-60, width: 50, name: "com.apple.menuextra.clock")])
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(input([main, portrait], apps: [app(1, "com.example.one", in: main.slots[1])]), memory: &memory)
        // The app's item is the first of the two slots on both displays; the second is nobody's.
        #expect(inventory.untiedSlots[mainUUID] == [ghost.frame!])
        #expect(inventory.untiedSlots[portraitUUID] == [CGRect(x: -400, y: 0, width: 40, height: 30)])
        #expect(displays(inventory.items(ofApp: "com.example.one").first) == [mainUUID, portraitUUID])
        // A menu bar with nothing left over has none.
        var other = IndexMemory()
        let clean = InventoryMatcher.match(input([mainBar([slot(100)])], apps: [app(1, "com.example.one", in: slot(100))]), memory: &other)
        #expect(clean.untiedSlots.isEmpty)
    }

    @Test func anAppsOwnIdentifierLosesItsLayoutPrefixToo() {
        // The layout names an item `<bundle ID>::<name>`; an app that reports its identifier that way is the same item as one that
        // reports the name alone, and its ID doesn't have the bundle ID in it twice.
        let bar = mainBar([slot(100)])
        func idOfItem(identifier: String) -> String? {
            var memory = IndexMemory()
            let inventory = InventoryMatcher.match(input([bar], apps: [app(1, "com.example.one", in: bar.slots[0], identifier: identifier)]), memory: &memory)
            return inventory.items(ofApp: "com.example.one").first?.id.string
        }
        #expect(idOfItem(identifier: "item.main") == "com.example.one::item.main")
        #expect(idOfItem(identifier: "com.example.one::item.main") == "com.example.one::item.main")
        #expect(idOfItem(identifier: "com.example.two::item.main") == "com.example.one::com.example.two::item.main", "another app's prefix is a name")
    }

    @Test func unansweredAppsComeFromTheReach() {
        var memory = IndexMemory()
        let reach = [AppReach(bundleID: "com.example.hung", name: nil, status: .timedOut, readMs: 250),
                     AppReach(bundleID: "com.example.left", name: nil, status: .skipped, readMs: 0),
                     AppReach(bundleID: "com.example.slow", name: nil, status: .slow, readMs: 150),
                     AppReach(bundleID: "com.example.fine", name: nil, status: .fine, readMs: 5)]
        let inventory = InventoryMatcher.match(input([mainBar([slot(100)])], apps: [], reach: reach), memory: &memory)
        #expect(inventory.unansweredApps == ["com.example.hung", "com.example.left"])
    }

    @Test func emptyBundleIDsAreFiltered() {
        // An app with no bundle ID, or an empty one, can't be told from another that has none: it is nobody's items.
        var memory = IndexMemory()
        let bar = mainBar([slot(100), slot(200), slot(300)])
        let nothing = AppExtras(pid: 3, bundleID: nil, name: nil,
                                items: [ExtraItem(index: 0, frame: slot(300).frame?.insetBy(dx: 6, dy: 1), identifier: nil, title: nil, description: nil)],
                                timedOut: false)

        let result = InventoryMatcher.matchCounting(input([bar], apps: [app(1, "", in: slot(100)), app(2, "com.example.two", in: slot(200)), nothing]),
                                                    memory: &memory)

        #expect(result.inventory.items.map(\.ownerBundleID).filter { $0 != "" } == ["com.example.two"])
        #expect(!result.inventory.items.contains { $0.ownerBundleID.isEmpty }, "no item is the empty app's")
        #expect(result.listed.keys.allSatisfy { !$0.bundleID.isEmpty })
        #expect(result.inventory.untiedSlots[mainUUID]?.count == 2, "the slots of the apps that were filtered are slots nobody claimed")
    }

    @Test func placesOfAnAppsItemsAreRememberedWhileTheyAreAllDrawn() {
        // The app lists its items right to left: the first it lists is the right-hand one.
        func two(_ first: AgentSlot, _ second: AgentSlot, drawn: Bool = true) -> AppExtras {
            AppExtras(pid: 22, bundleID: "com.example.two", name: nil, items: [
                ExtraItem(index: 0, frame: drawn ? first.frame?.insetBy(dx: 6, dy: 1) : nil, identifier: "two.right", title: nil, description: nil),
                ExtraItem(index: 1, frame: drawn ? second.frame?.insetBy(dx: 6, dy: 1) : nil, identifier: "two.left", title: nil, description: nil),
            ], timedOut: false)
        }
        var memory = IndexMemory()
        let bar = mainBar([slot(100), slot(200)])
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == nil, "nothing is known before they are seen")

        _ = InventoryMatcher.match(input([bar], apps: [two(slot(200), slot(100))]), memory: &memory)
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0], "position 0 is the right-hand one")

        // They are concealed: nothing to be told by, and what was learned stays.
        _ = InventoryMatcher.match(input([mainBar([slot(100, frame: false), slot(200, frame: false)])], apps: [two(slot(200), slot(100), drawn: false)]),
                                   memory: &memory)
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1, 2]) == nil, "an app that now lists another number has another order")
        #expect(memory.places(ofApp: "com.example.other", covering: [0, 1]) == nil)

        // One drawn and one not: the order of the two isn't learned over what was known.
        var partial = IndexMemory()
        _ = InventoryMatcher.match(input([bar], apps: [AppExtras(pid: 22, bundleID: "com.example.two", name: nil, items: [
            ExtraItem(index: 0, frame: slot(200).frame?.insetBy(dx: 6, dy: 1), identifier: "two.right", title: nil, description: nil),
            ExtraItem(index: 1, frame: nil, identifier: "two.left", title: nil, description: nil),
        ], timedOut: false)]), memory: &partial)
        #expect(partial.places(ofApp: "com.example.two", covering: [0, 1]) == nil)
    }

    @Test func forgettingAnAppsPlacesKeepsItsOrder() {
        var memory = IndexMemory()
        memory.remember(order: [0: 1, 1: 0], ofApp: "com.example.two")
        memory.remember(places: [0: 1, 1: 0], ofApp: "com.example.two")
        memory.remember(places: [0: 0], ofApp: "com.example.other")

        // Mantel changed the order of the app's items in macOS's table: where they sat is of the old order, and is learned again.
        memory.forgetPlaces(ofApp: "com.example.two")
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == nil)
        #expect(memory.order(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
        #expect(memory.places(ofApp: "com.example.other", covering: [0]) == [0: 0], "no other app's")
    }

    @Test func aRelaunchedAppForgetsItsPlacesButKeepsItsOrder() {
        // Items with no names, listed right to left, drawn: the order and the places are learned. The app is started again (another process
        // ID) and its items are concealed: the places were of the run before and may not be of this one, so they go; the order is what names
        // the items that have no name, so it stays.
        func unnamed(pid: pid_t, drawn: Bool) -> AppExtras {
            AppExtras(pid: pid, bundleID: "com.example.two", name: nil, items: [
                ExtraItem(index: 0, frame: drawn ? slot(200).frame?.insetBy(dx: 6, dy: 1) : nil, identifier: nil, title: nil, description: nil),
                ExtraItem(index: 1, frame: drawn ? slot(100).frame?.insetBy(dx: 6, dy: 1) : nil, identifier: nil, title: nil, description: nil),
            ], timedOut: false)
        }
        var memory = IndexMemory()
        let drawn = input([mainBar([slot(100), slot(200)])], apps: [unnamed(pid: 22, drawn: true)])
        let concealed = input([mainBar([slot(100, frame: false), slot(200, frame: false)])], apps: [unnamed(pid: 22, drawn: false)])
        _ = InventoryMatcher.match(drawn, memory: &memory)
        #expect(memory.order(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])

        // The same process, concealed: it is all kept.
        _ = InventoryMatcher.match(concealed, memory: &memory)
        #expect(memory.order(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])

        // Another process, concealed: the places are forgotten and the order is kept, so the items are told as they were, and not by the
        // order the app lists them in.
        let relaunched = InventoryMatcher.matchCounting(input([mainBar([slot(100, frame: false), slot(200, frame: false)])],
                                                              apps: [unnamed(pid: 77, drawn: false)]), memory: &memory)
        #expect(memory.order(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == nil)
        #expect(relaunched.inventory.items(ofApp: "com.example.two").map(\.id.string) == ["com.example.two#0", "com.example.two#1"])
        #expect(relaunched.listed[ItemID(bundleID: "com.example.two", key: .index(1))] == InventoryMatcher.ListedItem(pid: 77, index: 0),
                "the app's first item is the right-hand one, as before the relaunch")
        #expect(relaunched.listed[ItemID(bundleID: "com.example.two", key: .index(0))] == InventoryMatcher.ListedItem(pid: 77, index: 1))

        // And the places are learned again when the items are drawn.
        _ = InventoryMatcher.match(input([mainBar([slot(100), slot(200)])], apps: [unnamed(pid: 77, drawn: true)]), memory: &memory)
        #expect(memory.places(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
        // Another app's memory is its own.
        var other = IndexMemory()
        _ = InventoryMatcher.match(drawn, memory: &other)
        _ = InventoryMatcher.match(input([mainBar([slot(100), slot(200)])], apps: [AppExtras(pid: 5, bundleID: "com.example.other", name: nil, items: [], timedOut: false)]),
                                   memory: &other)
        #expect(other.places(ofApp: "com.example.two", covering: [0, 1]) == [0: 1, 1: 0])
    }

    @Test func eachItemSaysWhereItsAppListsIt() {
        var memory = IndexMemory()
        let bar = mainBar([slot(100), slot(200), slot(300)])
        let two = AppExtras(pid: 22, bundleID: "com.example.two", name: nil, items: [
            ExtraItem(index: 0, frame: slot(200).frame?.insetBy(dx: 6, dy: 1), identifier: "two.first", title: nil, description: nil),
            ExtraItem(index: 1, frame: slot(300).frame?.insetBy(dx: 6, dy: 1), identifier: "two.second", title: nil, description: nil),
        ], timedOut: false)
        let result = InventoryMatcher.matchCounting(input([bar], apps: [app(11, "com.example.one", in: slot(100)), two]), memory: &memory)

        #expect(result.listed[ItemID(bundleID: "com.example.two", key: .identifier("two.second"))] == InventoryMatcher.ListedItem(pid: 22, index: 1))
        #expect(result.listed[ItemID(bundleID: "com.example.one", key: .index(0))] == InventoryMatcher.ListedItem(pid: 11, index: 0))
        #expect(result.listed.count == 3)
    }

    // MARK: Mantel's own items

    /// Mantel's items, one to a slot from the left: each with the name and the description it is given, and the app that draws them.
    private func ownItemsInput(_ items: [(name: String?, description: String?)], bundleID: String = "com.example.mantel") -> MatchInput {
        let slots = items.indices.map { slot(CGFloat(100 + 100 * $0)) }
        let app = AppExtras(pid: 9, bundleID: bundleID, name: nil, items: items.enumerated().map { place, own in
            ExtraItem(index: place, frame: slots[place].frame?.insetBy(dx: 6, dy: 1), identifier: own.name, title: nil, description: own.description)
        }, timedOut: false)
        return input([mainBar(slots)], apps: [app])
    }

    @Test func ownKindSetFromDescription() {
        // The menu bar's own tree gives status items no names, so what an item of Mantel's is is told by what it is called.
        let descriptions = [OwnItems.hiddenDotDescription, OwnItems.alwaysDotDescription, OwnItems.dividerDescription, OwnItems.spacerDescription,
                            OwnItems.groupDescription(title: "Chat"), OwnItems.groupDescription(title: nil), "Something else"]
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(ownItemsInput(descriptions.map { (nil, $0) }), memory: &memory)
        func kind(_ description: String) -> OwnItemKind? {
            inventory.items.first { $0.label == description }?.ownKind
        }
        #expect(kind("Show hidden icons") == .hiddenDot)
        #expect(kind("Show all icons") == .alwaysDot)
        #expect(kind("Divider") == .divider)
        #expect(kind("Spacer") == .spacer)
        #expect(kind("Chat group") == .group)
        #expect(kind("Icon group") == .group)
        #expect(kind("Something else") == nil, "an item of Mantel's that is none of them has no kind")
        #expect(inventory.items.count == descriptions.count)
        #expect(inventory.items.allSatisfy { $0.isMantel })
        // `isDot` is the two dots.
        let dots: [OwnItemKind] = inventory.items.filter { $0.isDot }.compactMap { $0.ownKind }
        #expect(dots.count == 2)
        #expect(Set(dots) == [.alwaysDot, .hiddenDot])
        #expect(inventory.items.allSatisfy { $0.isDot == ($0.ownKind == .hiddenDot || $0.ownKind == .alwaysDot) })
    }

    @Test func ownKindSetFromName() async throws {
        let names = [OwnItems.hiddenDotName, OwnItems.alwaysDotName, OwnItems.dividerName, "mantel.spacer.1a2b3c4d", "mantel.group.5e6f7a8b",
                     // The wide spacer's invisible items are Mantel's, and none of the above.
                     "mantel.spacer.divider", "mantel.spacer.divider.2", "mantel.spacer.always"]
        var memory = IndexMemory()
        let named = InventoryMatcher.match(ownItemsInput(names.map { ($0, nil) }), memory: &memory)
        func kind(_ name: String) -> OwnItemKind? {
            named.items.first { $0.id.string == "com.example.mantel::\(name)" }?.ownKind
        }
        #expect(kind(OwnItems.hiddenDotName) == .hiddenDot)
        #expect(kind(OwnItems.alwaysDotName) == .alwaysDot)
        #expect(kind(OwnItems.dividerName) == .divider)
        #expect(kind("mantel.spacer.1a2b3c4d") == .spacer)
        #expect(kind("mantel.group.5e6f7a8b") == .group)
        for engine in ["mantel.spacer.divider", "mantel.spacer.divider.2", "mantel.spacer.always"] {
            #expect(named.items.contains { $0.id.string == "com.example.mantel::\(engine)" && $0.isMantel }, "\(engine) is read")
            #expect(kind(engine) == nil, "\(engine) is not a spacer of the person's")
        }
        #expect(named.items.filter { $0.isDot }.count == 2)

        // On the real fixture, where the dots are told by the name their slot has: both are dots, and the test item's are nothing.
        let desk = await inventory(of: InventoryFixtures.desk())
        let own: [MenuBarItem] = desk.items(ofApp: InventoryFixtures.ownBundleID)
        let ownKinds: Set<OwnItemKind> = Set(own.compactMap { $0.ownKind })
        #expect(own.count == 2)
        #expect(ownKinds == [.hiddenDot, .alwaysDot])
        #expect(item("com.example.mantel::mantel.dot.hidden", in: desk)?.ownKind == .hiddenDot)
        #expect(item("com.example.mantel::mantel.dot.always", in: desk)?.ownKind == .alwaysDot)
        #expect(item("com.example.mantel::mantel.dot.hidden", in: desk)?.isDot == true)
    }

    @Test func appItemsHaveNoOwnKind() async throws {
        // Another app's item is nothing of Mantel's, whatever it is called: a name or a description that is Mantel's is only Mantel's
        // from Mantel's own app.
        let lookalikes: [(name: String?, description: String?)] = [
            (OwnItems.hiddenDotName, OwnItems.hiddenDotDescription), (OwnItems.alwaysDotName, nil), (nil, OwnItems.dividerDescription),
            (nil, OwnItems.spacerDescription), ("mantel.group.5e6f7a8b", "Chat group"),
        ]
        var memory = IndexMemory()
        let imitation = InventoryMatcher.match(ownItemsInput(lookalikes, bundleID: "com.example.other"), memory: &memory)
        #expect(imitation.items.count == lookalikes.count)
        #expect(imitation.items.allSatisfy { $0.ownKind == nil && !$0.isDot && !$0.isMantel })

        // Nor is anything on the whole fixture's bar that isn't Mantel's own: the apps' items, the test item's, the system's.
        let desk = await inventory(of: InventoryFixtures.desk())
        for found in desk.items where found.ownerBundleID != InventoryFixtures.ownBundleID {
            #expect(found.ownKind == nil, "\(found.id.string)")
            #expect(!found.isDot, "\(found.id.string)")
        }
        #expect(desk.items.filter { $0.ownKind != nil }.count == 2)
    }

    @Test func anInventoryFromBeforeTheNewFieldsStillDecodes() throws {
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(
            input([mainBar([slot(100), slot(200)])], apps: [app(1, "com.example.one", in: slot(100))], reach: [AppReach(bundleID: "x", name: nil, status: .timedOut, readMs: 1)]),
            memory: &memory)
        #expect(!inventory.unansweredApps.isEmpty && !inventory.untiedSlots.isEmpty)
        let data = try JSONEncoder().encode(inventory)
        #expect(try JSONDecoder().decode(Inventory.self, from: data) == inventory)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "unansweredApps")
        object.removeValue(forKey: "untiedSlots")
        let older = try JSONDecoder().decode(Inventory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.unansweredApps.isEmpty)
        #expect(older.untiedSlots.isEmpty)
        #expect(older.items == inventory.items)
    }

    // MARK: Contests for a slot

    /// Two apps whose frames both lie in one slot (the slot is 100 to 140, centred at 120): one frame centred at `first`, the other at `second`.
    private func contest(_ first: CGFloat, _ second: CGFloat) -> Inventory {
        func app(_ pid: pid_t, _ bundleID: String, center: CGFloat) -> AppExtras {
            AppExtras(pid: pid, bundleID: bundleID, name: nil,
                      items: [ExtraItem(index: 0, frame: CGRect(x: center - 14, y: 1, width: 28, height: 28), identifier: nil, title: nil, description: nil)],
                      timedOut: false)
        }
        var memory = IndexMemory()
        return InventoryMatcher.match(
            input([mainBar([slot(100)])], apps: [app(1, "com.example.one", center: first), app(2, "com.example.two", center: second)]),
            memory: &memory)
    }

    @Test func nearTieForOneSlotIsReportedAsContested() {
        // One frame is 1.5 pt from the slot's centre and the other 0 pt: the second has the slot by a near tie, and neither app's place is
        // to be believed.
        let inventory = contest(121.5, 120)
        #expect(inventory.contestedApps == ["com.example.one", "com.example.two"])
        #expect(inventory.items(ofApp: "com.example.two").first?.frames[mainUUID] != nil, "the nearer frame still has the slot")
        #expect(inventory.items(ofApp: "com.example.one").first?.frames.isEmpty == true)
    }

    @Test func aClearWinIsNotContested() {
        // 3 pt apart is a clear win.
        #expect(contest(123, 120).contestedApps.isEmpty)
        // And a frame that has a slot of its own is no rival for another's.
        var memory = IndexMemory()
        let apart = InventoryMatcher.match(input([mainBar([slot(100), slot(200)])], apps: [app(1, "com.example.one", in: slot(100)),
                                                                                           app(2, "com.example.two", in: slot(200))]),
                                           memory: &memory)
        #expect(apart.contestedApps.isEmpty)
    }
}
