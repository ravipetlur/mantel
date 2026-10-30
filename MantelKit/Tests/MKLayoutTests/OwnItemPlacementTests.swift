import MKCore
import Testing

@testable import MKLayout

/// Where the tokens a write places go in the table: inside the gap that all the apps it doesn't write leave, by their real distances.
@Suite("Own item placement", .timeLimit(.minutes(1)))
struct OwnItemPlacementTests {
    private typealias F = ArrangementFixtures
    private let a = F.nameless("a"), b = F.nameless("b"), c = F.nameless("c"), d = F.nameless("d"), fresh = F.nameless("fresh")
    private let named = F.app("named")
    private let hidden = LayoutToken.dot(.hidden), always = LayoutToken.dot(.always), divider = LayoutToken.divider

    private func key(_ app: String, _ n: Int) -> String {
        LayoutKey.status(bundleID: "com.example.\(app)", autosaveName: "Item-\(n)")
    }

    private func ownKeys(_ tokens: [LayoutToken]) -> [LayoutToken: String] {
        var keys: [LayoutToken: String] = [:]
        for token in tokens {
            switch token {
            case .dot(.hidden): keys[token] = F.ownKey(OwnItems.hiddenDotName)
            case .dot(.always): keys[token] = F.ownKey(OwnItems.alwaysDotName)
            case .divider: keys[token] = F.ownKey(OwnItems.dividerName)
            case .item: break
            }
        }
        return keys
    }

    /// The arrangement of these tokens, with the distances `LayoutMath` would give them (which the apps' places make no sense of).
    private func arrangement(_ tokens: [LayoutToken], distances: [LayoutToken: Double] = [:]) -> LayoutArrangement {
        var made = distances
        for (index, token) in tokens.enumerated() where made[token] == nil { made[token] = Double((tokens.count - index) * 1000) }
        return LayoutArrangement(tokens: tokens, distances: made, skipped: [])
    }

    private func place(_ tokens: [LayoutToken], _ table: [String: Double], written: [LayoutToken: String] = [:],
                       distances: [LayoutToken: Double] = [:], systemStart: Double = 0) -> OwnItemPlacer.Result {
        OwnItemPlacer.place(arrangement(tokens, distances: distances), keys: ownKeys(tokens).merging(written) { $1 },
                            table: LayoutTableSnapshot(distances: table), systemStart: systemStart)
    }

    @Test func anItemBetweenTwoAppsIsInTheGapBetweenTheirDistances() throws {
        // a is left of b: larger distances are further left.
        let result = place([.item(a), hidden, .item(b)], [key("a", 0): 300, key("b", 0): 100])
        let distance = try #require(result.distances[hidden])
        #expect(distance == 200)
        #expect(result.notPlaced.isEmpty)
    }

    @Test func anAppsRangeIsAllItsKeysNamedAndNamelessAlike() throws {
        // a's keys are at 300 and 220 (its left-most is the larger one): the item is right of its smallest. b has two keys too.
        let named = LayoutKey.status(bundleID: "com.example.a", autosaveName: "alerts")
        let table: [String: Double] = [key("a", 0): 300, named: 220, key("b", 0): 100, key("b", 1): 140]
        let distance = try #require(place([.item(a), hidden, .item(b)], table).distances[hidden])
        #expect(distance < 220 && distance > 140, "between a's smallest (220) and b's largest (140)")
    }

    @Test func itemsSideBySideShareOneGapInOrder() throws {
        let result = place([.item(a), always, hidden, divider, .item(b)], [key("a", 0): 400, key("b", 0): 100])
        let always = try #require(result.distances[always]), hidden = try #require(result.distances[hidden])
        let divider = try #require(result.distances[divider])
        #expect(always > hidden && hidden > divider, "left to right, so the distances fall")
        #expect(always < 400 && divider > 100)
        #expect(result.notPlaced.isEmpty)
    }

    @Test func interleavedAppsLeaveNoGap() {
        // a has an item at 150 and one at 50; b is at 100.
        let table: [String: Double] = [key("a", 0): 150, key("a", 1): 50, key("b", 0): 100]
        let result = place([.item(a), hidden, divider, .item(b)], table)
        #expect(result.distances.isEmpty)
        #expect(result.notPlaced == [hidden, divider])
        // Touching ranges are none either.
        #expect(place([.item(a), hidden, .item(b)], [key("a", 0): 100, key("b", 0): 100]).notPlaced == [hidden])
    }

    @Test func appsTheOtherWayRoundLeaveNoGap() {
        // The model has a left of b, and the table has b left of a: there is nowhere for the item to be.
        #expect(place([.item(a), hidden, .item(b)], [key("a", 0): 100, key("b", 0): 300]).notPlaced == [hidden])
    }

    @Test func anAppWithNoKeyIsNoObstacle() throws {
        // An app that has no key has no place in the table: nothing is kept on a side of it, wherever it is in the arrangement.
        let one = try #require(place([.item(a), hidden, .item(b)], [key("b", 0): 100]).distances[hidden])
        #expect(one > 100, "right of b, which is the one app whose place is told")
        let two = try #require(place([.item(a), hidden, .item(b)], [key("a", 0): 300]).distances[hidden])
        #expect(two < 300)
        let far = try #require(place([.item(c), .item(a), hidden, .item(b)], [key("a", 0): 300, key("b", 0): 100]).distances[hidden])
        #expect(far < 300 && far > 100, "an app that isn't beside the item doesn't stop it either")
        #expect(place([.item(a), hidden, .item(b)], [key("b", 0): 100]).notPlaced.isEmpty)
    }

    @Test func anAppThatIsIgnoredIsNoObstacleEither() throws {
        // `ignoring` is for the apps that aren't running: they have keys, but take no room on the bar.
        let table: [String: Double] = [key("a", 0): 300, key("c", 0): 150, key("c", 1): 350, key("b", 0): 100]
        let tokens: [LayoutToken] = [.item(a), hidden, .item(c), .item(b)]
        let blocked = OwnItemPlacer.place(arrangement(tokens), keys: ownKeys(tokens), table: LayoutTableSnapshot(distances: table), systemStart: 0)
        #expect(blocked.notPlaced == [hidden], "c's keys are on both sides of a and b's gap")
        let ignored = OwnItemPlacer.place(arrangement(tokens), keys: ownKeys(tokens), table: LayoutTableSnapshot(distances: table), systemStart: 0,
                                          ignoring: ["com.example.c"])
        #expect(ignored.notPlaced.isEmpty)
        #expect(ignored.distances[hidden] != nil)
    }

    @Test func oneAppOnBothSidesCantBeTold() {
        // An own item between two items of the same app: its neighbours are one app, whose range has nothing in it for the item.
        #expect(place([.item(a), hidden, .item(ItemID(bundleID: a.bundleID, key: .index(1)))], [key("a", 0): 300, key("a", 1): 100]).notPlaced == [hidden])
    }

    // MARK: Every app that isn't written counts

    @Test func anAppThatIsNotANeighbourButSitsInTheGapKeepsItsSide() throws {
        // Hidden is [a, c] and the person dragged c before a: the arrangement is `c a • b`. The table has a at 300, c at 150, b at 100, so
        // the nearest apps (a and b) leave (100, 300), which has c in it. The dot goes below c: both stay left of it.
        let table: [String: Double] = [key("a", 0): 300, key("c", 0): 150, key("b", 0): 100]
        let distance = try #require(place([.item(c), .item(a), hidden, .item(b)], table).distances[hidden])
        #expect(distance < 150 && distance > 100, "right of c and a, left of b (a nearest-neighbour gap would give 200)")
    }

    @Test func theDotsStayBetweenTheirSectionsWhenTheAlwaysDotIsThereToo() throws {
        // Always Hidden [d], Hidden [a, c], Shown [b]: `d •• c a • b`, the table with d at 400, a at 300, c at 150, b at 100.
        let table: [String: Double] = [key("d", 0): 400, key("a", 0): 300, key("c", 0): 150, key("b", 0): 100]
        let result = place([.item(d), always, .item(c), .item(a), hidden, .item(b)], table)
        let always = try #require(result.distances[always]), hidden = try #require(result.distances[hidden])
        #expect(always < 400 && always > 300, "right of d, left of a, which is the furthest left of the apps that follow it")
        #expect(hidden < 150 && hidden > 100)
    }

    @Test func aNewAppWithAFarLeftKeyDoesNotMoveTheMarkerPastTheOthers() throws {
        // The marker is at the end of Hidden: `a c fresh • b`. macOS gave the new app's item a key at 900.
        let table: [String: Double] = [key("a", 0): 300, key("c", 0): 150, key("fresh", 0): 900, key("b", 0): 100]
        let distance = try #require(place([.item(a), .item(c), .item(fresh), hidden, .item(b)], table).distances[hidden])
        #expect(distance < 150 && distance > 100, "a (300) and c (150) are left of it; the midpoint of fresh and b would be 500")
    }

    @Test func anAppRightOfTheItemKeepsItsSideWhenItSitsInTheNearestGap() throws {
        // `a • b c`: the nearest apps leave (200, 300); c is right of b but at 250, inside that gap.
        let table: [String: Double] = [key("a", 0): 300, key("b", 0): 200, key("c", 0): 250]
        let distance = try #require(place([.item(a), hidden, .item(b), .item(c)], table).distances[hidden])
        #expect(distance > 250 && distance < 300, "right of c as well")
    }

    @Test func aDroppedAppStaysWhereItIsAndTheOthersGoAroundIt() throws {
        // `a n c • d`: n is written (it names itself) but a (200.4) and c (200) are 0.4 apart, so n has no gap the writer would keep and isn't
        // written. It stays at 60 in the table, so the dot must be right of it as well.
        let n = F.app("named")
        let table: [String: Double] = [key("a", 0): 200.4, key("c", 0): 200, F.key(n): 60, key("d", 0): 50]
        let result = place([.item(a), .item(n), .item(c), hidden, .item(d)], table, written: [.item(n): F.key(n)])
        #expect(result.notPlaced == [.item(n)])
        let distance = try #require(result.distances[hidden])
        #expect(distance < 60 && distance > 50, "n stays left of the dot")
    }

    // MARK: Obstacles whose places are against the arrangement

    @Test func appsAgainstTheArrangementDoNotStopTheAppsAroundThem() throws {
        // `a c n b d`: the person put a before c, and the table has c (300) left of a (100); neither can be written. b (250) and d (200)
        // agree with c, so n is written between c and b, as a row that kept every app's side would leave it nowhere.
        let n = F.app("n")
        let table: [String: Double] = [key("a", 0): 100, key("c", 0): 300, key("b", 0): 250, key("d", 0): 200, F.key(n): 20]
        let result = place([.item(a), .item(c), .item(n), .item(b), .item(d)], table, written: [.item(n): F.key(n)])
        #expect(result.notPlaced.isEmpty)
        let distance = try #require(result.distances[.item(n)])
        #expect(distance > 250 && distance < 300)
    }

    @Test func anOwnItemKeepsItsSideOfEveryAppWhileTheAppsAroundItAreWritten() throws {
        // `n a • c m` with a (100) and c (300) the wrong way round: no gap holds the dot, which stays at 200 in the table. n and m are
        // written around it all the same: n left of it, m right of it.
        let n = F.app("n"), m = F.app("m")
        let table: [String: Double] = [key("a", 0): 100, key("c", 0): 300, F.ownKey(OwnItems.hiddenDotName): 200, F.key(n): 500, F.key(m): 40]
        let result = place([.item(n), .item(a), hidden, .item(c), .item(m)], table, written: [.item(n): F.key(n), .item(m): F.key(m)])
        #expect(result.notPlaced == [hidden])
        #expect(try #require(result.distances[.item(n)]) > 200)
        #expect(try #require(result.distances[.item(m)]) < 200)
    }

    @Test func anOwnItemIsNotWrittenAcrossAnAppThatAgreesWithNothing() throws {
        // The same, with the dot's place unknown: nothing says where it is, so it isn't written, and no app is written to a side of it
        // either (see `appsAreNotWrittenAroundADotThatHasNoPlaceInTheTable`).
        let n = F.app("n"), m = F.app("m")
        let table: [String: Double] = [key("a", 0): 100, key("c", 0): 300, F.key(n): 500, F.key(m): 40]
        let result = place([.item(n), .item(a), hidden, .item(c), .item(m)], table, written: [.item(n): F.key(n), .item(m): F.key(m)])
        #expect(Set(result.notPlaced) == [hidden, .item(n), .item(m)])
        #expect(result.distances.isEmpty)
        // The divider with no place doesn't divide sections: the apps are written around it.
        let around = place([.item(n), .item(a), divider, .item(c), .item(m)], table, written: [.item(n): F.key(n), .item(m): F.key(m)])
        #expect(around.notPlaced == [divider])
        #expect(around.distances[.item(n)] != nil && around.distances[.item(m)] != nil)
    }

    // MARK: The system items' end

    @Test func withNoAppToTheRightTheGapStartsAtTheSystemItems() throws {
        // The system items end at 180 (the largest distance and width of a drawn module): the item goes left of them, not among them.
        let result = place([.item(a), hidden], [key("a", 0): 400], systemStart: 180)
        let distance = try #require(result.distances[hidden])
        #expect(distance > 180 && distance < 400)
        #expect(result.notPlaced.isEmpty)
    }

    @Test func nothingIsWrittenAmongTheSystemItems() {
        // The last app is at 150, below where the system items end: no gap is left for the item.
        #expect(place([.item(a), hidden, divider], [key("a", 0): 150], systemStart: 180).notPlaced == [hidden, divider])
    }

    @Test func withNoAppToTheLeftTheGapIsAsWideAsTheItemsNeedAbove() throws {
        let result = place([always, hidden, .item(b)], [key("b", 0): 100])
        let always = try #require(result.distances[always]), hidden = try #require(result.distances[hidden])
        #expect(always > hidden && hidden > 100)
    }

    @Test func withNoAppsAtAllTheTokensKeepTheArrangement() {
        // Nothing is left unwritten beside them: the arrangement's own distances stand.
        let result = place([always, hidden, divider], [:])
        #expect(result.distances.isEmpty)
        #expect(result.notPlaced.isEmpty)
    }

    // MARK: Apps that are written

    @Test func everyTokenIsWrittenWholeWhenNoAppIsLeftUnwritten() {
        let named = F.app("named")
        #expect(place([.item(named), hidden], [F.key(named): 50], written: [.item(named): F.key(named)]).distances.isEmpty)
    }

    @Test func aNamedAppAmongNamelessOnesIsPlacedByTheirRealPlaces() throws {
        // `a n b`: n names itself and has a key (at 450, right of a, which is the other way round from the model); a and b are nameless.
        let n = F.app("named")
        let table: [String: Double] = [key("a", 0): 400, key("b", 0): 100, F.key(n): 450]
        let result = place([.item(a), .item(n), .item(b)], table, written: [.item(n): F.key(n)], distances: [.item(n): 5000])
        let distance = try #require(result.distances[.item(n)])
        #expect(distance < 400 && distance > 100, "between a and b, not at the width-made 5000 or the old 450")
    }

    @Test func aNamedAppAndTheDotShareTheGapInOrder() throws {
        let n = F.app("named")
        let table: [String: Double] = [key("a", 0): 400, key("b", 0): 100, F.key(n): 450]
        let result = place([.item(a), .item(n), hidden, .item(b)], table, written: [.item(n): F.key(n)])
        let named = try #require(result.distances[.item(n)]), hidden = try #require(result.distances[hidden])
        #expect(named > hidden && named < 400 && hidden > 100)
    }

    @Test func aNamedAppBesideAnAppWithNoKeyIsWritten() {
        let n = F.app("named")
        let result = place([.item(a), .item(n)], [F.key(n): 450], written: [.item(n): F.key(n)])
        #expect(result.notPlaced.isEmpty)
        #expect(result.distances.isEmpty, "nothing is left unwritten beside it: the arrangement's own distance stands")
    }

    // MARK: A token that is left out is an obstacle too

    @Test func aDotAndDividerThatCantBePlacedKeepTheTestItemOnItsSide() throws {
        // `T A • | B` under this Mac's rules: T names itself (written), A and B don't. The table: A 100, B 122, the divider 152, • 161,
        // T 199, the system items ending at 90. B is left of A in the table, so • and the divider have no gap and stay at 161 and 152.
        // T must stay left of both: a write from the gap A and B leave alone (122 up) would put it at 160, right of •.
        let t = F.app("t")
        let table: [String: Double] = [key("a", 0): 100, key("b", 0): 122, F.ownKey(OwnItems.dividerName): 152,
                                       F.ownKey(OwnItems.hiddenDotName): 161, F.key(t): 199]
        let result = place([.item(t), .item(a), hidden, divider, .item(b)], table, written: [.item(t): F.key(t)], systemStart: 90)
        #expect(result.notPlaced == [hidden, divider])
        let distance = try #require(result.distances[.item(t)])
        #expect(distance > 161, "left of • (161), and so of the divider and of both apps")
    }

    @Test func aDotThatCantBePlacedStaysRightOfTheOneLeftOfIt() throws {
        // `D •• A • |`: the table has A (155) left of D (131), so •• has no gap and stays at 115. • and the divider must be right of it: the
        // apps alone would put • at 117.5, left of ••.
        let table: [String: Double] = [key("d", 0): 131, key("a", 0): 155, F.ownKey(OwnItems.alwaysDotName): 115,
                                       F.ownKey(OwnItems.hiddenDotName): 99, F.ownKey(OwnItems.dividerName): 90]
        let result = place([.item(d), always, .item(a), hidden, divider], table, systemStart: 90)
        #expect(result.notPlaced == [always])
        let hiddenAt = try #require(result.distances[hidden]), dividerAt = try #require(result.distances[divider])
        #expect(hiddenAt < 115 && hiddenAt > dividerAt && dividerAt > 90, "• and the divider are right of ••, left of the system items")
    }

    @Test func anOwnItemWithNoPlaceInTheTableBlocksTheOthersOnceItIsLeftOut() {
        // The dot has no gap (interleaved a and b) and isn't in the table either: where it is can't be told, so nothing that is on a side
        // of it can be written.
        let table: [String: Double] = [key("a", 0): 150, key("a", 1): 50, key("b", 0): 100]
        let result = place([always, .item(a), hidden, .item(b)], table)
        #expect(result.notPlaced == [always, hidden])
        // With its place in the table, •• is written around it.
        let placed = place([always, .item(a), hidden, .item(b)], table.merging([F.ownKey(OwnItems.hiddenDotName): 120]) { $1 })
        #expect(placed.notPlaced == [hidden])
        #expect((placed.distances[always] ?? 0) > 150)
    }

    @Test func theAppsThatBlockedAnOwnItemAreNamed() {
        // Interleaved a and b: the dot is left out because of both; b is the one whose place can't be told when a is gone.
        let table: [String: Double] = [key("a", 0): 150, key("a", 1): 50, key("b", 0): 100]
        #expect(place([.item(a), hidden, .item(b)], table).blockedBy == ["com.example.a", "com.example.b"])
        // An app whose place can't be told blocks nothing.
        #expect(place([.item(a), hidden, .item(b)], [key("b", 0): 100]).blockedBy.isEmpty)
        // Nothing blocked, nothing named; a named app left out isn't an own item, and isn't named.
        #expect(place([.item(a), hidden, .item(b)], [key("a", 0): 300, key("b", 0): 100]).blockedBy.isEmpty)
        let n = F.app("named")
        #expect(place([.item(a), .item(n), .item(b)], [key("a", 0): 100, key("b", 0): 300, F.key(n): 200], written: [.item(n): F.key(n)]).blockedBy.isEmpty)
    }

    @Test func appsAreNotWrittenAroundADotThatHasNoPlaceInTheTable() {
        // A new Mac before Mantel's first write: the dot has no entry. n and m are named apps that are written; x and b can't be, and have
        // places of their own. Wherever the dot is drawn, n and m would be put on a side of it that nothing says is theirs.
        let n = F.app("n"), m = F.app("m")
        let table: [String: Double] = [key("x", 0): 50, key("x", 1): 300, key("b", 0): 100, F.key(n): 700, F.key(m): 10]
        let x = F.nameless("x")
        let result = place([.item(n), .item(x), hidden, .item(b), .item(m)], table, written: [.item(n): F.key(n), .item(m): F.key(m)])
        #expect(result.distances.isEmpty, "nothing is written")
        #expect(result.notPlaced.contains(.item(n)) && result.notPlaced.contains(.item(m)))
        // With its place in the table, the dot divides them as it does: n is left of it, m right.
        let known = place([.item(n), .item(x), hidden, .item(b), .item(m)], table.merging([F.ownKey(OwnItems.hiddenDotName): 200]) { $1 },
                          written: [.item(n): F.key(n), .item(m): F.key(m)])
        #expect(known.distances[.item(n)] != nil || known.notPlaced.contains(.item(n)))
        if let at = known.distances[.item(n)] { #expect(at > 200) }
        if let at = known.distances[.item(m)] { #expect(at < 200) }
    }

    @Test func anAppIsNotWrittenAcrossADotTheChainLeavesOut() {
        // The table has the two dots the other way round (•• right of •), and the chain can hold only one of them. n is in Hidden, between
        // the dots: it is not written to the left of both, nor to the right of both, whichever dot the chain keeps.
        let n = F.app("n"), w = F.nameless("w"), z = F.nameless("z"), v = F.nameless("v")
        let table: [String: Double] = [
            key("w", 0): 200, key("z", 0): 50, key("z", 1): 500, key("v", 0): 400,
            F.ownKey(OwnItems.alwaysDotName): 100, F.ownKey(OwnItems.hiddenDotName): 300, F.key(n): 600,
        ]
        let result = place([.item(w), always, .item(n), .item(z), hidden, .item(v)], table, written: [.item(n): F.key(n)])
        #expect(result.distances[.item(n)] == nil)
        #expect(result.notPlaced.contains(.item(n)))
    }

    @Test func aStepSmallerThanTheWritersToleranceIsNoGap() {
        // The writer leaves a distance alone that is within 0.25 of the table's: a gap that small could hold the token's old place.
        #expect(place([.item(a), hidden, .item(b)], [key("a", 0): 100.6, key("b", 0): 100]).notPlaced == [hidden])
        #expect(place([.item(a), hidden, .item(b)], [key("a", 0): 102.5, key("b", 0): 100]).notPlaced.isEmpty)
    }

    @Test func noTokenEndsOnTheWrongSideOfAPlacedToken() {
        // Many arrangements of nameless apps (none to three keys each, anywhere in the table), named apps that are written, and Mantel's
        // own tokens, with places of their own in the table for two in three of them (some at the same distance as another token), from
        // a fixed seed: whatever the table says, every token that is placed has each token that isn't placed (an app, a dot, the divider)
        // on its side, none is at or below the system items' end, and nothing is placed while a token that isn't has no place to go by.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var placedAtAll = 0, leftOutOwn = 0
        for _ in 0..<1000 {
            var tokens: [LayoutToken] = []
            var table: [String: Double] = [:]
            var written: [LayoutToken: String] = [:]
            /// The table's distances of the keys each token stands for; none when its place can't be told.
            var places: [LayoutToken: [Double]] = [:]
            var ownLeft: [LayoutToken] = [always, hidden, divider]
            for index in 0..<(3 + next(5)) {
                if !ownLeft.isEmpty, next(3) == 0 { tokens.append(ownLeft.removeFirst()) }
                let token = LayoutToken.item(F.nameless("app\(index)"))
                tokens.append(token)
                places[token] = (0..<next(4)).map { item in
                    let value = Double(next(40) * 10)
                    table[key("app\(index)", item)] = value
                    return value
                }
                if next(5) == 0 {
                    let named = LayoutToken.item(F.app("named\(index)"))
                    let value = Double(next(40) * 10)
                    tokens.append(named)
                    written[named] = F.key(F.app("named\(index)"))
                    table[written[named]!] = value
                    places[named] = [value]
                }
            }
            tokens += ownLeft
            for own in [always, hidden, divider] where next(3) != 0 {
                let value = Double(next(40) * 10)
                table[ownKeys([own])[own]!] = value
                places[own] = [value]
            }
            let systemStart = Double(next(5) * 10)
            let result = place(tokens, table, written: written, systemStart: systemStart)

            let unplaced = tokens.filter { result.distances[$0] == nil }
            if unplaced.contains(where: { [always, hidden, divider].contains($0) }) { leftOutOwn += 1 }
            let own: Set<LayoutToken> = [always, hidden, divider]
            let dots: Set<LayoutToken> = [always, hidden]
            if unplaced.contains(where: { own.contains($0) && (places[$0] ?? []).isEmpty }) {
                #expect(result.distances.keys.allSatisfy { !own.contains($0) }, "an own item that isn't placed has no place to go around")
            }
            if unplaced.contains(where: { dots.contains($0) && (places[$0] ?? []).isEmpty }) {
                #expect(result.distances.isEmpty, "nothing is placed while a dot that isn't has no place: which side of it is not known")
            }
            #expect(Set(result.notPlaced).isDisjoint(with: result.distances.keys))
            // The tokens that aren't placed and have a place, in the arrangement's order: do they agree with it?
            var agree = true
            var below = Double.infinity
            for token in unplaced {
                guard let low = places[token]?.min(), let high = places[token]?.max() else { continue }
                if low >= below || high >= below { agree = false }
                below = min(below, low)
            }
            var previous = Double.infinity
            for (index, token) in tokens.enumerated() {
                guard let distance = result.distances[token] else { continue }
                placedAtAll += 1
                #expect(distance > systemStart)
                #expect(distance < previous, "the placed tokens are in the arrangement's order")
                previous = distance
                for other in unplaced where other != token {
                    // An app is on its side of every dot that isn't placed, whatever the others' places say; of the rest, when they agree.
                    guard own.contains(token) || agree || dots.contains(other) else { continue }
                    guard let at = tokens.firstIndex(of: other), let low = places[other]?.min(), let high = places[other]?.max() else { continue }
                    if at < index { #expect(low > distance, "a token left of this one is left of its distance") }
                    if at > index { #expect(high < distance, "a token right of this one is right of its distance") }
                }
            }
        }
        #expect(placedAtAll > 200, "the cases are not all refused")
        #expect(leftOutOwn > 50, "and Mantel's own items are among the ones left out often enough to matter")
    }

    @Test func applyingLeavesOutWhatCouldNotBePlaced() throws {
        let tokens: [LayoutToken] = [always, .item(a), hidden, .item(b)]
        // The table has b left of a: no gap for the dot, which stays at 125 (between them) where macOS has it.
        let table: [String: Double] = [key("a", 0): 100, key("b", 0): 150, F.ownKey(OwnItems.hiddenDotName): 125]
        let result = place(tokens, table)
        #expect(result.notPlaced == [hidden])
        let made = OwnItemPlacer.applying(result, to: arrangement(tokens))
        #expect(made.tokens == [always, .item(a), .item(b)])
        #expect(made.distances[hidden] == nil)
        #expect(made.distances[always] == result.distances[always], "the ones that were placed take their new distances")
    }
}
