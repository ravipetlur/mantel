import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Layout key resolver", .timeLimit(.minutes(1)))
struct LayoutKeyResolverTests {
    private typealias F = ArrangementFixtures

    private func rules(_ match: KeyMatchRule, _ reference: DistanceReference = .rightEdge) -> LayoutRules {
        var rules = F.rules(reference)
        rules.keyMatch = match
        return rules
    }

    private func resolve(_ tokens: [LayoutToken], table: LayoutTableSnapshot = LayoutTableSnapshot(distances: [:]),
                         inventory: Inventory = .empty, match: KeyMatchRule = .identifiersOnly, reference: DistanceReference = .rightEdge,
                         memory: [ItemID: String] = [:], concealed: Set<String> = [], stayingStart: Double? = nil,
                         earlierKeys: [ItemID: String] = [:]) -> LayoutKeyResolution {
        LayoutKeyResolver.resolve(tokens: tokens, table: table, inventory: inventory, ownBundleID: F.ownBundle,
                                  rules: rules(match, reference), memory: memory, concealedApps: concealed, stayingStart: stayingStart,
                                  earlierKeys: earlierKeys)
    }

    @Test func ownTokensUseOwnBundle() {
        let spacer = OwnItems.itemID(SpacerID(rawValue: "0000abcd"))
        let group = OwnItems.itemID(GroupID(rawValue: "0000beef"))
        // The table has none of them: they are what the writer adds.
        let resolution = resolve([.dot(.hidden), .dot(.always), .divider, .item(spacer), .item(group)])
        #expect(resolution.keys == [
            .dot(.hidden): "status:com.example.mantel::mantel.dot.hidden",
            .dot(.always): "status:com.example.mantel::mantel.dot.always",
            .divider: "status:com.example.mantel::mantel.divider.main",
            .item(spacer): "status:com.example.mantel::mantel.spacer.0000abcd",
            .item(group): "status:com.example.mantel::mantel.group.0000beef",
        ])
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func identifierKeys() {
        let a = F.app("a", "weather"), b = F.app("b", "NSStatusItem Item::1")
        let table = F.table([F.key(a): 80, F.key(b): 120])
        let resolution = resolve([.item(a), .item(b)], table: table)
        #expect(resolution.keys == [.item(a): "status:com.example.a::weather", .item(b): "status:com.example.b::NSStatusItem Item::1"])
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func autosaveIndexKeys() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1), third = F.nameless("a", 2)
        let table = F.table(["status:com.example.a::Item-0": 80, "status:com.example.a::Item-1": 120])
        let resolution = resolve([.item(first), .item(second), .item(third)], table: table, match: .autosaveIndex(prefix: "Item-"))
        #expect(resolution.keys == [.item(first): "status:com.example.a::Item-0", .item(second): "status:com.example.a::Item-1"])
        #expect(resolution.unresolved == [third])
    }

    /// An app with two nameless items drawn on a bar 1000 wide, at the right edge 960 (30 from the bar's right edge) and 900 (90).
    private func twoSlots(extra: [MenuBarItem] = []) -> Inventory {
        F.inventory([F.drawn(F.nameless("a", 0), x: 900, width: 30), F.drawn(F.nameless("a", 1), x: 830, width: 30)] + extra)
    }

    @Test func byDistanceMatchesOneToOne() {
        // Right edges are 1000 - 930 = 70 and 1000 - 860 = 140. Three keys are near them: the one at 72 is nearest the first slot, the one
        // at 75 would match it too but is taken, and the second slot takes the one at 138.
        let table = F.table(["status:com.example.a::Item-0": 75, "status:com.example.a::Item-1": 138, "status:com.example.a::Item-2": 72])
        let resolution = resolve([.item(F.nameless("a", 0)), .item(F.nameless("a", 1))], table: table, inventory: twoSlots(),
                                 match: .byDistance(tolerance: 10))
        #expect(resolution.keys[.item(F.nameless("a", 0))] == "status:com.example.a::Item-2")
        #expect(resolution.keys[.item(F.nameless("a", 1))] == "status:com.example.a::Item-1")
        #expect(resolution.unresolved.isEmpty)

        // One key between two slots serves one of them.
        let single = F.table(["status:com.example.a::Item-0": 100])
        let one = resolve([.item(F.nameless("a", 0)), .item(F.nameless("a", 1))], table: single, inventory: twoSlots(),
                          match: .byDistance(tolerance: 50))
        #expect(one.keys.count == 1)
        #expect(one.unresolved.count == 1)

        // Beyond the tolerance there is no match.
        let far = resolve([.item(F.nameless("a", 0))], table: F.table(["status:com.example.a::Item-0": 90]), inventory: twoSlots(),
                          match: .byDistance(tolerance: 10))
        #expect(far.keys.isEmpty)
        #expect(far.unresolved == [F.nameless("a", 0)])
    }

    @Test func byDistanceConcealedKeepsMemory() {
        let drawn = F.nameless("a", 0), hiding = F.nameless("a", 1)
        let inventory = F.inventory([F.drawn(drawn, x: 900, width: 30), F.concealed(hiding)])
        let table = F.table(["status:com.example.a::Item-0": 70, "status:com.example.a::Item-1": 400])
        let resolution = resolve([.item(drawn), .item(hiding)], table: table, inventory: inventory, match: .byDistance(tolerance: 10),
                                 memory: [hiding: "status:com.example.a::Item-1"])
        #expect(resolution.keys[.item(hiding)] == "status:com.example.a::Item-1")
        #expect(resolution.keys[.item(drawn)] == "status:com.example.a::Item-0")

        // Without a memory it stays unresolved, and a key the table no longer holds isn't kept.
        let forgotten = resolve([.item(drawn), .item(hiding)], table: table, inventory: inventory, match: .byDistance(tolerance: 10))
        #expect(forgotten.unresolved == [hiding])
        let gone = resolve([.item(hiding)], table: F.table([:]), inventory: inventory, match: .byDistance(tolerance: 10),
                           memory: [hiding: "status:com.example.a::Item-1"])
        #expect(gone.unresolved == [hiding])
    }

    @Test func orderOnlyKeepsTheRememberedKeyOfADrawnItem() {
        let drawn = F.nameless("a", 0)
        let inventory = F.inventory([F.drawn(drawn, x: 900, width: 30)])
        let table = F.table(["status:com.example.a::Item-0": 70])
        let remembered = [drawn: "status:com.example.a::Item-0"]
        // With no distances to compare nothing is matched anew, so a drawn item keeps what it had.
        let kept = resolve([.item(drawn)], table: table, inventory: inventory, match: .byDistance(tolerance: 10), reference: .orderOnly,
                           memory: remembered)
        #expect(kept.keys[.item(drawn)] == "status:com.example.a::Item-0")
        #expect(kept.memory == remembered)
        // With distances, a drawn item is matched again, and a memory the table no longer holds isn't kept.
        let gone = resolve([.item(drawn)], table: F.table([:]), inventory: inventory, match: .byDistance(tolerance: 10),
                           reference: .orderOnly, memory: remembered)
        #expect(gone.unresolved == [drawn])
    }

    @Test func memoryIsReturned() {
        let drawn = F.nameless("a", 0), hiding = F.nameless("a", 1), other = F.nameless("b", 0)
        let inventory = F.inventory([F.drawn(drawn, x: 900, width: 30), F.concealed(hiding), F.concealed(other)])
        let table = F.table(["status:com.example.a::Item-0": 70, "status:com.example.a::Item-1": 400])
        let resolution = resolve([.item(drawn), .item(hiding), .item(other)], table: table, inventory: inventory,
                                 match: .byDistance(tolerance: 10), memory: [hiding: "status:com.example.a::Item-1"])
        // The match made and the one kept; the item with no key has none.
        #expect(resolution.memory == [drawn: "status:com.example.a::Item-0", hiding: "status:com.example.a::Item-1"])
    }

    @Test func byDistanceIsReadOnTheWidestBar() {
        let item = F.nameless("a", 0)
        let narrow = F.drawn(item, x: 100, width: 30, display: "display-narrow")
        let wide = F.drawn(item, x: 900, width: 30)
        var frames = narrow.frames
        frames.merge(wide.frames) { first, _ in first }
        let both = MenuBarItem(id: item, ownerBundleID: item.bundleID, appName: nil, label: nil, frames: frames, overflowedOn: [], isMantel: false)
        let inventory = F.inventory([both], bars: [F.bar("display-narrow", width: 400), F.bar(Fixtures.display, width: 1000)])
        let resolution = resolve([.item(item)], table: F.table(["status:com.example.a::Item-0": 70]), inventory: inventory,
                                 match: .byDistance(tolerance: 5))
        #expect(resolution.keys[.item(item)] == "status:com.example.a::Item-0")
    }

    @Test func identifiersOnlyLeavesIndexUnresolved() {
        let named = F.app("a", "weather"), nameless = F.nameless("b", 0), other = F.nameless("b", 1)
        let table = F.table([F.key(named): 80, "status:com.example.b::Item-0": 100])
        let resolution = resolve([.item(named), .item(nameless), .item(other)], table: table, match: .identifiersOnly)
        #expect(resolution.keys == [.item(named): F.key(named)])
        #expect(resolution.unresolved == [nameless, other])
        #expect(resolution.memory.isEmpty)
    }

    @Test func systemNeverResolved() {
        let table = F.table(["module:Clock": 0, "module:WiFi": 155])
        let resolution = resolve([.item(.system("clock")), .item(.system("wifi"))], table: table, match: .byDistance(tolerance: 50))
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func missingKeyIsUnresolved() {
        let present = F.app("a", "one"), missing = F.app("a", "two")
        let resolution = resolve([.item(present), .item(missing)], table: F.table([F.key(present): 80]))
        #expect(resolution.keys == [.item(present): F.key(present)])
        #expect(resolution.unresolved == [missing])
    }

    @Test func anAppIsNotRunningWhenTheRunningAppsDontHaveIt() {
        let here = F.app("a", "one"), gone = F.app("b", "one"), silent = F.app("c", "one")
        let table = F.table([F.key(here): 80, F.key(gone): 90, F.key(silent): 100])
        let tokens: [LayoutToken] = [.item(here), .item(gone), .item(silent)]
        // The read has an item of `here` only; `silent` is running and draws nothing the read lists, `gone` isn't running.
        let drawn = F.inventory([F.drawn(here, x: 100)])
        let inventory = drawn.withRunningApps(["com.example.a", "com.example.c"])
        #expect(resolve(tokens, table: table, inventory: inventory).notRunning == ["com.example.b"])
        // Keys are found for it all the same: only the side it has in a write is dropped.
        #expect(resolve(tokens, table: table, inventory: inventory).keys[.item(gone)] == F.key(gone))
    }

    @Test func aReadThatDoesNotSayWhichAppsRunSaysNoAppIsNotRunning() {
        // A read that couldn't be taken has no items at all: that is not every app being gone.
        let here = F.app("a", "one"), other = F.app("b", "one")
        let table = F.table([F.key(here): 80, F.key(other): 90])
        let tokens: [LayoutToken] = [.item(here), .item(other)]
        #expect(resolve(tokens, table: table, inventory: F.inventory([F.drawn(here, x: 100)])).notRunning.isEmpty)
        #expect(resolve(tokens, table: table, inventory: .empty).notRunning.isEmpty)
        #expect(resolve(tokens, table: table, inventory: F.inventory([])).notRunning.isEmpty)
    }

    // MARK: By rank

    private let appKey0: String = "status:com.example.a::Item-0"
    private let appKey1: String = "status:com.example.a::Item-1"
    private let appKey2: String = "status:com.example.a::Item-2"
    private let hiddenDotKey: String = "status:com.example.mantel::mantel.dot.hidden"

    private func byRank(_ tokens: [LayoutToken], table: [String: Double], inventory: Inventory, concealed: Set<String> = [],
                        memory: [ItemID: String] = [:], stayingStart: Double? = nil,
                        earlierKeys: [ItemID: String] = [:]) -> LayoutKeyResolution {
        resolve(tokens, table: F.table(table), inventory: inventory, match: .byRank, memory: memory, concealed: concealed,
                stayingStart: stayingStart, earlierKeys: earlierKeys)
    }

    @Test func aSingleItemAppGetsItsOnlyKey() {
        let item = F.nameless("a", 0)
        let drawn = byRank([.item(item)], table: [appKey0: 70], inventory: F.slotted([F.drawn(item, x: 900)]))
        #expect(drawn.keys == [.item(item): appKey0])
        #expect(drawn.unresolved.isEmpty)
        #expect(drawn.memory.isEmpty)

        // Concealed by the plan, or not drawn at all, it doesn't have to be drawn.
        let concealed = byRank([.item(item)], table: [appKey0: 70], inventory: F.slotted([F.concealed(item)]), concealed: ["com.example.a"])
        #expect(concealed.keys == [.item(item): appKey0])
        let undrawn = byRank([.item(item)], table: [appKey0: 70], inventory: F.slotted([]))
        #expect(undrawn.keys == [.item(item): appKey0])
    }

    @Test func anAppWithAStaleKeyIsUnresolved() {
        let item = F.nameless("a", 0)
        let resolution = byRank([.item(item)], table: [appKey0: 70, appKey1: 140], inventory: F.slotted([F.drawn(item, x: 900)]))
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [item])
    }

    @Test func anAppWithAnItemHiddenIsUnresolved() {
        // Three keys, two listed items: the third is hidden (or new), and which key it has can't be told.
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830)])
        let resolution = byRank([.item(first), .item(second)], table: [appKey0: 70, appKey1: 140, appKey2: 210], inventory: inventory)
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [first, second])
    }

    @Test func severalItemsAreMatchedByRankNotByIndex() {
        // `.index(0)` is the right-most icon, and `Item-1` has the smaller distance: the right-most icon gets it.
        let right = F.nameless("a", 0), left = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(right, x: 900), F.drawn(left, x: 830)])
        let resolution = byRank([.item(right), .item(left)], table: [appKey0: 140, appKey1: 70], inventory: inventory)
        #expect(resolution.keys == [.item(right): appKey1, .item(left): appKey0])
        #expect(resolution.unresolved.isEmpty)
        #expect(resolution.memory.isEmpty)
    }

    @Test func aNamedItemsKeyIsNeverACandidate() {
        let named = F.app("a", "weather"), nameless = F.nameless("a", 0)
        let inventory = F.slotted([F.drawn(named, x: 800), F.drawn(nameless, x: 900)])
        let both = byRank([.item(named), .item(nameless)], table: [F.key(named): 120, appKey0: 70], inventory: inventory)
        #expect(both.keys == [.item(named): F.key(named), .item(nameless): appKey0])

        // With no key but the named item's, the nameless one has none: the count is 0 against 1.
        let only = byRank([.item(named), .item(nameless)], table: [F.key(named): 120], inventory: inventory)
        #expect(only.keys == [.item(named): F.key(named)])
        #expect(only.unresolved == [nameless])
    }

    @Test func severalItemsOneUndrawnAreUnresolved() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(first, x: 900), F.concealed(second)])
        let resolution = byRank([.item(first), .item(second)], table: [appKey0: 70, appKey1: 140], inventory: inventory,
                                memory: [first: appKey0, second: appKey1])
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [first, second])
        #expect(resolution.memory.isEmpty)

        // One in the overflow is not drawn either.
        let overflowed = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830, overflowed: true)])
        #expect(byRank([.item(first), .item(second)], table: [appKey0: 70, appKey1: 140], inventory: overflowed).keys.isEmpty)
    }

    @Test func aConcealedAppWithSeveralItemsIsUnresolved() {
        // Its frames are where it was last drawn: they say nothing now.
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830)])
        let table: [String: Double] = [appKey0: 70, appKey1: 140]
        #expect(byRank([.item(first), .item(second)], table: table, inventory: inventory, concealed: ["com.example.a"]).keys.isEmpty)
        #expect(byRank([.item(first), .item(second)], table: table, inventory: inventory).keys.count == 2)
    }

    @Test func aContestedAppIsUnresolved() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830)], contested: ["com.example.a"])
        let resolution = byRank([.item(first), .item(second)], table: [appKey0: 70, appKey1: 140], inventory: inventory)
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [first, second])
    }

    @Test func itemsOnTwoBarsAreUnresolved() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let other = "display-2"
        let bars = [F.bar(), F.bar(other)]
        let inventory = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830, display: other)], bars: bars)
        let table: [String: Double] = [appKey0: 70, appKey1: 140]
        #expect(byRank([.item(first), .item(second)], table: table, inventory: inventory).keys.isEmpty)

        // The same items on both bars, in one order, are on one bar.
        let both = [drawnOn(first, x: 900, and: 880, other), drawnOn(second, x: 830, and: 800, other)]
        let agreeing = F.slotted(both, bars: bars)
        #expect(byRank([.item(first), .item(second)], table: table, inventory: agreeing).keys.count == 2)
        // Two bars that give the items different orders: doubt.
        let crossed = [drawnOn(first, x: 900, and: 800, other), drawnOn(second, x: 830, and: 880, other)]
        #expect(byRank([.item(first), .item(second)], table: table, inventory: F.slotted(crossed, bars: bars)).keys.isEmpty)
    }

    private func drawnOn(_ id: ItemID, x: CGFloat, and otherX: CGFloat, _ other: String) -> MenuBarItem {
        let frames = [Fixtures.display: CGRect(x: x, y: 0, width: 30, height: 24), other: CGRect(x: otherX, y: 0, width: 30, height: 24)]
        return MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil, frames: frames, overflowedOn: [], isMantel: false)
    }

    @Test func twoKeysAtOneDistanceAreUnresolved() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830)])
        let resolution = byRank([.item(first), .item(second)], table: [appKey0: 70, appKey1: 70], inventory: inventory)
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [first, second])
    }

    @Test func aFrameInNoSlotIsNotDrawn() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let items = [F.drawn(first, x: 900), F.drawn(second, x: 830)]
        let table: [String: Double] = [appKey0: 70, appKey1: 140]
        // The slots the bar has are the first's and one that is the second's width but somewhere else.
        let slots = [Fixtures.display: [CGRect(x: 830, y: 0, width: 30, height: 24).offsetBy(dx: 0, dy: 40), CGRect(x: 900, y: 0, width: 30, height: 24)]]
        let resolution = byRank([.item(first), .item(second)], table: table, inventory: F.slotted(items, slots: slots))
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [first, second])
        // Two frames in one slot are not two drawn items either.
        let one = [Fixtures.display: [CGRect(x: 900, y: 0, width: 30, height: 24)]]
        let sameSlot = [F.drawn(first, x: 900), F.drawn(second, x: 900)]
        #expect(byRank([.item(first), .item(second)], table: table, inventory: F.slotted(sameSlot, slots: one)).keys.isEmpty)
    }

    @Test func theCrossCheckRefusesAnAppOnTheOtherSideOfADot() {
        let dot = F.own(.hiddenDot, x: 500)
        let item = F.nameless("a", 0)
        // The table puts the app's key (300) left of • (200); the bar draws the icon at 700, right of it.
        let wrong = byRank([.dot(.hidden), .item(item)], table: [hiddenDotKey: 200, appKey0: 300],
                           inventory: F.slotted([dot, F.drawn(item, x: 700)]))
        #expect(wrong.keys == [.dot(.hidden): hiddenDotKey])
        #expect(wrong.unresolved == [item])
        // Where the table and the bar agree it is matched.
        let right = byRank([.dot(.hidden), .item(item)], table: [hiddenDotKey: 200, appKey0: 100],
                           inventory: F.slotted([dot, F.drawn(item, x: 700)]))
        #expect(right.keys[.item(item)] == appKey0)
        // A key at the dot's own distance can't be told from either side.
        let tie = byRank([.dot(.hidden), .item(item)], table: [hiddenDotKey: 200, appKey0: 200],
                         inventory: F.slotted([dot, F.drawn(item, x: 700)]))
        #expect(tie.unresolved == [item])

        // Several items: one of them on the wrong side is enough to refuse them all.
        let first = F.nameless("b", 0), second = F.nameless("b", 1)
        let table: [String: Double] = [hiddenDotKey: 200, "status:com.example.b::Item-0": 300, "status:com.example.b::Item-1": 100]
        let split = byRank([.dot(.hidden), .item(first), .item(second)], table: table,
                           inventory: F.slotted([dot, F.drawn(first, x: 800), F.drawn(second, x: 700)]))
        #expect(split.unresolved == [first, second], "the table has one of them left of • and the bar has both right of it")
        let agreeing = byRank([.dot(.hidden), .item(first), .item(second)], table: table,
                              inventory: F.slotted([dot, F.drawn(first, x: 800), F.drawn(second, x: 300)]))
        #expect(agreeing.keys[.item(first)] == "status:com.example.b::Item-1" && agreeing.keys[.item(second)] == "status:com.example.b::Item-0")
    }

    @Test func theCrossCheckLooksAtNamedItemsAndAppsMatchedBefore() {
        let named = F.app("n", "weather"), a = F.nameless("a", 0), b = F.nameless("b", 0)
        let bKey = "status:com.example.b::Item-0"
        let inventory = F.slotted([F.drawn(named, x: 200), F.drawn(a, x: 400), F.drawn(b, x: 600)])
        // Left to right the bar has the named item, a and b, and so does a table that gives them 900, 500 and 300.
        let agreeing = byRank([.item(named), .item(a), .item(b)], table: [F.key(named): 900, appKey0: 500, bKey: 300], inventory: inventory)
        #expect(agreeing.keys[.item(a)] == appKey0 && agreeing.keys[.item(b)] == bKey)
        // b's key puts it left of a, which was matched before it: only b is refused.
        let refusedAfterA = byRank([.item(named), .item(a), .item(b)], table: [F.key(named): 900, appKey0: 500, bKey: 700], inventory: inventory)
        #expect(refusedAfterA.keys[.item(a)] == appKey0)
        #expect(refusedAfterA.unresolved == [b])
        // a's key puts it left of the named item, which the bar has left of it: a is refused, and isn't a place b is compared with.
        let refusedAfterNamed = byRank([.item(named), .item(a), .item(b)], table: [F.key(named): 900, appKey0: 950, bKey: 300],
                                       inventory: inventory)
        #expect(refusedAfterNamed.unresolved == [a])
        #expect(refusedAfterNamed.keys[.item(b)] == bKey)
    }

    @Test func aConcealedAppsTokensAreNotBelievedWhereTheyWereDrawn() {
        // The named item's frame is stale (its app is concealed): it can't contradict the match.
        let named = F.app("n", "weather"), item = F.nameless("a", 0)
        let inventory = F.slotted([F.drawn(named, x: 800), F.drawn(item, x: 300)])
        let table: [String: Double] = [F.key(named): 900, appKey0: 100]
        #expect(byRank([.item(named), .item(item)], table: table, inventory: inventory).unresolved == [item])
        #expect(byRank([.item(named), .item(item)], table: table, inventory: inventory, concealed: ["com.example.n"]).keys[.item(item)] == appKey0)
    }

    @Test func aPhantomNoLongerBlocksAnAppsOrder() {
        // A record of a name the app never gave (a slot's name, saved by an older version) has no key in the table: the app has a named
        // item that has none, and which of its keys is the nameless item's can't be told, so no key is given. Once the check has taken the
        // record out, the app's one nameless item gets its one key.
        let item = F.nameless("a", 0)
        let phantom = ItemID(bundleID: "com.example.a", key: .identifier("x.main-menu"))
        var sections = SectionModel()
        sections.noteIcons([phantom, item])
        let inventory = F.slotted([F.drawn(item, x: 900)])
        func keys(_ model: SectionModel) -> LayoutKeyResolution {
            byRank(model.items(in: .shown).map(LayoutToken.item), table: [appKey0: 70], inventory: inventory)
        }
        #expect(keys(sections).keys[.item(item)] == nil)
        #expect(keys(sections).unresolved.contains(phantom))

        sections.unchecked = ["com.example.a"]
        sections.reconcile(app: "com.example.a", current: [item])
        #expect(keys(sections).keys[.item(item)] == appKey0)
        #expect(keys(sections).unresolved.isEmpty)
    }

    // MARK: Pairing by bar position

    @Test func theLeftMostIconTakesTheLargestDistanceWhateverItsIndex() {
        // As the matcher names them, `.index(0)` is the left-most icon: it gets the key that is furthest left in the table, whatever the
        // key is called, and the right icon the other (pairing the n-th index with the n-th smallest distance would do the opposite).
        let left = F.nameless("a", 0), right = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(left, x: 830), F.drawn(right, x: 900)])
        let resolution = byRank([.item(left), .item(right)], table: [appKey0: 70, appKey1: 140], inventory: inventory)
        #expect(resolution.keys == [.item(left): appKey1, .item(right): appKey0])

        // And the keys of an app keep the order the table has when the arrangement has its icons as the bar does.
        let table: [String: Double] = [appKey0: 90, appKey1: 40]
        let kept = byRank([.item(left), .item(right)], table: table, inventory: inventory)
        let distances = [left, right].compactMap { id in kept.keys[.item(id)].flatMap { table[$0] } }
        #expect(distances == [90, 40])
    }

    @Test func theCountOfNamelessItemsIsTheUnionOfTheTokensAndTheInventory() {
        // The tokens have one nameless item, the inventory lists a second: one key can't be for both.
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let inventory = F.slotted([F.drawn(first, x: 900), F.drawn(second, x: 830)])
        let resolution = byRank([.item(first)], table: [appKey0: 70], inventory: inventory)
        #expect(resolution.keys.isEmpty)
        #expect(resolution.unresolved == [first])
    }

    // MARK: Among the modules that stay

    @Test func anAppAmongTheStayingModulesIsNotWrittenWhateverTheKeyMatch() {
        // The left-most module that stays is at 300. A single item whose entry is at 250 sits among the modules: it is unresolved, and has no
        // key.
        let item = F.nameless("a", 0), named = F.app("n", "weather")
        let inventory = F.slotted([F.drawn(item, x: 700), F.drawn(named, x: 600)])
        let table: [String: Double] = [appKey0: 250, F.key(named): 260]
        let ranked = byRank([.item(item), .item(named)], table: table, inventory: inventory, stayingStart: 300)
        #expect(ranked.keys.isEmpty)
        #expect(ranked.unresolved == [item, named])
        #expect(ranked.amongTheStaying == [item.bundleID, named.bundleID])
        // With no limit (a resolution that writes nothing), they are matched.
        #expect(byRank([.item(item), .item(named)], table: table, inventory: inventory, stayingStart: nil).keys.count == 2)

        // A named item is no different under the other rules.
        let only = resolve([.item(named)], table: F.table(table), inventory: inventory, match: .identifiersOnly, stayingStart: 300)
        #expect(only.keys.isEmpty && only.unresolved == [named])
        let indexed = resolve([.item(item)], table: F.table(["status:com.example.a::Item-0": 250]), inventory: inventory,
                              match: .autosaveIndex(prefix: "Item-"), stayingStart: 300)
        #expect(indexed.keys.isEmpty && indexed.unresolved == [item])
    }

    @Test func anAppJustAboveTheLeftMostStayingModuleIsStillWritten() {
        let item = F.nameless("a", 0), named = F.app("n", "weather")
        let inventory = F.slotted([F.drawn(item, x: 700), F.drawn(named, x: 600)])
        let resolution = byRank([.item(item), .item(named)], table: [appKey0: 300.5, F.key(named): 301], inventory: inventory, stayingStart: 300)
        #expect(resolution.keys == [.item(item): appKey0, .item(named): F.key(named)])
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func oneKeyAmongTheStayingModulesLeavesTheWholeAppAlone() {
        // The app's named item is at 250, among the modules, and its nameless one is matched to 350: none of it is written.
        let named = F.app("a", "weather"), nameless = F.nameless("a", 0)
        let resolution = byRank([.item(named), .item(nameless)], table: [F.key(named): 250, appKey0: 350],
                                inventory: F.slotted([F.drawn(named, x: 700), F.drawn(nameless, x: 600)]), stayingStart: 300)
        #expect(resolution.keys.isEmpty)
        #expect(Set(resolution.unresolved) == [named, nameless])
    }

    @Test func aStaleKeyBelowTheStartDoesNotFreezeAnAppWhoseItemsAreAbove() {
        // A named app at 500 that also has a key at 300 (an older name, or an item it hid): only the keys the resolution gives its items
        // count, so it is written. The stale key is a key of the app's, and the placer still goes around it. It is below the start, not at
        // it: "every key" would freeze the app whatever the comparison at the start is.
        let named = F.app("a", "weather")
        let table: [String: Double] = [F.key(named): 500, "status:com.example.a::old": 250]
        let resolution = byRank([.item(named)], table: table, inventory: .empty, stayingStart: 300)
        #expect(resolution.keys == [.item(named): F.key(named)])
        #expect(resolution.unresolved.isEmpty && resolution.amongTheStaying.isEmpty)
        // A nameless item with a stale key below isn't frozen by it either: the app has more keys than items, so it is unresolved by the
        // count, and not "among".
        let item = F.nameless("a", 0)
        let counted = byRank([.item(item)], table: [appKey0: 500, appKey1: 250], inventory: .empty, stayingStart: 300)
        #expect(counted.unresolved == [item] && counted.amongTheStaying.isEmpty)
    }

    @Test func theBoundaryIsTheLeftMostStayingModulesOwnDistance() {
        // A key at the module's own distance can't be told from either side of it: it counts as among, and is left alone. A key above it
        // (further left than the module's start) is an app left of the module: written.
        let item = F.nameless("a", 0), other = F.nameless("b", 0)
        let inventory = F.slotted([F.drawn(item, x: 700), F.drawn(other, x: 600)])
        let atIt = byRank([.item(item)], table: [appKey0: 300], inventory: inventory, stayingStart: 300)
        #expect(atIt.keys.isEmpty && atIt.unresolved == [item])
        let above = byRank([.item(other)], table: ["status:com.example.b::Item-0": 300.5], inventory: inventory, stayingStart: 300)
        #expect(above.keys[.item(other)] == "status:com.example.b::Item-0")
        let below = byRank([.item(item)], table: [appKey0: 299.5], inventory: inventory, stayingStart: 300)
        #expect(below.keys.isEmpty)
    }

    @Test func anAppIsOutOfTheWayOnlyWhenEveryKeyItHasIsAmongTheStayingModules() {
        let item = F.nameless("a", 0), named = F.app("n", "weather")
        let inventory = F.slotted([F.drawn(item, x: 700), F.drawn(named, x: 600)])
        // Itsycal-like: one item, one key, at 195.
        let only = byRank([.item(item)], table: [appKey0: 195], inventory: inventory, stayingStart: 300)
        #expect(only.amongTheStaying == [item.bundleID] && only.outOfTheWay == [item.bundleID])
        // A named item at 250, and a key of the app's at 500 that no item has: left alone, but its place isn't settled to the right.
        let table: [String: Double] = [F.key(named): 250, "status:com.example.n::other": 500]
        let more = byRank([.item(named)], table: table, inventory: inventory, stayingStart: 300)
        #expect(more.amongTheStaying == [named.bundleID] && more.outOfTheWay.isEmpty)
    }

    @Test func anAppWhoseKeysAreAllAmongTheStayingModulesIsOutOfTheWayWhetherOrNotItWasMatched() {
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        let both = [LayoutToken.item(first), .item(second)]
        let table: [String: Double] = [appKey0: 200, appKey1: 250]
        // Two nameless items the plan conceals aren't matched (their frames are left behind), and no key is given them: out of the way.
        let inventory = F.slotted([F.drawn(first, x: 700), F.drawn(second, x: 600)])
        let concealed = byRank(both, table: table, inventory: inventory, concealed: ["com.example.a"], stayingStart: 300)
        #expect(concealed.keys.isEmpty && Set(concealed.unresolved) == [first, second])
        #expect(concealed.amongTheStaying.isEmpty, "no key was given to either item")
        #expect(concealed.outOfTheWay == ["com.example.a"])
        // Nor does it matter that the bars disagree about their order (a failed rank match).
        let apart = byRank(both, table: table, inventory: F.slotted([F.drawn(first, x: 700)]), stayingStart: 300)
        #expect(apart.outOfTheWay == ["com.example.a"])

        // One key above the start, and the app is an obstacle again.
        let above = byRank(both, table: [appKey0: 200, appKey1: 350], inventory: inventory, concealed: ["com.example.a"], stayingStart: 300)
        #expect(above.outOfTheWay.isEmpty)
        // A nameless item no key can be found for (one key for two items under `byRank`) may be drawn anywhere: still an obstacle.
        let stale = byRank([.item(first)], table: table, inventory: F.slotted([F.drawn(first, x: 700)]), stayingStart: 300)
        #expect(stale.unresolved == [first] && stale.outOfTheWay.isEmpty)
        // A named item with no key is the same.
        let named = F.app("a", "foo")
        let withoutKey = byRank([.item(named), .item(first)], table: [appKey0: 200], inventory: F.slotted([F.drawn(named, x: 800)]),
                                stayingStart: 300)
        #expect(withoutKey.outOfTheWay.isEmpty)
        // Under the rule that finds no keys for nameless items, the count of keys isn't asked.
        let only = resolve([.item(first)], table: F.table(table), inventory: inventory, match: .identifiersOnly, stayingStart: 300)
        #expect(only.outOfTheWay == ["com.example.a"])
        // Without a start (a resolution that writes nothing) no app is out of the way.
        #expect(byRank(both, table: table, inventory: inventory, concealed: ["com.example.a"]).outOfTheWay.isEmpty)
    }

    @Test func anAppAmongTheStayingModulesKeepsItsMemory() {
        // Under the distance rule an item that isn't drawn keeps the key it had, and a key among the modules that stay leaves the app alone:
        // that is not a write, so what was remembered stays for when the app is drawn again.
        let item = F.nameless("a", 0)
        let resolution = resolve([.item(item)], table: F.table([appKey0: 250]), match: .byDistance(tolerance: 10),
                                 memory: [item: appKey0], stayingStart: 300)
        #expect(resolution.keys.isEmpty && resolution.unresolved == [item])
        #expect(resolution.memory == [item: appKey0])
    }

    // MARK: A named item with no key

    @Test func aNamedItemWithNoKeyLeavesItsNamelessSiblingsUnresolved() {
        // `foo` has no entry, and the app's one entry (`bar`) could be foo's own under another name: which of them it is can't be told.
        let named = F.app("a", "foo"), nameless = F.nameless("a", 0)
        let inventory = F.slotted([F.drawn(named, x: 800), F.drawn(nameless, x: 900)])
        let resolution = byRank([.item(named), .item(nameless)], table: ["status:com.example.a::bar": 70], inventory: inventory)
        #expect(resolution.keys.isEmpty)
        #expect(Set(resolution.unresolved) == [named, nameless])
    }

    // MARK: A concealed or contested app's frame

    @Test func aConcealedItemsLeftBehindFrameIsNotCheckedAgainstTheDots() {
        // The table puts the item's key (300) left of • (200); the frame it was left with (700) is right of it, in a slot a drawn app
        // claims. The app is concealed: it isn't drawn, and its frame says nothing.
        let dot = F.own(.hiddenDot, x: 500)
        let item = F.nameless("a", 0)
        let tokens: [LayoutToken] = [.dot(.hidden), .item(item)]
        let table: [String: Double] = [hiddenDotKey: 200, appKey0: 300]
        let inventory = F.slotted([dot, F.drawn(item, x: 700)])
        #expect(byRank(tokens, table: table, inventory: inventory).unresolved == [item], "drawn, it is refused")
        #expect(byRank(tokens, table: table, inventory: inventory, concealed: ["com.example.a"]).keys[.item(item)] == appKey0)
        let contested = F.slotted([dot, F.drawn(item, x: 700)], contested: ["com.example.a"])
        #expect(byRank(tokens, table: table, inventory: contested).keys[.item(item)] == appKey0)
    }

    // MARK: Keys an earlier try matched

    @Test func theKeysAnEarlierTryMatchedStayWhileTheTableHasThem() {
        // The bar says the item is right of • and the table (after a write) has its key left of it: the cross-check refuses, but the
        // earlier try's match stays, so the write goes on and the verifier has the last word.
        let dot = F.own(.hiddenDot, x: 500)
        let item = F.nameless("a", 0)
        let tokens: [LayoutToken] = [.dot(.hidden), .item(item)]
        let table: [String: Double] = [hiddenDotKey: 200, appKey0: 300]
        let inventory = F.slotted([dot, F.drawn(item, x: 700)])
        #expect(byRank(tokens, table: table, inventory: inventory).unresolved == [item])
        #expect(byRank(tokens, table: table, inventory: inventory, earlierKeys: [item: appKey0]).keys[.item(item)] == appKey0)
        // A key the table no longer has isn't kept, and nothing is matched from it.
        #expect(byRank(tokens, table: table, inventory: inventory, earlierKeys: [item: appKey1]).unresolved == [item])
        // The rest of the rule still applies: among the system items, the app isn't written whatever an earlier try did.
        #expect(byRank(tokens, table: table, inventory: inventory, stayingStart: 400, earlierKeys: [item: appKey0]).unresolved == [item])
    }

    @Test func systemAndOwnItemsAreUnchanged() {
        let spacer = OwnItems.itemID(SpacerID(rawValue: "0000abcd"))
        let named = F.app("n", "weather")
        let tokens: [LayoutToken] = [.dot(.hidden), .dot(.always), .divider, .item(spacer), .item(.system("clock")), .item(named)]
        let table: [String: Double] = [F.key(named): 80]
        let ranked = resolve(tokens, table: F.table(table), match: .byRank)
        let only = resolve(tokens, table: F.table(table), match: .identifiersOnly)
        #expect(ranked == only)
        #expect(ranked.keys[.item(named)] == F.key(named))
        #expect(ranked.keys[.item(.system("clock"))] == nil)
        #expect(ranked.unresolved.isEmpty)
    }
}
