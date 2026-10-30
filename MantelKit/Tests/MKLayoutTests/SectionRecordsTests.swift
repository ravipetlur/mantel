import Foundation
import MKCore
import Testing

@testable import MKLayout

/// What is kept of an app's icons: the records the sections hold, noted from the apps' reads, and checked against what each app lists.
@Suite("Section records", .timeLimit(.minutes(1)))
struct SectionRecordsTests {
    private let appA = "com.example.a"
    private let appB = "com.example.b"
    private let appC = "com.example.c"

    private func id(_ bundleID: String, _ name: String) -> ItemID { Fixtures.itemID(bundleID, name) }
    private func index(_ bundleID: String, _ n: Int) -> ItemID { ItemID(bundleID: bundleID, key: .index(n)) }

    /// Records as the older version left them: every id noted, and the apps unchecked.
    private func old(_ ids: [ItemID], unchecked: Set<String>) -> SectionModel {
        var model = SectionModel()
        model.order[.shown] = ids
        for app in Set(ids.filter { !$0.isSystem }.map(\.bundleID)) { model.apps[app] = AppPlacement(section: .shown, isAuto: false) }
        model.unchecked = unchecked
        return model
    }

    @Test func noteRefusesMantelsNamesUnderAnotherApp() {
        var model = SectionModel()
        let own = [id(appA, OwnItems.hiddenDotName), id(appA, OwnItems.alwaysDotName), id(appA, OwnItems.dividerName),
                   id(appA, "mantel.spacer.12345678"), id(appA, "mantel.group.12345678")]
        model.note((own + [index(appA, 0)]).map { Fixtures.item($0) })
        #expect(model.order[.shown] == [index(appA, 0)])
        // The test item's own names aren't Mantel's.
        model.noteIcons([id(appB, "mantel.fixture.one")])
        #expect(model.order[.shown] == [index(appA, 0), id(appB, "mantel.fixture.one")])
    }

    @Test func reconcileKeepsCurrentRecordsInPlaceAndDropsTheRest() {
        let phantom = id(appA, "x.main-menu"), real = index(appA, 0), other = index(appB, 0)
        var model = old([phantom, other, real], unchecked: [appA, appB])
        let done = model.reconcile(app: appA, current: [real])
        #expect(model.order[.shown] == [other, real])
        #expect(done.kept == [real] && done.dropped == [phantom] && done.added.isEmpty)
        #expect(model.unchecked == [appB])
    }

    @Test func reconcilePutsANewCurrentIDInTheFirstDroppedPlace() {
        let first = id(appA, "x.one"), second = id(appA, "x.two"), kept = id(appA, "x.kept"), other = index(appB, 0)
        var model = old([first, other, kept, second], unchecked: [appA])
        // The app lists its kept icon and two the sections don't have.
        let new = index(appA, 0), newer = index(appA, 1)
        let done = model.reconcile(app: appA, current: [kept, new, newer])
        #expect(model.order[.shown] == [new, other, kept, newer], "each takes the place of a dropped record, in order")
        #expect(done.added == [new, newer])
        // More icons than records dropped: the rest are listed next to the app's last icon.
        var more = old([first, other], unchecked: [appA])
        more.reconcile(app: appA, current: [new, newer])
        #expect(more.order[.shown] == [new, newer, other])
    }

    @Test func staleRecordsAreTheOnesTheAppDoesNotListOrAllButTheFirstOfAnUncheckedApp() {
        let phantom = id(appA, "x.phantom"), real = index(appA, 0), b1 = index(appB, 0), b2 = id(appB, "y.name")
        var model = old([phantom, real, b1, b2], unchecked: [appA, appB])
        // Nothing read yet: an unchecked app is held to its first record.
        var stale = model.staleRecords(current: [:])
        #expect(stale.contains(real) && !stale.contains(phantom))
        #expect(stale.contains(b2) && !stale.contains(b1))
        // Read whole: the records that aren't in the read.
        stale = model.staleRecords(current: [appA: [real]])
        #expect(stale.contains(phantom) && !stale.contains(real))
        #expect(stale.contains(id(appA, "x.anything")), "an icon that isn't in the whole read isn't there")
        // A checked app is believed until it is read.
        model.unchecked = []
        #expect(model.staleRecords(current: [:]) == .none)
        #expect(!model.staleRecords(current: [:]).contains(phantom))
        // A system item and Mantel's own are never stale.
        #expect(!stale.contains(ItemID.system("wifi")))
    }

    @Test func theFilesMigrationKeepsTheMarkerBeforeTheSameIcon() throws {
        func text(_ bundleID: String, _ name: String) -> String { id(bundleID, name).string }
        let own = text(appA, OwnItems.hiddenDotName), ownToo = text(appA, OwnItems.alwaysDotName)
        func migrated(_ order: [String], marker: Int?) throws -> (list: [String], marker: Int?) {
            var sections: [String: Any] = ["newItems": "shown", "order": ["shown": order, "hidden": [own, text(appB, "b.one")]]]
            if let marker { sections["newItemsIndex"] = marker }
            let document: [String: Any] = ["profiles": [["name": "Default", "sections": sections]]]
            let result = try ProfilesDocument.migrate(document, from: 1)
            let profile = try #require((result["profiles"] as? [[String: Any]])?.first)
            let after = try #require(profile["sections"] as? [String: Any])
            return ((after["order"] as? [String: [String]])?["shown"] ?? [], after["newItemsIndex"] as? Int)
        }
        let b = text(appB, "b.one"), c = text(appC, "c.one"), d = text(appC, "c.two")
        // Two records before the marker are dropped: it is before `c.one` still, and not two places further.
        var done = try migrated([own, b, ownToo, c, d], marker: 3)
        #expect(done.list == [b, c, d] && done.marker == 1)
        // The marker at the end stays at the end; one before every icon stays there.
        done = try migrated([b, own, c], marker: 3)
        #expect(done.list == [b, c] && done.marker == 2)
        done = try migrated([own, b, c], marker: 0)
        #expect(done.list == [b, c] && done.marker == 0)
        // A record dropped after the marker doesn't move it, and a file with no marker has none.
        done = try migrated([b, c, own, d], marker: 1)
        #expect(done.list == [b, c, d] && done.marker == 1)
        done = try migrated([own, b], marker: nil)
        #expect(done.list == [b] && done.marker == nil)
        // The lists of other sections aren't the marker's.
        let hidden = try migrated([b], marker: 1)
        #expect(hidden.marker == 1)
    }
}
