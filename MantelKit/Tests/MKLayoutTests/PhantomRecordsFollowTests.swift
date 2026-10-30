import MKCore
import Testing

@testable import MKLayout

/// A ⌘-drag in the menu bar, and the order Settings then shows, when the app dragged had a record of an icon it doesn't have.
@Suite("Phantom records and the order", .timeLimit(.minutes(1)))
struct PhantomRecordsFollowTests {
    private typealias F = ArrangementFixtures

    @Test func aCommandDragIsShownWhereTheBarHasIt() {
        let a = F.nameless("a", 0), b = F.nameless("b", 0)
        let phantom = ItemID(bundleID: a.bundleID, key: .identifier("x.main-menu"))
        var sections = F.sections(shown: [phantom, a, b])
        sections.unchecked = [a.bundleID]
        let inventory = Fixtures.inventory([Fixtures.item(a), Fixtures.item(b)])

        // A is dragged right of B on the bar. The follower orders the records it sees; the phantom keeps its place.
        let followed = LayoutFollower.follow(sections, observed: ObservedOrder(tokens: [.item(b), .item(a)], source: .table),
                                             placement: .betweenSections, sectionsMayChange: true, before: nil)
        #expect(followed.order[.shown] == [phantom, b, a])

        func shown(_ stale: StaleRecords) -> [String] {
            LayoutEditorModel.strips(sections: followed, inventory: inventory, running: [a.bundleID, b.bundleID], widths: ItemWidthCache(),
                                     stale: stale).first { $0.id == .section(.shown) }?.tokens.map(\.token.id).filter { $0 != "marker" } ?? []
        }
        #expect(shown(.none) == ["app:\(a.bundleID)", "app:\(b.bundleID)"], "the phantom pins A's place: not the bar's order")
        let read = followed.staleRecords(current: [a.bundleID: [a], b.bundleID: [b]])
        #expect(shown(read) == ["app:\(b.bundleID)", "app:\(a.bundleID)"], "A is where its icon is")
    }
}
