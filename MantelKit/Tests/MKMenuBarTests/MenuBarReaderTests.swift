import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

private let agentPID: pid_t = 50
private let agentBundleID = "com.apple.MenuBarAgent"

private typealias RunningApp = (pid: pid_t, bundleID: String?, name: String?)

private func reader(_ ax: FakeAX, apps: [RunningApp], clock: any Clock = FakeClock()) -> MenuBarReader {
    let all = [(pid: agentPID, bundleID: Optional(agentBundleID), name: Optional("MenuBarAgent"))] + apps
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
        (101, "com.example.alpha", "Alpha"), (102, "com.example.beta", "Beta"),
        (103, "com.example.gamma", "Gamma"), (104, "com.example.quiet", "Quiet"),
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
        let snapshot = await reader(ax, apps: [(101, "com.example.alpha", "Alpha")]).snapshot(layout: .laptop, includeRawTree: false)
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
        let snapshot = await reader(ax, apps: [(200, "com.example.x", "X")]).snapshot(layout: .laptop, includeRawTree: false)
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

    @Test func timedOutAppIsMarkedAndSkipped() async throws {
        let ax = FakeAX()
        ax.addApp(pid: 101, extras: [.init(title: "Fine", frame: CGRect(x: 10, y: 0, width: 20, height: 31))])
        let hungRoot = ax.root(ofApp: 102)
        ax.failReads(on: hungRoot, with: .timeout)
        let clock = FakeClock()
        let reader = reader(ax, apps: [(101, "com.example.fine", "Fine"), (102, "com.example.hung", "Hung")], clock: clock)

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
        let reader = reader(ax, apps: [(102, "com.example.late", "Late")], clock: clock)
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
            apps.append((pid, "com.example.app\(index)", "App \(index)"))
        }
        let reader = reader(ax, apps: apps)

        let started = ContinuousClock.now
        let snapshot = await reader.snapshot(layout: .desk, includeRawTree: false)
        let elapsed = ContinuousClock.now - started

        #expect(snapshot.apps.count == 40)
        #expect(snapshot.allSlots.count == 40)
        // 300 ms is the aim; the assertion is looser so that a loaded machine doesn't make it flaky.
        #expect(elapsed < .seconds(1))
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
        let reader = reader(ax, apps: [(200, "com.example.x", "X")])

        let full = await reader.snapshot(layout: .laptop, includeRawTree: false)
        let agentOnly = await reader.agentSnapshot(layout: .laptop)
        #expect(full.allSlots.map(\.ownerPID) == [200, 200])
        #expect(agentOnly.allSlots.map(\.ownerPID) == [200, nil], "by identifier still, by frame no longer")
    }

    @Test func anAgentOnlyReadSaysWhatKeptItFromBeingWhole() async {
        let noAgent = MenuBarReader(ax: FakeAX(), runningApps: { [(pid: 101, bundleID: "com.example.a", name: "A")] })
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
            apps.append((pid, "com.example.app\(index)", "App \(index)"))
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
        let reader = MenuBarReader(ax: ax, runningApps: { [(pid: 101, bundleID: "com.example.a", name: "A")] })
        let snapshot = await reader.snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.agentWindows.isEmpty)
        #expect(snapshot.problems == ["MenuBarAgent isn't running."])
    }

    @Test func anAppWithoutABundleIDIsNotAsked() async {
        let ax = FakeAX()
        ax.addApp(pid: 300, extras: [.init(title: "Anonymous", frame: nil)])
        let root = ax.root(ofApp: 300)
        let snapshot = await reader(ax, apps: [(300, nil, "Anonymous")]).snapshot(layout: .laptop, includeRawTree: false)
        #expect(snapshot.apps.isEmpty)
        #expect(ax.attributeReads(on: root) == 0)
    }
}
