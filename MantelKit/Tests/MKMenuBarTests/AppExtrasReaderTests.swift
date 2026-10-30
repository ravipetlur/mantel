import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What an app's items call themselves, read from a fake Accessibility tree.
@Suite("App extras reader", .timeLimit(.minutes(1)))
struct AppExtrasReaderTests {
    private let app = RunningApp.fake(1001, "com.example.app", "App")

    private func items(_ outcome: ExtrasOutcome) -> AppExtras? {
        if case .items(let extras) = outcome { return extras }
        return nil
    }

    private func identifiers(_ outcome: ExtrasOutcome) -> [String?]? {
        items(outcome)?.items.map(\.identifier)
    }

    @Test func itemsAreReadWithTheirNames() {
        let ax = FakeAX()
        ax.addApp(pid: app.pid, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B")])
        let extras = items(AppExtrasReader(ax: ax).read(app))

        #expect(extras?.items.map(\.identifier) == ["a.one", nil])
        #expect(extras?.items.map(\.index) == [0, 1])
        #expect(extras?.itemTimeouts == 0)
    }

    @Test func identifierRememberedAcrossTimeout() {
        let ax = FakeAX()
        let nodes = ax.addApp(pid: app.pid, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B", identifier: "b.two"), .init(title: "C")])
        let reader = AppExtrasReader(ax: ax)
        #expect(identifiers(reader.read(app)) == ["a.one", "b.two", nil])

        // The app is slow to say its first two items' names (the read of each times out): they are called what they were called.
        let slow = Set(nodes.prefix(2))
        ax.setOverride { id, name in slow.contains(id) && name == AXName.identifier ? .failure(.timeout) : nil }
        let slowRead = items(reader.read(app))
        #expect(slowRead?.items.map(\.identifier) == ["a.one", "b.two", nil], "so that they don't turn into items with no name, and back")
        #expect(slowRead?.itemTimeouts == 2, "the timeouts are counted all the same")
        #expect(slowRead?.timedOut == false)

        // It answers again: what it says is what the items are called.
        ax.setOverride(nil)
        ax.setAttribute(AXName.identifier, .string("a.renamed"), on: nodes[0])
        #expect(identifiers(reader.read(app)) == ["a.renamed", "b.two", nil])

        // An item that answers with no name has none, and a timeout after that doesn't bring one back.
        ax.setAttribute(AXName.identifier, .string(""), on: nodes[1])
        #expect(identifiers(reader.read(app)) == ["a.renamed", nil, nil])
        ax.setOverride { id, name in id == nodes[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        #expect(identifiers(reader.read(app)) == ["a.renamed", nil, nil])
    }

    @Test func namesAreRememberedPerProcess() {
        let ax = FakeAX()
        let first = ax.addApp(pid: 1001, extras: [.init(title: "A", identifier: "a.one")])
        let second = ax.addApp(pid: 1002, extras: [.init(title: "A", identifier: "other.name")])
        let reader = AppExtrasReader(ax: ax)
        _ = reader.read(.fake(1001, "com.example.app"))
        _ = reader.read(.fake(1002, "com.example.other"))

        let slow = Set([first[0], second[0]])
        ax.setOverride { id, name in slow.contains(id) && name == AXName.identifier ? .failure(.timeout) : nil }
        #expect(identifiers(reader.read(.fake(1001, "com.example.app"))) == ["a.one"])
        #expect(identifiers(reader.read(.fake(1002, "com.example.other"))) == ["other.name"], "each process keeps its own")
        // An app that is started again is another process: nothing is known of its items.
        let again = ax.addApp(pid: 1003, extras: [.init(title: "A", identifier: "a.one")])
        ax.setOverride { id, name in id == again[0] && name == AXName.identifier ? .failure(.timeout) : nil }
        #expect(identifiers(reader.read(.fake(1003, "com.example.app"))) == [nil])
    }

    @Test func anIdentifierTimeoutWithNothingRememberedMarksTheNamesIncomplete() {
        let ax = FakeAX()
        let nodes = ax.addApp(pid: 1001, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B", identifier: "a.two")])
        let reader = AppExtrasReader(ax: ax)
        func extras(_ app: RunningApp) -> AppExtras? {
            if case .items(let extras) = reader.read(app) { extras } else { nil }
        }
        // A name that is read, and one that isn't read in time with nothing remembered of it: the read says its names aren't all known.
        ax.setOverride { id, name in id == nodes[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        #expect(extras(.fake(1001, "com.example.app"))?.namesIncomplete == true)

        // Read once, and then late: the name that was remembered stands for it, and the read is whole.
        ax.setOverride { _, _ in nil }
        #expect(extras(.fake(1001, "com.example.app"))?.namesIncomplete == false)
        ax.setOverride { id, name in id == nodes[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        let late = extras(.fake(1001, "com.example.app"))
        #expect(late?.namesIncomplete == false)
        #expect(late?.items.map(\.identifier) == ["a.one", "a.two"])
    }

    @Test func anItemThatWentMovesTheOthersAndWhatWasKeptForTheirPositionsIsNotUsed() {
        // An app lists an item with no name and then one with a name, and drops the first. The named item is now at the first position, and
        // a read of its name that times out there must not be taken for the nameless one's answer.
        let ax = FakeAX()
        let nodes = ax.addApp(pid: 1001, extras: [.init(title: "A"), .init(title: "B", identifier: "b.two")])
        let reader = AppExtrasReader(ax: ax)
        func extras() -> AppExtras? { items(reader.read(.fake(1001, "com.example.app"))) }
        #expect(extras()?.items.map(\.identifier) == [nil, "b.two"])

        ax.removeNode(nodes[0])
        ax.setOverride { id, name in id == nodes[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        let late = extras()
        #expect(late?.namesIncomplete == true, "the name isn't known: the position was another item's")
        #expect(late?.items.map(\.identifier) == [nil])
        // And the read after it, which times out the same: what that read learned of the list isn't what the first one's memory said of
        // another (a read that reached the end of the new list didn't learn this position again).
        let lateAgain = extras()
        #expect(lateAgain?.namesIncomplete == true, "still not known: nothing was learned of this position in the list as it is now")
        #expect(lateAgain?.items.map(\.identifier) == [nil])

        // The twin: a name that was kept for a position is not given to the item that is there now.
        let other = ax.addApp(pid: 1002, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B", identifier: "b.two")])
        ax.setOverride(nil)
        #expect(items(reader.read(.fake(1002, "com.example.other")))?.items.map(\.identifier) == ["a.one", "b.two"])
        ax.removeNode(other[0])
        ax.setOverride { id, name in id == other[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        let twin = items(reader.read(.fake(1002, "com.example.other")))
        #expect(twin?.items.map(\.identifier) == [nil], "not `a.one`")
        #expect(twin?.namesIncomplete == true)
        let twinAgain = items(reader.read(.fake(1002, "com.example.other")))
        #expect(twinAgain?.items.map(\.identifier) == [nil], "nor in the read after it")
        #expect(twinAgain?.namesIncomplete == true)

        // A list that is as long as it was is the one that was seen: what was kept stands for it.
        ax.setOverride(nil)
        #expect(items(reader.read(.fake(1002, "com.example.other")))?.items.map(\.identifier) == ["b.two"])
        ax.setOverride { id, name in id == other[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        let same = items(reader.read(.fake(1002, "com.example.other")))
        #expect(same?.items.map(\.identifier) == ["b.two"])
        #expect(same?.namesIncomplete == false)
    }

    @Test func twoItemsThatTradePlacesInAListOfTheSameLengthTakeNoNamesFromEachOther() {
        // Named items: `a.one` and `a.two` swap places. The one now first, `a.two`, has its name read late: what was kept for the first
        // position is `a.one`'s, and isn't given to it.
        let ax = FakeAX()
        let nodes = ax.addApp(pid: 1001, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B", identifier: "a.two")])
        let reader = AppExtrasReader(ax: ax)
        func extras() -> AppExtras? { items(reader.read(.fake(1001, "com.example.app"))) }
        #expect(extras()?.items.map(\.identifier) == ["a.one", "a.two"])
        #expect(extras()?.items.map(\.identifier) == ["a.one", "a.two"], "the same elements at the same places again: this app's elements hold")

        ax.swapPlaces(of: nodes[0], and: nodes[1])
        ax.setOverride { id, name in id == nodes[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        let swapped = extras()
        #expect(swapped?.items.map(\.identifier) == [nil, "a.one"], "the first isn't called `a.one`")
        #expect(swapped?.namesIncomplete == true)
        let again = extras()
        #expect(again?.items.map(\.identifier) == [nil, "a.one"], "nor in the read after it")
        #expect(again?.namesIncomplete == true)

        // A read that gets the names learns them again, at their new places.
        ax.setOverride(nil)
        #expect(extras()?.items.map(\.identifier) == ["a.two", "a.one"])
        ax.setOverride { id, name in id == nodes[1] && name == AXName.identifier ? .failure(.timeout) : nil }
        let settled = extras()
        #expect(settled?.items.map(\.identifier) == ["a.two", "a.one"])
        #expect(settled?.namesIncomplete == false, "what was learned stands for the element that gave it")
    }

    @Test func anAppThatGivesNewElementsAtEachReadKeepsItsNamesByPositionAndItsReadsWhole() {
        // The app's items are other elements each time they are listed: an element can't tell what an item is, and nothing may be asked of
        // it. What was kept for a position stands as it did before the elements were used, and an identifier that times out after a read
        // that answered leaves the read whole.
        let ax = FakeAX()
        ax.giveNewElementsAtEachRead()
        let nodes = ax.addApp(pid: 1001, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B", identifier: "a.two")])
        let nameless = ax.addApp(pid: 1002, extras: [.init(title: "A"), .init(title: "B")])
        let reader = AppExtrasReader(ax: ax)
        #expect(identifiers(reader.read(.fake(1001, "com.example.named"))) == ["a.one", "a.two"])
        #expect(identifiers(reader.read(.fake(1002, "com.example.nameless"))) == [nil, nil])
        #expect(items(reader.read(.fake(1001, "com.example.named")))?.namesIncomplete == false)
        #expect(items(reader.read(.fake(1002, "com.example.nameless")))?.namesIncomplete == false)

        ax.setOverride { id, name in (nodes + nameless).contains(id) && name == AXName.identifier ? .failure(.timeout) : nil }
        let late = items(reader.read(.fake(1001, "com.example.named")))
        #expect(late?.items.map(\.identifier) == ["a.one", "a.two"], "called what they were called")
        #expect(late?.namesIncomplete == false)
        let lateNameless = items(reader.read(.fake(1002, "com.example.nameless")))
        #expect(lateNameless?.items.map(\.identifier) == [nil, nil])
        #expect(lateNameless?.namesIncomplete == false, "seen to have no name a moment ago: the read is whole, as it is when elements hold")
        #expect(lateNameless?.itemTimeouts == 2)
    }

    @Test func aListCutBeforeItsLastChildIsMarkedCut() {
        // The reading of an app that doesn't answer stops at the third timeout: the children after it are not read.
        let ax = FakeAX()
        let nodes = ax.addApp(pid: 1001, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B", identifier: "a.two"),
                                                  .init(title: "C", identifier: "a.three"), .init(title: "D", identifier: "a.four")])
        let reader = AppExtrasReader(ax: ax)
        let whole = items(reader.read(.fake(1001, "com.example.app")))
        #expect(whole?.listCut == false)
        #expect(whole?.items.count == 4)

        // The second and third children don't answer: the reading stops in the third, with the fourth unread.
        let slow = Set(nodes[1...2])
        ax.setOverride { id, _ in slow.contains(id) ? .failure(.timeout) : nil }
        let cut = items(reader.read(.fake(1001, "com.example.app")))
        #expect(cut?.timedOut == true)
        #expect(cut?.listCut == true, "children are left that the list doesn't have")
        #expect((cut?.items.count ?? 4) < 4)
    }

    @Test func aProcessIDThatAnotherAppHasTakenInheritsNoNames() {
        let ax = FakeAX()
        let nodes = ax.addApp(pid: 1001, extras: [.init(title: "A", identifier: "a.one")])
        let reader = AppExtrasReader(ax: ax)
        _ = reader.read(.fake(1001, "com.example.app"))

        // The first app quits and another gets its process ID: the names are the first app's.
        ax.setOverride { id, name in id == nodes[0] && name == AXName.identifier ? .failure(.timeout) : nil }
        #expect(reader.names.name(of: ax.ref(nodes[0]), ofProcess: 1001, bundleID: "com.example.other", at: 0) == nil)
        guard case .items(let extras) = reader.read(.fake(1001, "com.example.other")) else {
            Issue.record("the app answers")
            return
        }
        #expect(extras.items.map(\.identifier) == [nil])
        #expect(extras.namesIncomplete)
    }

    @Test func theElementsComeWithTheItems() throws {
        let ax = FakeAX()
        let nodes = ax.addApp(pid: app.pid, extras: [.init(title: "A", identifier: "a.one"), .init(title: "B")])
        let read = AppExtrasReader(ax: ax).readWithElements(app)

        #expect(read.elements.map(ax.id(of:)) == nodes)
        #expect(identifiers(read.outcome) == ["a.one", nil])
        let none = AppExtrasReader(ax: ax).readWithElements(.fake(1009, "com.example.none"))
        #expect(none.elements.isEmpty)
        if case .noExtras = none.outcome {} else { Issue.record("an app with no extras has none") }
    }
}
