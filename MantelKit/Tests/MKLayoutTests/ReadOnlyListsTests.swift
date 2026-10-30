import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Read-only lists", .timeLimit(.minutes(1)))
struct ReadOnlyListsTests {
    private let frame = CGRect(x: 100, y: 0, width: 30, height: 30)

    private func make(_ inventory: Inventory, sections: SectionModel = SectionModel(), running: Set<String> = [],
                      turnedOff: TurnedOffList = .apps([])) -> ReadOnlyLists {
        ReadOnlyLists.make(inventory: inventory, sections: sections, running: running, turnedOff: turnedOff)
    }

    @Test func cantMoveListsClockAndControlCenter() {
        let inventory = Fixtures.inventory([
            Fixtures.item(.system("wifi"), frame: frame),
            Fixtures.item(.system("clock"), frame: frame),
            Fixtures.item(Fixtures.itemID("com.example.a"), frame: frame),
            Fixtures.item(.system("controlcenter"), frame: frame),
        ])
        #expect(make(inventory).cantMove == [.system("clock"), .system("controlcenter")])

        // Only the ones that are in the menu bar, and an app's item that is called "clock" is not the system's.
        let without = Fixtures.inventory([Fixtures.item(.system("wifi"), frame: frame),
                                          Fixtures.item(Fixtures.itemID("com.example.a", "clock"), frame: frame)])
        #expect(make(without).cantMove.isEmpty)
        #expect(make(.empty).cantMove.isEmpty)
    }

    @Test func missingListsOnlyNonDefaultPlacements() {
        var sections = SectionModel()
        sections.move(app: "com.example.zeta", to: .hidden)
        sections.move(app: "com.example.alpha", to: .alwaysHidden)
        sections.move(app: "com.example.running", to: .hidden)
        // Placed in the new-items section when first seen, and moved to Shown by the person: both are what a new app gets anyway,
        // so there is nothing to forget.
        sections.assignNew(apps: ["com.example.default"])
        sections.move(app: "com.example.shown", to: .shown)
        // Put on trial by automatic overflow (Shown, and automatic) and gone: that differs from the default.
        sections.apps["com.example.auto"] = AppPlacement(section: .shown, isAuto: true)

        let lists = make(.empty, sections: sections, running: ["com.example.running"])
        #expect(lists.missing == ["com.example.alpha", "com.example.auto", "com.example.zeta"])

        // What a new app gets follows the new-items section: now it is Hidden, so the Hidden apps are the default ones.
        sections.newItems = .hidden
        let hiddenDefault = make(.empty, sections: sections, running: [])
        #expect(hiddenDefault.missing == ["com.example.alpha", "com.example.auto", "com.example.default", "com.example.shown"])
    }

    @Test func unansweredRunningAppIsNotMissing() {
        var sections = SectionModel()
        sections.move(app: "com.example.slow", to: .hidden)
        sections.move(app: "com.example.gone", to: .hidden)
        // The slow app is running but didn't answer when asked for its items, so the inventory has none of them.
        let inventory = Fixtures.inventory([], unansweredApps: ["com.example.slow"])
        let lists = make(inventory, sections: sections, running: ["com.example.slow"])
        #expect(lists.missing == ["com.example.gone"])
    }

    @Test func overflowListsOverflowedItems() {
        let overflowed = Fixtures.itemID("com.example.a", "one")
        let behindTheNotch = Fixtures.itemID("com.example.b")
        let inventory = Fixtures.inventory([
            Fixtures.item(overflowed, frame: frame, overflowed: true),
            Fixtures.item(Fixtures.itemID("com.example.c"), frame: frame),
            Fixtures.item(behindTheNotch, overflowed: true),
            // Concealed, framed nowhere: not in the overflow.
            Fixtures.item(Fixtures.itemID("com.example.d")),
        ])
        #expect(make(inventory).overflow == [overflowed, behindTheNotch])
    }

    @Test func cantHideYetListsUnknownModules() {
        let inventory = Fixtures.inventory([
            Fixtures.item(.system("wifi"), frame: frame),
            Fixtures.item(.system("airdrop"), frame: frame),
            Fixtures.item(.system("battery"), frame: frame),
            Fixtures.item(.system("somethingnew"), frame: frame),
            Fixtures.item(Fixtures.itemID("com.example.a"), frame: frame),
        ])
        #expect(make(inventory).cantHideYet == [.system("airdrop"), .system("somethingnew")])
    }

    @Test func turnedOffPassesThrough() {
        #expect(make(.empty, turnedOff: .unavailable("Mantel can't read this list on this Mac.")).turnedOff
            == .unavailable("Mantel can't read this list on this Mac."))
        #expect(make(.empty, turnedOff: .apps(["com.example.b", "com.example.a"])).turnedOff == .apps(["com.example.b", "com.example.a"]))
    }

    @Test func cantReorderListsUnresolved() {
        let nameless = ItemID(bundleID: "com.example.a", key: .index(0))
        let other = ItemID(bundleID: "com.example.b", key: .index(1))
        let quit = ItemID(bundleID: "com.example.c", key: .index(0))
        #expect(make(.empty).cantReorder.isEmpty)
        let inventory = Fixtures.inventory([Fixtures.item(nameless, frame: frame), Fixtures.item(other, frame: frame)])
        let lists = ReadOnlyLists.make(inventory: inventory, sections: SectionModel(), running: [], turnedOff: .apps([]),
                                       unresolved: [nameless, other, quit])
        // An item the inventory doesn't hold (its app has quit) isn't listed.
        #expect(lists.cantReorder == [nameless, other])
    }
}
