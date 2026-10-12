import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

private let agentPID: pid_t = 50
private let agentBundleID = "com.apple.MenuBarAgent"

private func reader(_ ax: FakeAX, apps: [RunningApp], clock: any Clock = FakeClock()) -> MenuBarReader {
    let all = [RunningApp.fake(agentPID, agentBundleID, "MenuBarAgent")] + apps
    return MenuBarReader(ax: ax, runningApps: { all }, clock: clock)
}

/// The three apps and two displays' windows of a small desk: eight slots in all.
private func smallDesk() -> (ax: FakeAX, apps: [RunningApp]) {
    let ax = FakeAX()
    let main = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 3360, height: 31))
    ax.addSlot(in: main, identifier: "com.apple.menuextra.clock", frame: CGRect(x: 3300, y: 0, width: 50, height: 31))
    ax.addSlot(in: main, identifier: "com.apple.menuextra.controlcenter", frame: CGRect(x: 3250, y: 0, width: 40, height: 31))
    ax.addSlot(in: main, identifier: "com.example.alpha.item", frame: CGRect(x: 3200, y: 0, width: 40, height: 31))
    ax.addSlot(in: main, childIdentifier: "com.example.beta.item", frame: CGRect(x: 3150, y: 0, width: 40, height: 31))
    ax.addSlot(in: main, subrole: "AXMenuExtra", description: "Show more", frame: CGRect(x: 3100, y: 0, width: 30, height: 31))
    let second = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: -1800, y: -491, width: 1800, height: 31))
    ax.addSlot(in: second, identifier: "com.apple.menuextra.clock", frame: CGRect(x: -60, y: -491, width: 50, height: 31))
    ax.addSlot(in: second, identifier: "com.example.gamma.item", frame: CGRect(x: -120, y: -491, width: 40, height: 31))
    ax.addSlot(in: second, identifier: "com.example.alpha.item", frame: CGRect(x: -170, y: -491, width: 40, height: 31))

    ax.addApp(pid: 101, extras: [.init(title: "Alpha", frame: CGRect(x: 3200, y: 0, width: 40, height: 31))])
    ax.addApp(pid: 102, extras: [.init(description: "Beta", frame: CGRect(x: 3150, y: 0, width: 40, height: 31)),
                                 .init(description: "Beta two", frame: nil)])
    ax.addApp(pid: 103, extras: [.init(identifier: "gamma", frame: CGRect(x: -120, y: -491, width: 40, height: 31))])
    ax.addApp(pid: 104, extras: [])
    let apps: [RunningApp] = [
        .fake(101, "com.example.alpha", "Alpha"), .fake(102, "com.example.beta", "Beta"),
        .fake(103, "com.example.gamma", "Gamma"), .fake(104, "com.example.quiet", "Quiet"),
    ]
    return (ax, apps)
}

@Suite("Menu bar snapshot", .timeLimit(.minutes(1)))
struct MenuBarSnapshotTests {
    @Test func aSnapshotRoundTripsThroughJSON() throws {
        let slot = AgentSlot(frame: CGRect(x: 1, y: 2, width: 3, height: 4), identifier: "id", role: "AXGroup",
                             subrole: "AXHostingView", description: "d", ownerPID: 77, isOverflowChevron: false)
        let snapshot = MenuBarSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000.5), layout: .desk,
            agentWindows: [AgentWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 31), slots: [slot])],
            apps: [AppExtras(pid: 77, bundleID: "com.example.a", name: "A",
                             items: [ExtraItem(index: 0, frame: nil, identifier: "i", title: "t", description: "d")],
                             timedOut: false)],
            rawAgentTree: .object(["role": .string("AXApplication"), "children": .array([])]),
            problems: ["Accessibility isn't granted"])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(MenuBarSnapshot.self, from: data) == snapshot)
    }

    @Test func aSnapshotWithoutProblemsInItsFileStillReads() throws {
        let snapshot = MenuBarSnapshot(capturedAt: Date(timeIntervalSince1970: 0), layout: .laptop, agentWindows: [],
                                       apps: [], rawAgentTree: nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "problems")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(MenuBarSnapshot.self, from: older).problems == [])
    }

    @Test func aSnapshotOfAFakeTreeHasTwoWindowsEightSlotsAndThreeApps() async {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)

        #expect(snapshot.agentWindows.count == 2)
        #expect(snapshot.agentWindows.map(\.slots.count) == [5, 3])
        #expect(snapshot.allSlots.count == 8)
        // Four apps are running, but one has nothing in the menu bar, and the agent itself isn't an app of items.
        #expect(snapshot.apps.map(\.bundleID) == ["com.example.alpha", "com.example.beta", "com.example.gamma"])
        #expect(snapshot.apps.map(\.items.count) == [1, 2, 1])
        #expect(snapshot.layout == .desk)
        #expect(snapshot.problems.isEmpty)
    }
}

@Suite("Menu bar reader", .timeLimit(.minutes(1)))
struct MenuBarReaderTests {
    // MARK: What a slot is

    @Test func theWindowKeepsItsFrameAndItsSlotsTheirs() async throws {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)
        #expect(snapshot.agentWindows[0].frame == CGRect(x: 0, y: 0, width: 3360, height: 31))
        let clock = try #require(snapshot.agentWindows[0].slots.first)
        #expect(clock.identifier == "com.apple.menuextra.clock")
        #expect(clock.frame == CGRect(x: 3300, y: 0, width: 50, height: 31))
        #expect(clock.role == "AXGroup" && clock.subrole == "AXHostingView")
    }

    @Test func aSlotTakesItsIdentifierFromAChildWhenItHasNone() async {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)
        #expect(snapshot.agentWindows[0].slots[3].identifier == "com.example.beta.item")
    }

    @Test func theChevronIsToldByItsStructureNotItsText() async {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)
        let chevrons = snapshot.allSlots.filter(\.isOverflowChevron)
        #expect(chevrons.count == 1)
        #expect(chevrons.first?.description == "Show more")
        #expect(chevrons.first?.identifier == nil)
    }

    @Test func theChevronMayBeInAnyLanguage() async {
        // The description is localized; what makes the chevron is that it has one and has no identifier.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 1000, height: 31))
        ax.addSlot(in: window, subrole: "AXMenuExtra", description: "非表示のメニューバー項目を表示", frame: CGRect(x: 900, y: 0, width: 30, height: 31))
        let snapshot = await reader(ax, apps: []).snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.allSlots.first?.isOverflowChevron == true)
    }

    @Test func aSlotWithoutAnIdentifierThatBelongsToAnAppIsNotTheChevron() async {
        // It has the chevron's structure, but its frame is an app's item's: an app owns it.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 1000, height: 31))
        ax.addSlot(in: window, subrole: "AXMenuExtra", description: "Alpha", frame: CGRect(x: 800, y: 0, width: 40, height: 31))
        ax.addApp(pid: 101, extras: [.init(title: "Alpha", frame: CGRect(x: 800, y: 0, width: 40, height: 31))])
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.alpha", "Alpha")]).snapshot(layout: .laptop, includeRawTree: false)
        let slot = snapshot.allSlots.first
        #expect(slot?.isOverflowChevron == false)
        #expect(slot?.ownerPID == 101)
    }

    @Test func aSlotsOwnerComesFromItsIdentifierOrItsFrame() async {
        let (ax, apps) = smallDesk()
        let slots = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false).allSlots
        // alpha: identifier names the bundle; beta: the identifier is on a child and names it too; clock: nobody's.
        #expect(slots[2].ownerPID == 101)
        #expect(slots[3].ownerPID == 102)
        #expect(slots[0].ownerPID == nil)
        #expect(slots[6].ownerPID == 103)
    }

    @Test func aFrameBelongsToTheAppWhoseItemHasTheSameFrame() async {
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 1000, height: 31))
        ax.addSlot(in: window, identifier: "item-1", frame: CGRect(x: 500, y: 0, width: 40, height: 31))
        ax.addApp(pid: 200, extras: [.init(title: "X", frame: CGRect(x: 500.5, y: 0, width: 40, height: 31))])
        let snapshot = await reader(ax, apps: [.fake(200, "com.example.x", "X")]).snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.allSlots.first?.ownerPID == 200)
    }

    // MARK: Apps

    @Test func anAppsItemsKeepTheirIndexAndWhatTheyAreCalled() async throws {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)
        let beta = try #require(snapshot.apps.first { $0.bundleID == "com.example.beta" })
        #expect(beta.name == "Beta")
        #expect(beta.items.map(\.index) == [0, 1])
        #expect(beta.items[0].description == "Beta")
        #expect(beta.items[1].frame == nil)
        #expect(!beta.timedOut)
    }

    // MARK: Reads of an item that time out

    /// The ids of the items in an app's extras menu bar.
    private func itemIDs(_ ax: FakeAX, app pid: pid_t) throws -> [Int] {
        guard case .elements(let bars) = try ax.attribute(AXName.extrasMenuBar, of: ax.application(pid: pid)), let bar = bars.first else {
            return []
        }
        return try ax.children(of: bar).map(ax.id(of:))
    }

    private func appWithThreeItems() -> FakeAX {
        let ax = FakeAX()
        ax.addApp(pid: 101, extras: [
            .init(title: "One", identifier: "one", frame: CGRect(x: 10, y: 0, width: 20, height: 31)),
            .init(title: "Two", identifier: "two", frame: CGRect(x: 40, y: 0, width: 20, height: 31)),
            .init(title: "Three", identifier: "three", frame: CGRect(x: 70, y: 0, width: 20, height: 31)),
        ])
        return ax
    }

    @Test func itemTimeoutsAreCounted() async throws {
        let ax = appWithThreeItems()
        let ids = try itemIDs(ax, app: 101)
        // The app answers, but the read of one item's title doesn't come in time.
        let slow: Set<Int> = [ids[1]]
        ax.setOverride { id, name in slow.contains(id) && name == AXName.title ? .failure(.timeout) : nil }
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(101, "com.example.app", "App")], clock: clock)

        let first = await reader.snapshot(layout: .laptop, includeRawTree: false)
        let app = try #require(first.apps.first)
        #expect(app.itemTimeouts == 1, "counted, not swallowed")
        #expect(app.items.count == 3, "the other reads of the item, and the other items, are there")
        #expect(app.items[1].title == nil)
        #expect(app.items[1].identifier == "two")
        #expect(app.items[1].frame == CGRect(x: 40, y: 0, width: 20, height: 31))
        #expect(app.items[0].title == "One")
        #expect(!app.timedOut, "one is not three")

        // Not skipped: asked again at once, and the count is of that read alone.
        let readsBefore = ax.attributeReads(on: ids[0])
        let second = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(ax.attributeReads(on: ids[0]) > readsBefore)
        #expect(second.apps.first?.itemTimeouts == 1)
    }

    @Test func aReadOfAnItemsFrameThatTimesOutIsCountedToo() async throws {
        let ax = appWithThreeItems()
        let ids = try itemIDs(ax, app: 101)
        let slow: Set<Int> = [ids[0]]
        ax.setOverride { id, name in slow.contains(id) && name == AXName.position ? .failure(.timeout) : nil }
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.app", "App")]).snapshot(layout: .laptop, includeRawTree: false)
        let app = try #require(snapshot.apps.first)
        #expect(app.itemTimeouts == 1)
        #expect(app.items[0].frame == nil)
        #expect(app.items[1].frame != nil)
    }

    @Test func threeItemTimeoutsCountAsATimeoutOfTheApp() async throws {
        let ax = appWithThreeItems()
        let ids = try itemIDs(ax, app: 101)
        let slow = Set(ids)
        ax.setOverride { id, name in slow.contains(id) && name == AXName.title ? .failure(.timeout) : nil }
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(101, "com.example.app", "App")], clock: clock)

        let first = await reader.snapshot(layout: .laptop, includeRawTree: false)
        let app = try #require(first.apps.first)
        #expect(app.itemTimeouts == 3)
        #expect(app.timedOut, "three in one read: the app timed out")

        // As for an app that timed out whole: it is left alone for 30 seconds.
        let reads = ax.attributeReads(on: ids[0])
        clock.advance(by: .seconds(29))
        let second = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(second.apps.first?.timedOut == true)
        #expect(ax.attributeReads(on: ids[0]) == reads, "not asked again")

        clock.advance(by: .seconds(2))
        ax.setOverride(nil)
        let third = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(third.apps.first?.timedOut == false)
        #expect(third.apps.first?.itemTimeouts == 0)
        #expect(third.apps.first?.items.map(\.title) == ["One", "Two", "Three"])
    }

    @Test func readStopsAtTheItemTimeoutThreshold() async throws {
        // An app whose reads all time out costs three of them, not a wait for every attribute of every item it has.
        let ax = FakeAX()
        let items = ax.addApp(pid: 101, extras: (0..<12).map { index in
            FakeAX.Extra(title: "Item \(index)", identifier: "item.\(index)", frame: CGRect(x: 10 * CGFloat(index), y: 0, width: 8, height: 31))
        })
        let hung = Set(items)
        ax.setOverride { id, _ in hung.contains(id) ? .failure(.timeout) : nil }
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.app", "App")]).snapshot(layout: .laptop, includeRawTree: false)

        let app = try #require(snapshot.apps.first)
        #expect(items.map { ax.attributeReads(on: $0) }.reduce(0, +) == 3, "exactly three reads of items were made")
        #expect(ax.attributeReads(on: items[0]) == 3, "all of them in the first item")
        #expect(items.dropFirst().allSatisfy { ax.attributeReads(on: $0) == 0 })
        #expect(app.itemTimeouts == 3)
        #expect(app.timedOut)
        #expect(app.items.isEmpty, "the item it stopped in wasn't read whole")
    }

    @Test func itemsReadBeforeTheThresholdAreKept() async throws {
        // Two items that answer and then ones that don't: the two are in the list, and the others are never asked.
        let ax = FakeAX()
        let items = ax.addApp(pid: 101, extras: (0..<8).map { index in
            FakeAX.Extra(title: "Item \(index)", identifier: "item.\(index)", frame: CGRect(x: 10 * CGFloat(index), y: 0, width: 8, height: 31))
        })
        let hung = Set(items.dropFirst(2))
        ax.setOverride { id, _ in hung.contains(id) ? .failure(.timeout) : nil }
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.app", "App")]).snapshot(layout: .laptop, includeRawTree: false)

        let app = try #require(snapshot.apps.first)
        #expect(app.items.map(\.identifier) == ["item.0", "item.1"])
        #expect(app.itemTimeouts == 3)
        #expect(app.timedOut)
        #expect(items.dropFirst(3).allSatisfy { ax.attributeReads(on: $0) == 0 }, "the items after the one it stopped in were not asked")
    }

    @Test func theItemThatReachesTheThresholdOnItsLastReadIsKeptAndTheNextIsNotAsked() async throws {
        // The third timeout is the last read of the first item (its description): that item is whole, as far as it will be.
        let ax = FakeAX()
        let items = ax.addApp(pid: 101, extras: (0..<4).map { index in
            FakeAX.Extra(title: "Item \(index)", identifier: "item.\(index)", description: "Description \(index)",
                         frame: CGRect(x: 10 * CGFloat(index), y: 0, width: 8, height: 31))
        })
        let first = items[0]
        ax.setOverride { id, name in id == first && name != AXName.title ? .failure(.timeout) : nil }
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.app", "App")]).snapshot(layout: .laptop, includeRawTree: false)

        let app = try #require(snapshot.apps.first)
        #expect(app.itemTimeouts == 3)
        #expect(app.timedOut)
        #expect(app.items.map(\.title) == ["Item 0"])
        #expect(app.items.first?.identifier == nil && app.items.first?.frame == nil)
        #expect(items.dropFirst().allSatisfy { ax.attributeReads(on: $0) == 0 })
    }

    @Test func anAppThatAnswersEverythingHasNoItemTimeouts() async throws {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)
        #expect(snapshot.apps.allSatisfy { $0.itemTimeouts == 0 })
    }

    @Test func otherFailuresOfAnItemsReadAreNotTimeouts() async throws {
        let ax = appWithThreeItems()
        let ids = try itemIDs(ax, app: 101)
        let refused: Set<Int> = Set(ids)
        ax.setOverride { id, name in refused.contains(id) && name == AXName.title ? .failure(.failure(-25205)) : nil }
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.app", "App")]).snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.apps.first?.itemTimeouts == 0)
        #expect(snapshot.apps.first?.timedOut == false)
    }

    @Test func aSnapshotSavedBeforeTheCountWasKeptHasNone() throws {
        let json = #"{"pid":7,"bundleID":"com.example.a","name":"A","items":[],"timedOut":false}"#
        let extras = try JSONDecoder().decode(AppExtras.self, from: Data(json.utf8))
        #expect(extras.itemTimeouts == 0)
        let counted = AppExtras(pid: 7, bundleID: "com.example.a", name: "A", items: [], timedOut: false, itemTimeouts: 2)
        #expect(try JSONDecoder().decode(AppExtras.self, from: JSONEncoder().encode(counted)) == counted)
    }

    @Test func timedOutAppIsMarkedAndSkipped() async throws {
        let ax = FakeAX()
        ax.addApp(pid: 101, extras: [.init(title: "Fine", frame: CGRect(x: 10, y: 0, width: 20, height: 31))])
        let hungRoot = ax.root(ofApp: 102)
        ax.failReads(on: hungRoot, with: .timeout)
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(101, "com.example.fine", "Fine"), .fake(102, "com.example.hung", "Hung")], clock: clock)

        let first = await reader.snapshot(layout: .laptop, includeRawTree: false)
        let hung = try #require(first.apps.first { $0.pid == 102 })
        #expect(hung.timedOut)
        #expect(hung.items.isEmpty)
        #expect(first.apps.first { $0.pid == 101 }?.timedOut == false)
        let readsAfterFirst = ax.attributeReads(on: hungRoot)
        #expect(readsAfterFirst >= 1)

        // Within 30 s it isn't asked again, and is still reported as timed out.
        clock.advance(by: .seconds(29))
        let second = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(second.apps.first { $0.pid == 102 }?.timedOut == true)
        #expect(ax.attributeReads(on: hungRoot) == readsAfterFirst)

        // After 30 s it is asked again (and, still hung, skipped for another 30 s).
        clock.advance(by: .seconds(2))
        let third = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(third.apps.first { $0.pid == 102 }?.timedOut == true)
        #expect(ax.attributeReads(on: hungRoot) > readsAfterFirst)
    }

    @Test func anAppThatRecoversIsReadAgainAfterTheSkip() async throws {
        let ax = FakeAX()
        let root = ax.root(ofApp: 102)
        ax.failReads(on: root, with: .timeout)
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(102, "com.example.late", "Late")], clock: clock)
        #expect(await reader.snapshot(layout: .laptop, includeRawTree: false).apps.first?.timedOut == true)

        ax.failReads(on: root, with: nil)
        ax.addApp(pid: 102, extras: [.init(title: "Back", frame: nil)])
        clock.advance(by: .seconds(31))
        let after = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(after.apps.first?.timedOut == false)
        #expect(after.apps.first?.items.count == 1)
    }

    @Test func snapshotOf40FakeAppsIsFast() async {
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 3360, height: 31))
        var apps: [RunningApp] = []
        for index in 0..<40 {
            let pid = pid_t(1000 + index)
            let frame = CGRect(x: 3000 - index * 40, y: 0, width: 38, height: 31)
            ax.addApp(pid: pid, extras: [.init(title: "App \(index)", frame: frame), .init(title: "Second \(index)", frame: nil)])
            ax.addSlot(in: window, identifier: "com.example.app\(index).item", frame: frame)
            apps.append(.fake(pid, "com.example.app\(index)", "App \(index)"))
        }
        let reader = reader(ax, apps: apps)

        let started = ContinuousClock.now
        let snapshot = await reader.snapshot(layout: .desk, includeRawTree: false)
        let elapsed = ContinuousClock.now - started

        #expect(snapshot.apps.count == 40)
        #expect(snapshot.allSlots.count == 40)
        // The fake tree answers at once, so this can't tell reading the apps one after the other from reading them at once: it
        // guards against a gross slowdown of the read, and nothing finer. (That the apps are asked at once, with a limit, is checked
        // on a fake clock where each answer takes a second: `MenuBarScannerTests.scanReadsAppsConcurrently`.) The limit is loose so
        // that a loaded machine doesn't make it flaky: run alone, the snapshot takes milliseconds, and in the whole suite it waits for
        // a free thread behind tests that are busy, for a second or more.
        #expect(elapsed < .seconds(5))
    }

    // MARK: The agent alone

    @Test func anAgentOnlyReadHasTheWindowsAndTheSlotsAndNoApps() async {
        let (ax, apps) = smallDesk()
        let reader = reader(ax, apps: apps)
        let full = await reader.snapshot(layout: .desk, includeRawTree: false)
        let agentOnly = await reader.agentSnapshot(layout: .desk)

        #expect(agentOnly.agentWindows == full.agentWindows, "the same windows and slots, with the same frames and identifiers")
        #expect(agentOnly.apps.isEmpty)
        #expect(agentOnly.rawAgentTree == nil)
        #expect(agentOnly.layout == .desk)
        #expect(agentOnly.problems.isEmpty)
    }

    @Test func anAgentOnlyReadAsksNoAppAnything() async {
        let (ax, apps) = smallDesk()
        let reader = reader(ax, apps: apps)
        _ = await reader.agentSnapshot(layout: .desk)
        for pid in [101, 102, 103, 104] as [pid_t] {
            #expect(ax.attributeReads(on: ax.root(ofApp: pid)) == 0, "an app's own list of items isn't read for change detection")
        }
        #expect(ax.attributeReads(on: ax.root(ofApp: agentPID)) > 0)

        _ = await reader.snapshot(layout: .desk, includeRawTree: false)
        #expect(ax.attributeReads(on: ax.root(ofApp: 101)) > 0, "the full snapshot does")
    }

    @Test func aSlotsOwnerByItsFrameNeedsTheAppsSoItIsLeftOutOfAnAgentOnlyRead() async {
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 1000, height: 31))
        ax.addSlot(in: window, identifier: "com.example.x.item", frame: CGRect(x: 400, y: 0, width: 40, height: 31))
        ax.addSlot(in: window, identifier: "item-1", frame: CGRect(x: 500, y: 0, width: 40, height: 31))
        ax.addApp(pid: 200, extras: [.init(title: "X", frame: CGRect(x: 500, y: 0, width: 40, height: 31))])
        let reader = reader(ax, apps: [.fake(200, "com.example.x", "X")])

        let full = await reader.snapshot(layout: .laptop, includeRawTree: false)
        let agentOnly = await reader.agentSnapshot(layout: .laptop)
        #expect(full.allSlots.map(\.ownerPID) == [200, 200])
        #expect(agentOnly.allSlots.map(\.ownerPID) == [200, nil], "by identifier still, by frame no longer")
    }

    @Test func anAgentOnlyReadSaysWhatKeptItFromBeingWhole() async {
        let noAgent = MenuBarReader(ax: FakeAX(), runningApps: { [.fake(101, "com.example.a", "A")] })
        let missing = await noAgent.agentSnapshot(layout: .laptop)
        #expect(missing.agentWindows.isEmpty)
        #expect(missing.problems == ["MenuBarAgent isn't running."])

        let (ax, apps) = smallDesk()
        ax.failReads(on: ax.root(ofApp: agentPID), with: .notTrusted)
        let refused = await reader(ax, apps: apps).agentSnapshot(layout: .desk)
        #expect(refused.problems == ["Accessibility isn't granted to Mantel."])
    }

    @Test func anAgentOnlyReadOfADeskWithFortyAppsAsksNoneOfThem() async {
        // What a poll costs is what its reads cost: the full one asks every app, the agent-only one asks the agent alone.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 3360, height: 31))
        var apps: [RunningApp] = []
        for index in 0..<40 {
            let pid = pid_t(1000 + index)
            let frame = CGRect(x: 3000 - index * 40, y: 0, width: 38, height: 31)
            ax.addApp(pid: pid, extras: [.init(title: "App \(index)", frame: frame), .init(title: "Second \(index)", frame: nil)])
            ax.addSlot(in: window, identifier: "com.example.app\(index).item", frame: frame)
            apps.append(.fake(pid, "com.example.app\(index)", "App \(index)"))
        }
        let reader = reader(ax, apps: apps)
        func readsOfTheApps() -> Int {
            (0..<40).map { ax.attributeReads(on: ax.root(ofApp: pid_t(1000 + $0))) }.reduce(0, +)
        }

        _ = await reader.agentSnapshot(layout: .desk)
        #expect(readsOfTheApps() == 0, "forty apps weren't asked")
        _ = await reader.snapshot(layout: .desk, includeRawTree: false)
        #expect(readsOfTheApps() >= 40)
    }

    // MARK: Raw tree and problems

    @Test func rawTreeOnlyWhenAsked() async throws {
        let (ax, apps) = smallDesk()
        let reader = reader(ax, apps: apps)
        #expect(await reader.snapshot(layout: .desk, includeRawTree: false).rawAgentTree == nil)

        let withTree = await reader.snapshot(layout: .desk, includeRawTree: true)
        let tree = try #require(withTree.rawAgentTree)
        guard case .object(let root) = tree else {
            Issue.record("the tree's root is an object")
            return
        }
        guard case .array(let windows)? = root["children"] else {
            Issue.record("the root has children")
            return
        }
        #expect(windows.count == 2)
        guard case .object(let first) = windows[0], case .array(let slots)? = first["children"] else {
            Issue.record("a window has children")
            return
        }
        #expect(slots.count == 5)
        guard case .object(let slot) = slots[0] else {
            Issue.record("a slot is an object")
            return
        }
        #expect(slot["identifier"] == .string("com.apple.menuextra.clock"))
        #expect(slot["role"] == .string("AXGroup"))
        guard case .object(let frame)? = slot["frame"] else {
            Issue.record("a slot has a frame")
            return
        }
        #expect(frame["x"] == .number(3300))
        // What the element has, by name, so that the real names can be read off a real dump.
        guard case .array(let names)? = slot["attributes"] else {
            Issue.record("a slot lists its attribute names")
            return
        }
        #expect(names.contains(.string("AXIdentifier")))
    }

    @Test func theRawTreeStopsAtDepthSix() async throws {
        let ax = FakeAX()
        var parent = ax.root(ofApp: agentPID)
        for level in 1...10 {
            parent = ax.addNode(attributes: [AXName.role: .string("level\(level)")], under: parent)
        }
        let snapshot = await reader(ax, apps: []).snapshot(layout: .laptop, includeRawTree: true)
        var depth = 0
        var node = snapshot.rawAgentTree
        while case .object(let object)? = node, case .array(let children)? = object["children"], let next = children.first {
            depth += 1
            node = next
        }
        #expect(depth == 6)
    }

    @Test func withoutAccessibilityTheSnapshotSaysSo() async {
        let (ax, apps) = smallDesk()
        for pid in [agentPID, 101, 102, 103, 104] {
            ax.failReads(on: ax.root(ofApp: pid), with: .notTrusted)
        }
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk, includeRawTree: false)
        #expect(snapshot.agentWindows.isEmpty)
        #expect(snapshot.apps.isEmpty)
        #expect(snapshot.problems == ["Accessibility isn't granted to Mantel."])
    }

    @Test func withoutMenuBarAgentTheSnapshotSaysSo() async {
        let ax = FakeAX()
        let reader = MenuBarReader(ax: ax, runningApps: { [.fake(101, "com.example.a", "A")] })
        let snapshot = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.agentWindows.isEmpty)
        #expect(snapshot.problems == ["MenuBarAgent isn't running."])
    }

    @Test func anAppWithoutABundleIDIsNotAsked() async {
        let ax = FakeAX()
        ax.addApp(pid: 300, extras: [.init(title: "Anonymous", frame: nil)])
        let root = ax.root(ofApp: 300)
        let snapshot = await reader(ax, apps: [.fake(300, nil, "Anonymous")]).snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.apps.isEmpty)
        #expect(ax.attributeReads(on: root) == 0)
    }
}

@Suite("Menu bar reader, one app and the windows", .timeLimit(.minutes(1)))
struct MenuBarReaderNarrowReadsTests {
    @Test func theFramesOfOneAppAreReadAndNothingElseIs() {
        let (ax, apps) = smallDesk()
        let alpha = ax.root(ofApp: 101)
        let beta = ax.root(ofApp: 102)
        let agent = ax.root(ofApp: agentPID)

        let frames = reader(ax, apps: apps).extrasFrames(ofPID: 102)

        #expect(frames == [CGRect(x: 3150, y: 0, width: 40, height: 31), nil], "its second item has no frame")
        #expect(ax.attributeReads(on: beta) > 0)
        #expect(ax.attributeReads(on: alpha) == 0, "no other app is asked")
        #expect(ax.attributeReads(on: agent) == 0, "and MenuBarAgent isn't")
    }

    @Test func anAppWithNoItemsOrNoAnswerHasNoFrames() {
        let (ax, apps) = smallDesk()
        #expect(reader(ax, apps: apps).extrasFrames(ofPID: 104) == nil, "an app with an empty extras menu bar")
        #expect(reader(ax, apps: apps).extrasFrames(ofPID: 999) == nil, "an app that isn't there")
        let beta = ax.root(ofApp: 102)
        ax.failReads(on: beta, with: .timeout)
        #expect(reader(ax, apps: apps).extrasFrames(ofPID: 102) == nil, "an app that doesn't answer")
    }

    @Test func eachWindowOfTheAgentSaysItsFrameItsAttributesAndHowManySlotsItHas() async {
        let (ax, apps) = smallDesk()
        let details = await reader(ax, apps: apps).agentWindowDetails()
        #expect(details.map(\.slotCount) == [5, 3])
        #expect(details.map(\.frame) == [CGRect(x: 0, y: 0, width: 3360, height: 31), CGRect(x: -1800, y: -491, width: 1800, height: 31)])
        #expect(details[0].attributes["AXRole"] == .string("AXWindow"))
    }

    @Test func withoutTheAgentThereAreNoWindowDetails() async {
        let ax = FakeAX()
        let details = await MenuBarReader(ax: ax, runningApps: { [] }, clock: FakeClock()).agentWindowDetails()
        #expect(details.isEmpty)
    }
}
