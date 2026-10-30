import Foundation
import MKCore
import MKLayout
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync

/// What the layout editor asks of the session: a drop says the tokens it lands between, and the place in the list is worked out on the
/// session's own model.
@Suite("Menu bar session: layout editor drops", .timeLimit(.minutes(1)))
struct MenuBarSessionEditorTests {
    private func started() async -> SessionRig {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        return rig
    }

    /// The icons of the apps in the Shown list, by app, in order.
    private func order(_ sections: SectionModel) -> [String] {
        var seen: [String] = []
        for item in sections.items(in: .shown) where !item.isSystem && seen.last != item.bundleID { seen.append(item.bundleID) }
        return seen
    }

    private func request(_ drop: EditorDrop, between: DropAnchors, running: Set<String>? = nil) -> DropRequest {
        DropRequest(drop: drop, strip: .section(.shown), between: between, canReorder: true, running: running)
    }

    private func token(_ bundleID: String, in sections: SectionModel) -> StripToken {
        .app(bundleID: bundleID, items: sections.items(in: .shown).filter { $0.bundleID == bundleID })
    }

    @Test func aDropWorkedOutOnAnOlderListIsMadeBetweenItsNeighboursOnTheSessionsList() async {
        let rig = await started()
        let session = rig.session
        let model = await session.sections
        #expect(order(model) == [weather, notes, vpn, sync])

        // The pane's list held a system icon the session has already taken out: vpn before weather was the place 1 there, which on the
        // session's list is in the middle of the weather app's two icons.
        var stale = model
        stale.insert(.system("wifi"), in: .shown, at: 0)
        let running = Set(rig.world.runningBundleIDs)
        let context = LayoutEditorModel.DropContext(sections: stale, canReorder: true, inventory: await session.inventory, running: running)
        let drop = EditorDrop.token(token(vpn, in: stale), from: .section(.shown))
        let request = LayoutEditorModel.request(for: drop, onto: .section(.shown), at: 0, in: context)
        #expect(request.between.right == "app:\(weather)")
        #expect(LayoutEditorModel.operation(for: drop, onto: .section(.shown), at: 0, in: context) == .insert(token(vpn, in: stale).item!, .shown, 1))

        let done = await session.drop(request)

        #expect(done == .insert(token(vpn, in: model).item!, .shown, 0))
        #expect(order(await session.sections) == [vpn, weather, notes, sync])
    }

    @Test func aDropWhoseNeighbourHasLeftIsDeclinedAndNothingIsWritten() async {
        let rig = await started()
        let session = rig.session
        let model = await session.sections

        // Between notes and the VPN app, which went to Hidden meanwhile.
        let request = request(.token(token(sync, in: model), from: .section(.shown)), between: DropAnchors(left: "app:\(notes)", right: "app:\(vpn)"))
        await session.move(app: vpn, to: .hidden)
        let after = await session.sections
        let savedBefore = rig.saved.all.count

        let done = await session.drop(request)

        #expect(done == nil)
        #expect(await session.sections == after)
        #expect(rig.saved.all.count == savedBefore, "nothing was saved")
        #expect(order(after) == [weather, notes, sync])
    }

    @Test func aDropWhoseNeighboursAreStillThereIsMade() async {
        let rig = await started()
        let session = rig.session
        let model = await session.sections

        let request = request(.token(token(sync, in: model), from: .section(.shown)), between: DropAnchors(left: "app:\(weather)", right: "app:\(notes)"))
        let done = await session.drop(request)

        #expect(done != nil)
        #expect(order(await session.sections) == [weather, sync, notes, vpn])
    }
}
