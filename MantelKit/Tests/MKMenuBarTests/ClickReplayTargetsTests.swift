import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// Where clicks are held: the frames of the clock, on every display, from each new inventory.
@Suite("Click replay targets", .timeLimit(.minutes(1)))
struct ClickReplayTargetsTests {
    private let main = DisplayFixtures.deskMain.uuid
    private let portrait = DisplayFixtures.deskPortrait.uuid

    private func systemItem(_ module: String, _ frames: [String: CGRect]) -> MenuBarItem {
        MenuBarItem(id: .system(module), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil, frames: frames, overflowedOn: [],
                    isMantel: false)
    }

    private func appItem(_ bundleID: String, _ frames: [String: CGRect]) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier("item")), ownerBundleID: bundleID, appName: nil, label: nil, frames: frames,
                    overflowedOn: [], isMantel: false)
    }

    private func inventory(_ items: [MenuBarItem]) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: items, chevrons: [:], reach: [], problems: [])
    }

    private func scan(_ fixture: InventoryFixtures.Fixture) async -> Inventory {
        let layout = fixture.layout
        let running = fixture.running
        let scanner = MenuBarScanner(ax: fixture.ax, runningApps: { running }, layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        return await scanner.scan()
    }

    // MARK: Review focus: the second display, and a display that is unplugged

    @Test func clockOnEveryDisplayIsATarget() async throws {
        // A real read of two displays' menu bars: the clock has a slot on each, and each is a target.
        let fixture = InventoryFixtures.desk()
        let inventory = await scan(fixture)

        let clock = try #require(inventory.items.first { $0.id == .system("clock") })
        #expect(Set(clock.frames.keys) == [main, portrait], "the clock was found on both displays")
        let rects = ClickReplayTargets.rects(in: inventory)
        #expect(rects.count == 2)
        #expect(Set(rects) == Set(clock.frames.values))
        for display in [main, portrait] {
            let frame = try #require(clock.frames[display])
            #expect(rects.contains(frame), "the clock of each display is held")
            #expect(rects.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) })
        }

        // And where they are, in numbers that don't come from the same code: a clock 80 points wide, 12 points in from the right edge of
        // a bar that is 30 points high. The main display is 3360 points wide and starts at the origin; the portrait one is 1800 wide, and its
        // bar is where CoreGraphics puts the top of a display whose top is 491 points above the main display's.
        let mainClock = CGRect(x: 3268, y: 0, width: 80, height: 30)
        let portraitClock = CGRect(x: -92, y: -491, width: 80, height: 30)
        #expect(clock.frames[main] == mainClock)
        #expect(clock.frames[portrait] == portraitClock)
        #expect(rects == [portraitClock, mainClock], "in the order of the displays' IDs")
    }

    @Test func removedDisplayLeavesNoTarget() {
        let mainClock = CGRect(x: 3268, y: 0, width: 80, height: 30)
        let portraitClock = CGRect(x: -92, y: -491, width: 80, height: 30)
        let both = inventory([systemItem("clock", [main: mainClock, portrait: portraitClock])])
        #expect(Set(ClickReplayTargets.rects(in: both)) == [mainClock, portraitClock])

        // The next read, after the portrait display was unplugged: its clock is gone from the inventory, and so is its target.
        let after = inventory([systemItem("clock", [main: mainClock])])
        let rects = ClickReplayTargets.rects(in: after)
        #expect(rects == [mainClock])
        #expect(!rects.contains(portraitClock))
        #expect(!rects.contains { $0.contains(CGPoint(x: -50, y: -480)) }, "a click where the unplugged display's clock was is nobody's")
    }

    @Test func removedDisplayLeavesNoTargetInARealRead() async {
        // The same through the scanner: the portrait display is gone from the layout when the next read is made.
        let fixture = InventoryFixtures.desk()
        let before = await scan(fixture)
        #expect(ClickReplayTargets.rects(in: before).count == 2)

        let layout = DisplayLayout(displays: [DisplayFixtures.deskMain])
        let running = fixture.running
        let scanner = MenuBarScanner(ax: fixture.ax, runningApps: { running }, layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock(), readLimit: 8)
        let after = await scanner.scan()

        let rects = ClickReplayTargets.rects(in: after)
        #expect(rects.count == 1, "only the display that is still there has a target")
        let portraitBar = fixture.bars[1]
        #expect(!rects.contains { $0.intersects(portraitBar) }, "none is on the portrait display")
    }

    // MARK: Which items

    @Test func modulesAreTheClockOnly() {
        // Control Center, Wi-Fi, battery, sound and Bluetooth all open normally while an allowlist is live; only the clock is ignored.
        #expect(ClickReplayTargets.modules == ["clock"])
    }

    @Test func controlCenterIsNotATarget() {
        let frame = CGRect(x: 3228, y: 0, width: 36, height: 30)
        #expect(ClickReplayTargets.rects(in: inventory([systemItem("controlcenter", [main: frame])])).isEmpty)
    }

    @Test func onlyRuledModules() {
        let clock = CGRect(x: 3268, y: 0, width: 80, height: 30)
        let items = [
            systemItem("controlcenter", [main: CGRect(x: 3228, y: 0, width: 36, height: 30)]),
            systemItem("battery", [main: CGRect(x: 3170, y: 0, width: 50, height: 30)]),
            systemItem("wifi", [main: CGRect(x: 3130, y: 0, width: 36, height: 30)]),
            systemItem("sound", [main: CGRect(x: 3090, y: 0, width: 36, height: 30)]),
            systemItem("bluetooth", [main: CGRect(x: 3050, y: 0, width: 36, height: 30)]),
            systemItem("clock", [main: clock]),
            appItem("com.example.weather", [main: CGRect(x: 2900, y: 0, width: 36, height: 30)]),
        ]
        #expect(ClickReplayTargets.rects(in: inventory(items)) == [clock], "an app's item is never a target, and neither is any other system item")
    }

    @Test func anAppWhoseIdentifierEndsInClockIsNotTheClock() {
        let frame = CGRect(x: 2900, y: 0, width: 36, height: 30)
        let item = MenuBarItem(id: ItemID(bundleID: "com.example.clocks", key: .identifier("com.apple.menuextra.clock")),
                               ownerBundleID: "com.example.clocks", appName: nil, label: nil, frames: [main: frame], overflowedOn: [], isMantel: false)
        #expect(ClickReplayTargets.rects(in: inventory([item])).isEmpty)
    }

    @Test func concealedItemsAreNotTargets() {
        // A clock that has no place on any bar (macOS isn't drawing it) has no frames, and holds nothing.
        #expect(ClickReplayTargets.rects(in: inventory([systemItem("clock", [:])])).isEmpty)
        // Nor does a frame with no area.
        #expect(ClickReplayTargets.rects(in: inventory([systemItem("clock", [main: .zero])])).isEmpty)
        // A clock that has a frame on one display only is held there, and nowhere else.
        let frame = CGRect(x: 3268, y: 0, width: 80, height: 30)
        #expect(ClickReplayTargets.rects(in: inventory([systemItem("clock", [main: frame])])) == [frame])
    }

    @Test func noItemsNoTargets() {
        #expect(ClickReplayTargets.rects(in: .empty).isEmpty)
    }

    @Test func theTargetsComeInTheOrderOfTheDisplays() {
        // Whatever order a dictionary happens to give its entries in, the same inventory gives the same targets.
        let mainClock = CGRect(x: 3268, y: 0, width: 80, height: 30)
        let portraitClock = CGRect(x: -92, y: -491, width: 80, height: 30)
        let inventory = inventory([systemItem("clock", [main: mainClock, portrait: portraitClock])])
        #expect(ClickReplayTargets.rects(in: inventory) == [portraitClock, mainClock], "by the displays' UUIDs")
        for _ in 0..<5 { #expect(ClickReplayTargets.rects(in: inventory) == [portraitClock, mainClock]) }
    }

    // MARK: Which engine

    @Test func onlyTheAllowlistWantsTheTap() {
        #expect(ClickReplayTargets.isWanted(whileHidingWith: .allowlist))
        #expect(!ClickReplayTargets.isWanted(whileHidingWith: .approvals), "the clock works as usual with the switches")
        #expect(!ClickReplayTargets.isWanted(whileHidingWith: .spacer), "and with the spacer")
        #expect(!ClickReplayTargets.isWanted(whileHidingWith: nil), "and before an engine has been chosen")
    }
}

/// When the tap on the clock may run, as a value: the quit stop is final.
@Suite("Clock click gate", .timeLimit(.minutes(1)))
struct ClockClickGateTests {
    @Test func theTapIsWantedOnlyWhileTheAllowlistHides() {
        let gate = ClockClickGate()
        #expect(gate.isWanted(whileHidingWith: .allowlist))
        #expect(!gate.isWanted(whileHidingWith: .approvals))
        #expect(!gate.isWanted(whileHidingWith: .spacer))
        #expect(!gate.isWanted(whileHidingWith: nil))
    }

    @Test func aShutDownTapIsNeverWantedAgain() {
        // The quit stop: states the session publishes while the app puts things back go on saying that the allowlist is the engine.
        var gate = ClockClickGate()
        gate.shutDown()
        #expect(gate.isShutDown)
        for engine in [HidingEngineKind.allowlist, .approvals, .spacer] {
            #expect(!gate.isWanted(whileHidingWith: engine))
        }
        #expect(!gate.isWanted(whileHidingWith: nil))
        gate.shutDown()
        #expect(!gate.isWanted(whileHidingWith: .allowlist), "twice is the same as once")
    }

    @Test func aNewGateIsNotShutDown() {
        var old = ClockClickGate()
        old.shutDown()
        #expect(ClockClickGate().isWanted(whileHidingWith: .allowlist), "the stop belongs to the gate it was made on")
        #expect(old != ClockClickGate())
    }
}
