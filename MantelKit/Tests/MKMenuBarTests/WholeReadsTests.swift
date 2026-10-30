import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Whole reads", .timeLimit(.minutes(1)))
struct WholeReadsTests {
    private func read(processes: [String: Set<Int32>], incomplete: Set<String> = [], unanswered: Set<String> = [],
                      reach: [AppReach] = []) -> Inventory {
        let items = processes.keys.sorted().map { bundleID in
            MenuBarItem(id: ItemID(bundleID: bundleID, key: .index(0)), ownerBundleID: bundleID, appName: nil, label: nil, frames: [:],
                        overflowedOn: [], isMantel: false)
        }
        return Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: items, chevrons: [:], reach: reach, problems: [],
                         unansweredApps: unanswered, incompleteApps: incomplete, appProcesses: processes)
    }

    @Test func anAppReadForTheFirstTimeIsWholeAndAnIncompleteOrUnansweredOneIsNot() {
        var reads = WholeReads()
        let running: Set<String> = ["a", "b", "c"]
        #expect(reads.wholeApps(in: read(processes: ["a": [1], "b": [2], "c": [3]], incomplete: ["b"], unanswered: ["c"]), running: running) == ["a"])
    }

    @Test func aListCutBeforeItsLastChildIsNotWhole() {
        // The read of an app that stopped before the last child of its list (here by the timeout that ends a reading; the apps that answered
        // late or whole say nothing of it, as they are not unanswered): the matcher says the app isn't known whole, and so does the gate.
        func inventory(listCut: Bool) -> Inventory {
            var memory = IndexMemory()
            let app = AppExtras(pid: 7, bundleID: "a", name: nil, items: [ExtraItem(index: 0, frame: nil, identifier: nil, title: nil, description: nil)],
                                timedOut: false, listCut: listCut)
            return InventoryMatcher.match(MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .laptop, bars: [], apps: [app],
                                                     ownBundleID: "own", concealedApps: []), memory: &memory)
        }
        var reads = WholeReads()
        #expect(reads.wholeApps(in: inventory(listCut: true), running: ["a"]).isEmpty)
        #expect(inventory(listCut: true).incompleteApps == ["a"])
        var whole = WholeReads()
        #expect(whole.wholeApps(in: inventory(listCut: false), running: ["a"]) == ["a"])
    }

    /// A read with a main bar and these icons, each with the display UUIDs it has a frame on, in a cut read of MenuBarAgent (or not).
    private func read(icons: [(app: String, n: Int, frames: [String])], cut: Bool, system: [String] = []) -> Inventory {
        let bars = [MenuBarGeometry(displayUUID: "main", rect: CGRect(x: 0, y: 0, width: 1000, height: 30), notch: nil),
                    MenuBarGeometry(displayUUID: "other", rect: CGRect(x: 1000, y: 0, width: 1000, height: 30), notch: nil)]
        var items = icons.map { icon in
            MenuBarItem(id: ItemID(bundleID: icon.app, key: .index(icon.n)), ownerBundleID: icon.app, appName: nil, label: nil,
                        frames: Dictionary(uniqueKeysWithValues: icon.frames.map { ($0, CGRect(x: 10, y: 0, width: 20, height: 20)) }),
                        overflowedOn: [], isMantel: false)
        }
        items += system.map { module in
            MenuBarItem(id: ItemID(bundleID: "a", key: .system(module: module)), ownerBundleID: "a", appName: nil, label: nil, frames: [:],
                        overflowedOn: [], isMantel: false)
        }
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars, items: items, chevrons: [:], reach: [], problems: [],
                             appProcesses: Dictionary(uniqueKeysWithValues: Set(icons.map(\.app)).map { ($0, [Int32(1)]) }))
        return cut ? read.markingAgentReadCut() : read
    }

    @Test func aReadOfMenuBarAgentThatWasCutIsNotWholeForAnAppWhoseIconsItPlacesInMoreThanOneGroupAndIsForOneWithOne() {
        // The read orders an app's icons: on the main bar, then only on another bar, then those without a frame. A slot that lacks its
        // frame can move an icon from one group to another.
        let running: Set<String> = ["a", "b"]
        for (name, frames) in [("one on the main bar, one without a frame", [["main"], []]),
                               ("one on the main bar, one only on another bar", [["main"], ["other"]]),
                               ("one only on another bar, one without a frame", [["other"], []])] {
            let cut = read(icons: [("a", 0, frames[0]), ("a", 1, frames[1]), ("b", 0, [])], cut: true)
            var reads = WholeReads()
            #expect(reads.wholeApps(in: cut, running: running) == ["b"], "\(name): the order of two icons isn't known")
            // The processes are remembered all the same: the next read that wasn't cut is the second of the same processes.
            let uncut = read(icons: [("a", 0, frames[0]), ("a", 1, frames[1]), ("b", 0, [])], cut: false)
            #expect(reads.wholeApps(in: uncut, running: running) == ["a", "b"], "\(name)")
            var fresh = WholeReads()
            #expect(fresh.wholeApps(in: uncut, running: running) == ["a", "b"], "\(name)")
        }
    }
}
