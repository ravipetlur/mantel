import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// An icon's ID is its app's own name for it, or its place among the app's unnamed icons. The name a slot carries is never an ID.
@Suite("Inventory naming", .timeLimit(.minutes(1)))
struct InventoryNamingTests {
    private let own = "com.example.mantel"
    private let uuid = DisplayFixtures.laptopAlone.uuid
    private func slot(_ x: CGFloat, width: CGFloat = 40, name: String? = nil) -> AgentSlot {
        AgentSlot(frame: CGRect(x: x, y: 0, width: width, height: 30), identifier: name, role: "AXGroup", subrole: nil, description: nil,
                  ownerPID: nil, isOverflowChevron: false)
    }

    /// An app that lists one item per entry: `x` is where its frame is (six points inside a slot at `x`), nil for none.
    private func app(_ pid: pid_t, _ bundleID: String, _ items: [(name: String?, x: CGFloat?)]) -> AppExtras {
        AppExtras(pid: pid, bundleID: bundleID, name: nil, items: items.enumerated().map { place, item in
            ExtraItem(index: place, frame: item.x.map { CGRect(x: $0 + 6, y: 1, width: 28, height: 28) }, identifier: item.name, title: nil,
                      description: nil)
        }, timedOut: false)
    }

    private func bar(_ slots: [AgentSlot]) -> MatchBar {
        MatchBar(displayUUID: uuid, rect: CGRect(x: 0, y: 0, width: 2000, height: 30), slots: slots)
    }

    private func match(_ bars: [MatchBar], _ apps: [AppExtras], concealed: Set<String> = [], memory: inout IndexMemory) -> Inventory {
        InventoryMatcher.match(MatchInput(capturedAt: Date(timeIntervalSince1970: 0), layout: .laptop, bars: bars, apps: apps,
                                          ownBundleID: own, concealedApps: concealed), memory: &memory)
    }

    private func ids(_ inventory: Inventory, ofApp bundleID: String) -> [String] {
        inventory.items(ofApp: bundleID).map(\.id.string).sorted()
    }

    @Test func aSlotNameIsNeverAnItemsName() {
        var memory = IndexMemory()
        let inventory = match([bar([slot(100, name: "x.name")])], [app(1, "com.example.a", [(nil, 100)])], memory: &memory)
        #expect(ids(inventory, ofApp: "com.example.a") == ["com.example.a#0"])
    }

    @Test func anotherAppsNameOnASlotNamesNothing() {
        // A lists "a.one" and is concealed (its frame is nowhere); B's old frame is in the slot that carries that name.
        var memory = IndexMemory()
        let inventory = match([bar([slot(100, name: "a.one")])],
                              [app(1, "com.example.a", [("a.one", nil)]), app(2, "com.example.b", [(nil, 100)])],
                              concealed: ["com.example.a"], memory: &memory)
        #expect(ids(inventory, ofApp: "com.example.b") == ["com.example.b#0"])
        #expect(ids(inventory, ofApp: "com.example.a") == ["com.example.a::a.one"])
    }

    @Test func aNameOnTwoAppsSlotsOverTimeNamesNothing() {
        // "Main Menu" is on one slot of the bar. In one read it is under B's frame, in the next under C's.
        var memory = IndexMemory()
        let b = app(1, "com.example.b", [(nil, 100)]), c = app(2, "com.example.c", [(nil, 200)])
        let first = match([bar([slot(100, name: "Main Menu"), slot(200)])], [b, c], memory: &memory)
        let second = match([bar([slot(100), slot(200, name: "Main Menu")])], [b, c], memory: &memory)
        for read in [first, second] {
            #expect(ids(read, ofApp: "com.example.b") == ["com.example.b#0"])
            #expect(ids(read, ofApp: "com.example.c") == ["com.example.c#0"])
        }
    }

    @Test func aWrongNameIsNotCarriedToTheNextRead() {
        var memory = IndexMemory()
        let first = match([bar([slot(100, name: "x.name")])], [app(1, "com.example.b", [(nil, 100)])], memory: &memory)
        #expect(ids(first, ofApp: "com.example.b") == ["com.example.b#0"])
        // B is concealed now, with no slot: it is what it was.
        let second = match([bar([])], [app(1, "com.example.b", [(nil, nil)])], concealed: ["com.example.b"], memory: &memory)
        #expect(ids(second, ofApp: "com.example.b") == ["com.example.b#0"])
    }

    @Test func stackedFramesAtTheNotch() {
        // The laptop's two left-most drawn slots, and the frames of eight concealed apps' icons, all within a point of each other, right of
        // the notch. The test item names its two items, and its slots carry the names.
        let testItem = "com.example.testitem"
        let slots = [slot(1631.5, width: 32, name: "mantel.fixture.two"), slot(1663.5, width: 38, name: "mantel.fixture.one"), slot(1800)]
        var apps = [app(1, testItem, [("mantel.fixture.one", 1642), ("mantel.fixture.two", 1643)])]
        for number in 0..<8 { apps.append(app(pid_t(10 + number), "com.example.app\(number)", [(nil, 1641 + CGFloat(number) * 0.25)])) }
        var memory = IndexMemory()
        let inventory = match([bar(slots)], apps, concealed: Set(apps.dropFirst().compactMap(\.bundleID)), memory: &memory)

        #expect(ids(inventory, ofApp: testItem) == ["\(testItem)::mantel.fixture.one", "\(testItem)::mantel.fixture.two"])
        for number in 0..<8 { #expect(ids(inventory, ofApp: "com.example.app\(number)") == ["com.example.app\(number)#0"]) }
        // The slots that carry the test item's names are the test item's, whoever's old frame is in them.
        let one = inventory.items.first { $0.id.string == "\(testItem)::mantel.fixture.one" }
        #expect(one?.frames[uuid] == slots[1].frame)
    }

    @Test func aNamedSlotGoesToItsNamedItemBeforeFrames() {
        // A's own frame is somewhere else (old), and B's frame is nearer the slot that carries A's name.
        var memory = IndexMemory()
        let inventory = match([bar([slot(100, name: "a.one"), slot(300)])],
                              [app(1, "com.example.a", [("a.one", 300)]), app(2, "com.example.b", [(nil, 100)])], memory: &memory)
        let a = inventory.items.first { $0.id.string == "com.example.a::a.one" }
        #expect(a?.frames[uuid]?.minX == 100)
        let b = inventory.items.first { $0.id.string == "com.example.b#0" }
        #expect(b?.frames[uuid] == nil, "B's frame is in A's slot, and loses it")
    }
}
