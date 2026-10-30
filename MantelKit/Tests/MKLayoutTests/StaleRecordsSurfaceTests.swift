import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// What the places that list icons show of the records the sections hold of an app: the icons the app has, not the records of icons that
/// aren't there.
@Suite("Stale records on the surfaces", .timeLimit(.minutes(1)))
struct StaleRecordsSurfaceTests {
    private let appA = "com.example.a"
    private let appB = "com.example.b"
    private let appC = "com.example.c"

    private func index(_ bundleID: String, _ n: Int) -> ItemID { ItemID(bundleID: bundleID, key: .index(n)) }
    private func name(_ bundleID: String, _ name: String) -> ItemID { Fixtures.itemID(bundleID, name) }

    private func world(_ records: [ItemID], current: [String: Set<ItemID>]) -> (SectionModel, Inventory, StaleRecords) {
        var sections = SectionModel()
        sections.order[.shown] = records
        for app in Set(records.map(\.bundleID)) { sections.apps[app] = AppPlacement(section: .shown, isAuto: false) }
        let inventory = Fixtures.inventory(current.values.flatMap { $0 }.map { Fixtures.item($0) })
        return (sections, inventory, sections.staleRecords(current: current))
    }

    @Test func aRecordThatIsNotCurrentHasNoCell() {
        let (sections, inventory, stale) = world([index(appA, 0), name(appA, "x.phantom"), index(appB, 0)],
                                                 current: [appA: [index(appA, 0)], appB: [index(appB, 0)]])
        for model in [sections] {
            let entries = SecondBarContent.entries(level: .all, sections: { var m = model; m.move(app: appA, to: .hidden); m.move(app: appB, to: .hidden); return m }(),
                                                   inventory: inventory, running: [appA, appB], turnedOff: [], names: [:], widths: ItemWidthCache(),
                                                   allowClockAndControlCenter: false, stale: stale)
            #expect(entries.map(\.id) == [index(appA, 0), index(appB, 0)])
        }
        var hidden = sections
        hidden.move(app: appA, to: .hidden)
        hidden.move(app: appB, to: .hidden)
        let without = SecondBarContent.entries(level: .hidden, sections: hidden, inventory: inventory, running: [appA, appB], turnedOff: [],
                                               names: [:], widths: ItemWidthCache(), allowClockAndControlCenter: false)
        #expect(without.count == 3, "which is every record, as it was")
    }

    @Test func anAppsTokenHoldsOnlyItsCurrentIcons() {
        let (sections, inventory, stale) = world([name(appA, "x.phantom"), index(appA, 0), index(appB, 0)],
                                                 current: [appA: [index(appA, 0)], appB: [index(appB, 0)]])
        let running: Set<String> = [appA, appB]
        func token(_ strips: [Strip], _ app: String) -> StripToken? {
            strips.first { $0.id == .section(.shown) }?.tokens.map(\.token).first { $0.bundleID == app }
        }
        let all = LayoutEditorModel.strips(sections: sections, inventory: inventory, running: running, widths: ItemWidthCache())
        #expect(token(all, appA)?.item == name(appA, "x.phantom"), "every record, and a phantom first pins the place")
        let current = LayoutEditorModel.strips(sections: sections, inventory: inventory, running: running, widths: ItemWidthCache(), stale: stale)
        #expect(token(current, appA) == .app(bundleID: appA, items: [index(appA, 0)]))
        #expect(current.first { $0.id == .section(.shown) }?.tokens.map(\.token.id) == ["app:\(appA)", "app:\(appB)", "marker"])
    }

    @Test func aDropBesideAnAppWithHiddenRecordsLandsWhereShown() {
        // B's first record is one its app doesn't list. C is dragged between A and B.
        let (sections, inventory, stale) = world([name(appB, "x.phantom"), index(appA, 0), index(appB, 0), index(appC, 0)],
                                                 current: [appA: [index(appA, 0)], appB: [index(appB, 0)], appC: [index(appC, 0)]])
        let running: Set<String> = [appA, appB, appC]
        let strip = StripID.section(.shown)
        func shown(_ model: SectionModel) -> [String] {
            LayoutEditorModel.strips(sections: model, inventory: inventory, running: running, widths: ItemWidthCache(), stale: stale)
                .first { $0.id == strip }?.tokens.map(\.token.id).filter { $0 != "marker" } ?? []
        }
        #expect(shown(sections) == ["app:\(appA)", "app:\(appB)", "app:\(appC)"], "B is where its listed record is, not at the phantom's place")
        let tokens = LayoutEditorModel.strips(sections: sections, inventory: inventory, running: running, widths: ItemWidthCache(), stale: stale)
            .first { $0.id == strip }?.tokens.map(\.token) ?? []
        let c = tokens.first { $0.bundleID == appC }!
        let operation = LayoutEditorModel.operation(for: .token(c, from: strip), onto: strip, at: 1, sections: sections, canReorder: true,
                                                    inventory: inventory, running: running, stale: stale)
        guard case .insert = operation else {
            Issue.record("the drop lands: \(operation)")
            return
        }
        var after = sections
        LayoutEditorModel.apply(operation, created: nil, to: &after)
        #expect(shown(after) == ["app:\(appA)", "app:\(appC)", "app:\(appB)"], "C lands where the strip showed it, between A and B")
        #expect(after.order[.shown]?.first == name(appB, "x.phantom"), "and the phantom is where it was")
    }
}
