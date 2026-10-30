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
            problems: ["Device control and data access isn't granted"])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(MenuBarSnapshot.self, from: data) == snapshot)
    }

    @Test func aSnapshotOfAFakeTreeHasTwoWindowsEightSlotsAndThreeApps() async {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk)

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
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk)
        #expect(snapshot.agentWindows[0].frame == CGRect(x: 0, y: 0, width: 3360, height: 31))
        let clock = try #require(snapshot.agentWindows[0].slots.first)
        #expect(clock.identifier == "com.apple.menuextra.clock")
        #expect(clock.frame == CGRect(x: 3300, y: 0, width: 50, height: 31))
        #expect(clock.role == "AXGroup" && clock.subrole == "AXHostingView")
    }

    @Test func aSlotTakesItsIdentifierFromAChildWhenItHasNone() async {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk)
        #expect(snapshot.agentWindows[0].slots[3].identifier == "com.example.beta.item")
    }

    @Test func theChevronIsToldByItsStructureNotItsText() async {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk)
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
        let snapshot = await reader(ax, apps: []).snapshot(layout: .laptop)
        #expect(snapshot.allSlots.first?.isOverflowChevron == true)
    }

    @Test func aSlotWithoutAnIdentifierThatBelongsToAnAppIsNotTheChevron() async {
        // It has the chevron's structure, but its frame is an app's item's: an app owns it.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 1000, height: 31))
        ax.addSlot(in: window, subrole: "AXMenuExtra", description: "Alpha", frame: CGRect(x: 800, y: 0, width: 40, height: 31))
        ax.addApp(pid: 101, extras: [.init(title: "Alpha", frame: CGRect(x: 800, y: 0, width: 40, height: 31))])
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.alpha", "Alpha")]).snapshot(layout: .laptop)
        let slot = snapshot.allSlots.first
        #expect(slot?.isOverflowChevron == false)
        #expect(slot?.ownerPID == 101)
    }

    @Test func aSlotsOwnerComesFromItsIdentifierOrItsFrame() async {
        let (ax, apps) = smallDesk()
        let slots = await reader(ax, apps: apps).snapshot(layout: .desk).allSlots
        // alpha: identifier names the bundle; beta: the identifier is on a child and names it too; clock: nobody's.
        #expect(slots[2].ownerPID == 101)
        #expect(slots[3].ownerPID == 102)
        #expect(slots[0].ownerPID == nil)
        #expect(slots[6].ownerPID == 103)
    }

    // MARK: Apps

    @Test func anAppsItemsKeepTheirIndexAndWhatTheyAreCalled() async throws {
        let (ax, apps) = smallDesk()
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk)
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

        let first = await reader.snapshot(layout: .laptop)
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
        let second = await reader.snapshot(layout: .laptop)
        #expect(ax.attributeReads(on: ids[0]) > readsBefore)
        #expect(second.apps.first?.itemTimeouts == 1)
    }

    @Test func threeItemTimeoutsCountAsATimeoutOfTheApp() async throws {
        let ax = appWithThreeItems()
        let ids = try itemIDs(ax, app: 101)
        let slow = Set(ids)
        ax.setOverride { id, name in slow.contains(id) && name == AXName.title ? .failure(.timeout) : nil }
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(101, "com.example.app", "App")], clock: clock)

        let first = await reader.snapshot(layout: .laptop)
        let app = try #require(first.apps.first)
        #expect(app.itemTimeouts == 3)
        #expect(app.timedOut, "three in one read: the app timed out")

        // As for an app that timed out whole: it is left alone for 30 seconds.
        let reads = ax.attributeReads(on: ids[0])
        clock.advance(by: .seconds(29))
        let second = await reader.snapshot(layout: .laptop)
        #expect(second.apps.first?.timedOut == true)
        #expect(ax.attributeReads(on: ids[0]) == reads, "not asked again")

        clock.advance(by: .seconds(2))
        ax.setOverride(nil)
        let third = await reader.snapshot(layout: .laptop)
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
        let snapshot = await reader(ax, apps: [.fake(101, "com.example.app", "App")]).snapshot(layout: .laptop)

        let app = try #require(snapshot.apps.first)
        #expect(items.map { ax.attributeReads(on: $0) }.reduce(0, +) == 3, "exactly three reads of items were made")
        #expect(ax.attributeReads(on: items[0]) == 3, "all of them in the first item")
        #expect(items.dropFirst().allSatisfy { ax.attributeReads(on: $0) == 0 })
        #expect(app.itemTimeouts == 3)
        #expect(app.timedOut)
        #expect(app.items.isEmpty, "the item it stopped in wasn't read whole")
    }

    @Test func timedOutAppIsMarkedAndSkipped() async throws {
        let ax = FakeAX()
        ax.addApp(pid: 101, extras: [.init(title: "Fine", frame: CGRect(x: 10, y: 0, width: 20, height: 31))])
        let hungRoot = ax.root(ofApp: 102)
        ax.failReads(on: hungRoot, with: .timeout)
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(101, "com.example.fine", "Fine"), .fake(102, "com.example.hung", "Hung")], clock: clock)

        let first = await reader.snapshot(layout: .laptop)
        let hung = try #require(first.apps.first { $0.pid == 102 })
        #expect(hung.timedOut)
        #expect(hung.items.isEmpty)
        #expect(first.apps.first { $0.pid == 101 }?.timedOut == false)
        let readsAfterFirst = ax.attributeReads(on: hungRoot)
        #expect(readsAfterFirst >= 1)

        // Within 30 s it isn't asked again, and is still reported as timed out.
        clock.advance(by: .seconds(29))
        let second = await reader.snapshot(layout: .laptop)
        #expect(second.apps.first { $0.pid == 102 }?.timedOut == true)
        #expect(ax.attributeReads(on: hungRoot) == readsAfterFirst)

        // After 30 s it is asked again (and, still hung, skipped for another 30 s).
        clock.advance(by: .seconds(2))
        let third = await reader.snapshot(layout: .laptop)
        #expect(third.apps.first { $0.pid == 102 }?.timedOut == true)
        #expect(ax.attributeReads(on: hungRoot) > readsAfterFirst)
    }

    @Test func anAppThatRecoversIsReadAgainAfterTheSkip() async throws {
        let ax = FakeAX()
        let root = ax.root(ofApp: 102)
        ax.failReads(on: root, with: .timeout)
        let clock = FakeClock()
        let reader = reader(ax, apps: [.fake(102, "com.example.late", "Late")], clock: clock)
        #expect(await reader.snapshot(layout: .laptop).apps.first?.timedOut == true)

        ax.failReads(on: root, with: nil)
        ax.addApp(pid: 102, extras: [.init(title: "Back", frame: nil)])
        clock.advance(by: .seconds(31))
        let after = await reader.snapshot(layout: .laptop)
        #expect(after.apps.first?.timedOut == false)
        #expect(after.apps.first?.items.count == 1)
    }

    // MARK: Problems

    @Test func withoutAccessibilityTheSnapshotSaysSo() async {
        let (ax, apps) = smallDesk()
        for pid in [agentPID, 101, 102, 103, 104] {
            ax.failReads(on: ax.root(ofApp: pid), with: .notTrusted)
        }
        let snapshot = await reader(ax, apps: apps).snapshot(layout: .desk)
        #expect(snapshot.agentWindows.isEmpty)
        #expect(snapshot.apps.isEmpty)
        #expect(snapshot.problems == ["Device control and data access isn't granted to Mantel."])
    }

    @Test func withoutMenuBarAgentTheSnapshotSaysSo() async {
        let ax = FakeAX()
        let reader = MenuBarReader(ax: ax, runningApps: { [.fake(101, "com.example.a", "A")] })
        let snapshot = await reader.snapshot(layout: .laptop)
        #expect(snapshot.agentWindows.isEmpty)
        #expect(snapshot.problems == ["MenuBarAgent isn't running."])
    }
}
