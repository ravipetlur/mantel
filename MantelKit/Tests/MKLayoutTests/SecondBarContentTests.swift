import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// Which icons the second bar and a group's panel list, and in what order.
@Suite("Second bar content", .timeLimit(.minutes(1)))
struct SecondBarContentTests {
    private func bundle(_ name: String) -> String { "com.example.\(name)" }

    private func id(_ name: String) -> ItemID {
        ItemID(bundleID: bundle(name), key: .identifier("main"))
    }

    private func menuItem(_ id: ItemID, appName: String? = nil, frame: CGRect? = nil, mantel: Bool = false,
                          kind: OwnItemKind? = nil) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: appName, label: nil, frames: frame.map { ["main": $0] } ?? [:],
                    overflowedOn: [], isMantel: mantel, ownKind: kind)
    }

    private func inventory(_ items: [MenuBarItem]) -> Inventory {
        Fixtures.inventory(items)
    }

    private let upper: [String: String] = [
        "com.example.a": "Alpha", "com.example.b": "Bravo", "com.example.c": "Charlie", "com.example.d": "Delta",
        "com.example.e": "Echo", "com.example.g1": "Golf", "com.example.g2": "Hotel", "com.example.g3": "India",
        "com.example.z": "Zulu", "com.example.y": "Yankee",
    ]

    private func running(_ names: [String]) -> Set<String> { Set(names.map(bundle)) }

    /// What a test lists from: the model, the inventory, and the two groups.
    private struct Desk {
        var model: SectionModel
        var inventory: Inventory
        let first: GroupID
        let second: GroupID
    }

    /// The desk this suite uses: Hidden holds b, a and c (in that order), Always Hidden holds e and d, and two groups: the second added
    /// first, so the order of the groups isn't the order of their names. `first` holds g1 and g2, `second` holds g3.
    private func desk() -> Desk {
        let names = ["b", "a", "c", "e", "d", "g1", "g2", "g3"]
        let items = names.map { menuItem(id($0), appName: upper[bundle($0)]) }
        var model = SectionModel()
        for name in ["b", "a", "c"] { model.move(app: bundle(name), to: .hidden) }
        for name in ["e", "d", "g1", "g2", "g3"] { model.move(app: bundle(name), to: .alwaysHidden) }
        model.note(items)
        let first = GroupID(rawValue: "0000000a")
        let second = GroupID(rawValue: "0000000b")
        model.addGroup(IconGroup(id: second, title: "Two", members: [bundle("g3")]), in: .shown, at: 0)
        model.addGroup(IconGroup(id: first, title: "One", members: [bundle("g1"), bundle("g2")]), in: .shown, at: 0)
        return Desk(model: model, inventory: inventory(items), first: first, second: second)
    }

    private func entries(_ level: RevealLevel, _ desk: Desk, only: Set<String>? = nil, turnedOff: Set<String> = [],
                         widths: ItemWidthCache = ItemWidthCache(), allowClock: Bool = false) -> [SecondBarEntry] {
        SecondBarContent.entries(level: level, sections: desk.model, inventory: desk.inventory,
                                 running: only ?? running(["a", "b", "c", "d", "e", "g1", "g2", "g3"]), turnedOff: turnedOff,
                                 names: upper, widths: widths, allowClockAndControlCenter: allowClock)
    }

    private func names(_ entries: [SecondBarEntry]) -> [String] {
        entries.map { $0.id.bundleID.replacingOccurrences(of: "com.example.", with: "") }
    }

    @Test func hiddenLevelListsHiddenInOrder() {
        let desk = desk()
        let listed = entries(.hidden, desk)
        // The order of the layout editor, not the alphabet's; and nothing of Always Hidden or the groups.
        #expect(names(listed) == ["b", "a", "c"])
        #expect(listed.map(\.title) == ["Bravo", "Alpha", "Charlie"])
        #expect(listed.allSatisfy { $0.section == .hidden && $0.group == nil && !$0.startsBlock })
        #expect(listed.map(\.id) == [id("b"), id("a"), id("c")])
        // A reveal that shows nothing lists nothing.
        #expect(entries(.off, desk).isEmpty)
    }

    @Test func allLevelAddsAlwaysHiddenThenGroups() {
        let desk = desk()
        let listed = entries(.all, desk)
        // Hidden's, Always Hidden's, then each group's in the order of the groups (G2 was added first), members in order.
        #expect(names(listed) == ["b", "a", "c", "e", "d", "g3", "g1", "g2"])
        #expect(listed.map(\.section) == [.hidden, .hidden, .hidden, .alwaysHidden, .alwaysHidden,
                                          .alwaysHidden, .alwaysHidden, .alwaysHidden])
        #expect(listed.map(\.group) == [nil, nil, nil, nil, nil, desk.second, desk.first, desk.first])
        // Grouped apps are never in a reveal of Hidden alone.
        #expect(!names(entries(.hidden, desk)).contains("g1"))
    }

    @Test func blocksStartWithSeparator() {
        let desk = desk()
        // Always Hidden's first, and each group's first, start a block: a thin separator goes before them.
        #expect(entries(.all, desk).map(\.startsBlock) == [false, false, false, true, false, true, true, false])
        // Nothing comes before the first cell, whichever block it is in.
        var emptyHidden = desk.model
        for name in ["b", "a", "c"] { emptyHidden.move(app: bundle(name), to: .alwaysHidden) }
        let listed = entries(.all, Desk(model: emptyHidden, inventory: desk.inventory, first: desk.first, second: desk.second))
        #expect(names(listed).prefix(3) == ["e", "d", "b"])
        #expect(listed.first?.startsBlock == false)
        #expect(listed.dropFirst().filter(\.startsBlock).count == 2, "the two groups")
        // A group with nothing to list adds no separator.
        let quiet = running(["a", "b", "c", "d", "e", "g1", "g2"])
        #expect(entries(.all, desk, only: quiet).map(\.startsBlock) == [false, false, false, true, false, true, false])
    }

    @Test func notRunningLeftOut() {
        let desk = desk()
        let listed = entries(.all, desk, only: running(["a", "e", "g2"]))
        #expect(names(listed) == ["a", "e", "g2"])
        // Nothing is running: nothing is listed.
        #expect(entries(.all, desk, only: []).isEmpty)
    }

    @Test func turnedOffLeftOut() {
        let desk = desk()
        // macOS doesn't draw an app that is turned off in System Settings, so a click can't show it.
        let listed = entries(.all, desk, turnedOff: [bundle("a"), bundle("g1")])
        #expect(names(listed) == ["b", "c", "e", "d", "g3", "g2"])
    }

    @Test func ownItemsNeverListed() {
        var desk = desk()
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "00000001"))
        desk.model.addSpacer(spacer, in: .hidden, at: 1)
        desk.model.addGroup(IconGroup(id: GroupID(rawValue: "0000000c")), in: .hidden, at: 0)
        // Mantel's own icons, as the inventory has them: its dots and divider are never in the model's lists, and if one were, it is
        // still not listed.
        let dot = ItemID(bundleID: bundle("mantel"), key: .identifier("mantel.dot.hidden"))
        let divider = ItemID(bundleID: bundle("mantel"), key: .identifier("mantel.divider.main"))
        desk.model.insert(dot, in: .hidden, at: 0)
        desk.model.insert(divider, in: .alwaysHidden, at: 0)
        let own = [menuItem(dot, mantel: true, kind: .hiddenDot), menuItem(divider, mantel: true, kind: .divider),
                   menuItem(ItemID(bundleID: bundle("mantel"), key: .identifier("invisible")), mantel: true)]
        desk.inventory = inventory(desk.inventory.items + own)
        let present = running(["a", "b", "c", "d", "e", "g1", "g2", "g3", "mantel"])

        #expect(desk.model.items(in: .hidden).contains(OwnItems.itemID(spacer.id)), "the spacer is in the list")
        let listed = entries(.all, desk, only: present)
        #expect(names(listed) == ["b", "a", "c", "e", "d", "g3", "g1", "g2"])
    }

    @Test func unorderedAppAppendedByName() {
        var desk = desk()
        // Three apps that are running and placed, whose icons the inventory has and the model's lists don't yet: they come at the end of
        // their block, by name and not by the order the inventory has them in.
        let extra = ["z", "y"].map { menuItem(id($0), appName: upper[bundle($0)]) }
        desk.inventory = inventory(desk.inventory.items + extra)
        desk.model.move(app: bundle("z"), to: .hidden)
        desk.model.move(app: bundle("y"), to: .hidden)
        let present = running(["a", "b", "c", "d", "e", "g1", "g2", "g3", "y", "z"])
        #expect(names(entries(.hidden, desk, only: present)) == ["b", "a", "c", "y", "z"])

        // The same in Always Hidden, and in a group.
        desk.model.move(app: bundle("z"), to: .alwaysHidden)
        desk.model.move(app: bundle("y"), toGroup: desk.first, at: Int.max)
        let listed = entries(.all, desk, only: present)
        #expect(names(listed) == ["b", "a", "c", "e", "d", "z", "g3", "g1", "g2", "y"])
        // An app that is placed but whose app the inventory doesn't have has nothing to list.
        desk.model.move(app: bundle("x"), to: .hidden)
        #expect(names(entries(.hidden, desk, only: present.union([bundle("x")]))) == ["b", "a", "c"])
    }

    @Test func groupEntriesOnlyMembers() {
        let desk = desk()
        func group(_ group: GroupID, only: Set<String>? = nil) -> [SecondBarEntry] {
            SecondBarContent.entries(group: group, sections: desk.model, inventory: desk.inventory,
                                     running: only ?? running(["a", "b", "c", "d", "e", "g1", "g2", "g3"]), turnedOff: [],
                                     names: upper, widths: ItemWidthCache())
        }
        let one = group(desk.first)
        #expect(names(one) == ["g1", "g2"])
        #expect(one.map(\.title) == ["Golf", "Hotel"])
        #expect(one.allSatisfy { $0.group == desk.first && $0.section == .alwaysHidden })
        // One block, with nothing to separate: no separators.
        #expect(one.allSatisfy { !$0.startsBlock })
        #expect(names(group(desk.second)) == ["g3"])
        // A member that isn't running is left out, and a group nobody has built has nothing.
        #expect(names(group(desk.first, only: running(["g2"]))) == ["g2"])
        #expect(group(GroupID(rawValue: "0000ffff")).isEmpty)
    }

    @Test func systemModuleListedWhenAllowed() {
        var model = SectionModel()
        let wifi = ItemID.system("wifi"), clock = ItemID.system("clock"), airdrop = ItemID.system("airdrop")
        let control = ItemID.system("controlcenter")
        for item in [wifi, clock, airdrop, control] { model.insert(item, in: .hidden, at: Int.max) }
        model.insert(id("a"), in: .hidden, at: 0)
        let items = [wifi, clock, airdrop, control, id("a")].map { menuItem($0) }
        let desk = Desk(model: model, inventory: inventory(items), first: GroupID(rawValue: "0"), second: GroupID(rawValue: "1"))

        // Wi-Fi has a number to hide it by; AirDrop has none, so it can't be hidden and is never listed; the clock and Control Center
        // only when hiding them is allowed (they never leave the bar otherwise).
        let plain = entries(.hidden, desk, only: running(["a"]))
        #expect(plain.map(\.id) == [id("a"), wifi])
        #expect(plain.map(\.title) == ["Alpha", "Wi-Fi"])
        let allowed = entries(.hidden, desk, only: running(["a"]), allowClock: true)
        #expect(allowed.map(\.id) == [id("a"), wifi, clock, control])
        #expect(allowed.map(\.title) == ["Alpha", "Wi-Fi", "Clock", "Control Center"])
        // A system item never needs an app to be running.
        #expect(entries(.hidden, desk, only: []).map(\.id) == [wifi])
    }

    @Test func entryWidthIsClampedSlotWidth() {
        let desk = desk()
        func drawn(_ name: String, width: CGFloat) -> MenuBarItem {
            menuItem(id(name), frame: CGRect(x: 100, y: 1, width: width, height: 30))
        }
        var cache = ItemWidthCache()
        cache.update(from: inventory([drawn("b", width: 10), drawn("a", width: 50), drawn("c", width: 200)]))
        let listed = entries(.hidden, desk, widths: cache)
        // Narrower than 30 is 30, in between is as it is, wider than 120 is 120.
        #expect(listed.map(\.width) == [30, 50, 120])
        // An icon whose slot was never seen gets the narrowest cell.
        let unseen = entries(.all, desk, widths: cache)
        #expect(unseen.dropFirst(3).allSatisfy { $0.width == 30 })
        #expect(SecondBarGeometry.cellWidth(slotWidth: nil) == 30)
        #expect(SecondBarGeometry.cellWidth(slotWidth: 29.9) == 30)
        #expect(SecondBarGeometry.cellWidth(slotWidth: 30) == 30)
        #expect(SecondBarGeometry.cellWidth(slotWidth: 75.5) == 75.5)
        #expect(SecondBarGeometry.cellWidth(slotWidth: 120) == 120)
        #expect(SecondBarGeometry.cellWidth(slotWidth: 120.1) == 120)
    }
}
