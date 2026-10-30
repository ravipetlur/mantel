import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// A change the pane sends is shown at once, and a drop is made where it was dropped whatever the session's list is when it runs: the
/// pane decides on the model with the changes before it made, the session applies them in queue order, and the drop says the tokens it lands
/// between, not a number.
@Suite("Layout editor: changes being made", .timeLimit(.minutes(1)))
struct LayoutEditorPendingTests {
    private let appA = "com.example.a"
    private let appB = "com.example.b"
    private let appC = "com.example.c"
    private let quit = "com.example.quit"

    private func id(_ bundleID: String, _ name: String = "main") -> ItemID {
        Fixtures.itemID(bundleID, name)
    }

    private struct World {
        var sections: SectionModel
        var inventory: Inventory
        var running: Set<String>

        func strip(_ strip: StripID = .section(.shown), of sections: SectionModel? = nil) -> [String] {
            LayoutEditorModel.strips(sections: sections ?? self.sections, inventory: inventory, running: running, widths: ItemWidthCache())
                .first { $0.id == strip }?.tokens.map(\.token.id) ?? []
        }
    }

    private let spacerS = SpacerID(rawValue: "0000000a")
    private var own: ItemID { OwnItems.itemID(spacerS) }

    /// Shown: Wi-Fi, a spacer, an app that isn't running, then A, B and C. Hidden holds a fourth app.
    private func world() -> World {
        let wifi = ItemID.system("wifi")
        let listed = [wifi, id(quit), id(appA), id(appB), id(appC)]
        var sections = SectionModel()
        sections.note(listed.map { Fixtures.item($0) })
        sections.addSpacer(LayoutSpacer(id: spacerS), in: .shown, at: 1)
        let inventory = Fixtures.inventory(listed.map { Fixtures.item($0) })
        return World(sections: sections, inventory: inventory, running: Set([appA, appB, appC]))
    }

    private func token(_ bundleID: String) -> StripToken {
        .app(bundleID: bundleID, items: [id(bundleID)])
    }

    /// One change as the pane asks for it, and as the session makes it.
    private struct Change {
        var edit: (World, PendingMoves) -> PendingMoves.Edit
        var session: (inout SectionModel) -> Void
    }

    // MARK: A change before a drop

    /// The pane asks for each change (shown at once), then decides a drop on what it shows; the session makes the changes in the order they
    /// were sent, then the drop. The drop must land where it was made, and the strip must show what the pane showed.
    private func replay(_ changes: [Change], dropping drop: (World) -> (EditorDrop, StripID, Int), expected: [String],
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let base = world()
        var pending = PendingMoves()
        var session = base.sections

        for change in changes {
            let shown = pending.applied(to: base.sections, inventory: base.inventory)
            pending.ask(change.edit(base, pending), on: shown, inventory: base.inventory)
            change.session(&session)
        }

        // The pane decides on what it shows.
        let shown = pending.applied(to: base.sections, inventory: base.inventory)
        let (what, onto, index) = drop(World(sections: shown, inventory: base.inventory, running: base.running))
        let context = LayoutEditorModel.DropContext(sections: shown, canReorder: true, inventory: base.inventory, running: base.running)
        let request = LayoutEditorModel.request(for: what, onto: onto, at: index, in: context)
        pending.ask(.drop(request), on: shown, inventory: base.inventory)
        let displayed = pending.applied(to: base.sections, inventory: base.inventory)

        // The session makes the drop after them.
        guard let operation = LayoutEditorModel.resolve(request, sections: session, inventory: base.inventory) else {
            Issue.record("the drop wasn't made", sourceLocation: sourceLocation)
            return
        }
        LayoutEditorModel.apply(operation, created: request.created, to: &session)

        #expect(base.strip(onto, of: session) == expected, sourceLocation: sourceLocation)
        #expect(base.strip(onto, of: displayed) == expected, "what the pane showed", sourceLocation: sourceLocation)
    }

    private var bBeforeA: (World) -> (EditorDrop, StripID, Int) {
        { world in
            let tokens = world.strip()
            let place = tokens.firstIndex(of: "app:\(appA)")!
            return (.token(token(appB), from: .section(.shown)), .section(.shown), place)
        }
    }

    private var system: Change {
        Change(edit: { _, _ in .system(module: "wifi", .hidden) }, session: { $0.move(item: .system("wifi"), to: .hidden) })
    }

    @Test func aSystemIconSetToHiddenThenADropLandsWhereItWasDropped() {
        // The review's case: the pane's list still held Wi-Fi when the drop was worked out.
        replay([system], dropping: bBeforeA,
               expected: ["own:\(own.string)", "app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
    }

    @Test func aRemovedSpacerThenADropLandsWhereItWasDropped() {
        replay([Change(edit: { _, _ in .remove(own) }, session: { $0.removeOwnItem(own) })], dropping: bBeforeA,
               expected: ["app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
    }

    @Test func aForgottenAppThenADropLandsWhereItWasDropped() {
        replay([Change(edit: { _, _ in .forget(bundleID: quit) }, session: { $0.forget(app: quit) })], dropping: bBeforeA,
               expected: ["own:\(own.string)", "app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
    }

    @Test func aSpacerAddedAtTheStartThenADropLandsWhereItWasDropped() {
        let added = LayoutSpacer(id: SpacerID(rawValue: "0000000c"))
        let addedToken = "own:\(OwnItems.itemID(added.id).string)"
        let add = Change(
            edit: { world, pending in
                let shown = pending.applied(to: world.sections, inventory: world.inventory)
                let context = LayoutEditorModel.DropContext(sections: shown, canReorder: true, inventory: world.inventory, running: world.running)
                var request = LayoutEditorModel.request(for: .palette(.spacer), onto: .section(.shown), at: 0, in: context)
                request.created = .spacer(added)
                return .drop(request)
            },
            session: { $0.addSpacer(added, in: .shown, at: 0) })
        replay([add], dropping: bBeforeA,
               expected: [addedToken, "own:\(own.string)", "app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
    }

    @Test func severalChangesInARowThenADropLandsWhereItWasDropped() {
        replay([system, Change(edit: { _, _ in .remove(own) }, session: { $0.removeOwnItem(own) }),
                Change(edit: { _, _ in .forget(bundleID: quit) }, session: { $0.forget(app: quit) })],
               dropping: bBeforeA, expected: ["app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
    }

    // MARK: A list that isn't the one the drop was worked out on

    @Test func aDropWorkedOutOnAnOlderListIsStillMadeBetweenItsNeighbours() {
        // Without the pending change the pane's list holds Wi-Fi: dropping B before A is the place 3 (after wifi, S, quit)... on that list.
        let base = world()
        let context = LayoutEditorModel.DropContext(sections: base.sections, canReorder: true, inventory: base.inventory, running: base.running)
        let request = LayoutEditorModel.request(for: .token(token(appB), from: .section(.shown)), onto: .section(.shown), at: 1, in: context)
        #expect(request.between == DropAnchors(left: "own:\(own.string)", right: "app:\(appA)"))

        // The session has taken Wi-Fi, the spacer and the quit app out first: the list is A, B, C.
        var session = base.sections
        session.move(item: .system("wifi"), to: .hidden)
        session.removeOwnItem(own)
        session.forget(app: quit)
        #expect(session.items(in: .shown) == [id(appA), id(appB), id(appC)])
        // The spacer it lands beside is gone: nothing is made.
        #expect(LayoutEditorModel.resolve(request, sections: session, inventory: base.inventory) == nil)

        // Beside tokens that are still there, the same drop is made between them, whatever the list holds.
        var other = base.sections
        other.move(item: .system("wifi"), to: .hidden)
        other.forget(app: quit)
        let made = LayoutEditorModel.resolve(request, sections: other, inventory: base.inventory)
        #expect(made == .insert(id(appB), .shown, 1))
        var after = other
        LayoutEditorModel.apply(made!, created: nil, to: &after)
        #expect(base.strip(of: after) == ["own:\(own.string)", "app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
    }

    @Test func aDropIsDeclinedAndNothingIsWrittenWhenANeighbourHasLeftTheStrip() {
        let base = world()
        let context = LayoutEditorModel.DropContext(sections: base.sections, canReorder: true, inventory: base.inventory, running: base.running)
        // A dropped between B and C.
        let request = LayoutEditorModel.request(for: .token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 3, in: context)
        #expect(request.between == DropAnchors(left: "app:\(appB)", right: "app:\(appC)"))
        #expect(LayoutEditorModel.resolve(request, sections: base.sections, inventory: base.inventory) != nil)

        // C went to Hidden meanwhile, B to Always Hidden, the pair is no longer a pair, the app quit.
        var moved = base.sections
        moved.move(app: appC, to: .hidden)
        #expect(LayoutEditorModel.resolve(request, sections: moved, inventory: base.inventory) == nil)
        var swapped = base.sections
        swapped.insert(id(appC), in: .shown, at: 2)
        #expect(LayoutEditorModel.resolve(request, sections: swapped, inventory: base.inventory) == nil)
    }

    @Test func aNeighbourThatQuitsAfterTheDropIsStillWhereTheDropLands() {
        // The request keeps the apps that were running when it was made, as the session doesn't know them: an app that quits meanwhile is
        // still the neighbour, by its listed icon, and the drop is made beside it (not declined).
        let base = world()
        let context = LayoutEditorModel.DropContext(sections: base.sections, canReorder: true, inventory: base.inventory, running: base.running)
        let request = LayoutEditorModel.request(for: .token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 3, in: context)
        #expect(request.between == DropAnchors(left: "app:\(appB)", right: "app:\(appC)"))

        let made = LayoutEditorModel.resolve(request, sections: base.sections, inventory: base.inventory)
        #expect(made != nil)
        var after = base.sections
        LayoutEditorModel.apply(made!, created: nil, to: &after)
        #expect(base.strip(of: after) == ["own:\(own.string)", "app:\(appB)", "app:\(appA)", "app:\(appC)", "marker"])
        // C is gone from the strip by then: A shows where it was put, beside B.
        let withoutC = World(sections: base.sections, inventory: base.inventory, running: [appA, appB])
        #expect(withoutC.strip(of: after) == ["own:\(own.string)", "app:\(appB)", "app:\(appA)", "marker"])
    }

    @Test func theStartAndTheEndAreAnchorsToo() {
        let base = world()
        let context = LayoutEditorModel.DropContext(sections: base.sections, canReorder: true, inventory: base.inventory, running: base.running)
        let first = LayoutEditorModel.request(for: .token(token(appC), from: .section(.shown)), onto: .section(.shown), at: 0, in: context)
        let last = LayoutEditorModel.request(for: .token(token(appA), from: .section(.shown)), onto: .section(.hidden), at: 0, in: context)
        #expect(first.between == DropAnchors(left: nil, right: "own:\(own.string)"))
        #expect(last.between == DropAnchors(left: nil, right: nil))
        // A new app arrives at the front meanwhile: "the start" is still the start.
        #expect(LayoutEditorModel.resolve(first, sections: base.sections, inventory: base.inventory) == .insert(id(appC), .shown, 1))
    }

    // MARK: Settling in order

    /// Shown starts as `[wifi, S, quit, A, B, C]`. The person sets Wi-Fi to Hidden (change 0), adds a spacer at the end of Shown (change 1)
    /// and drags A to the right of it (change 2). Returns what the pane has asked, the spacer, and what the session has made of change 0.
    private func quickSeries() -> (base: World, pending: PendingMoves, added: LayoutSpacer, published: SectionModel) {
        let base = world()
        var pending = PendingMoves()
        pending.ask(.system(module: "wifi", .hidden), on: base.sections, inventory: base.inventory)

        let added = LayoutSpacer(id: SpacerID(rawValue: "0000000c"))
        var shown = pending.applied(to: base.sections, inventory: base.inventory)
        var add = dropRequest(.palette(.spacer), onto: .section(.shown), at: base.strip(of: shown).count - 1, in: base, shown: shown)
        add.created = .spacer(added)
        pending.ask(.drop(add), on: shown, inventory: base.inventory)

        shown = pending.applied(to: base.sections, inventory: base.inventory)
        let tokens = base.strip(of: shown)
        let afterAdded = tokens.firstIndex(of: "own:\(OwnItems.itemID(added.id).string)")! + 1
        pending.ask(.drop(dropRequest(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: afterAdded, in: base, shown: shown)),
                    on: shown, inventory: base.inventory)

        var published = base.sections
        published.move(item: .system("wifi"), to: .hidden)
        return (base, pending, added, published)
    }

    @Test func aDropBesideANewSpacerStaysShownWhenOnlyTheFirstChangeHasBeenMade() {
        let series = quickSeries()
        let base = series.base
        let added = series.added
        var pending = series.pending
        var published = series.published
        let addedToken = "own:\(OwnItems.itemID(added.id).string)"
        let expected = ["own:\(own.string)", "app:\(appB)", "app:\(appC)", addedToken, "app:\(appA)", "marker"]
        #expect(base.strip(of: pending.applied(to: base.sections, inventory: base.inventory)) == expected)

        // The session has made change 0 and published it: the other two are still to come, and are still shown as they were asked.
        pending.settle(against: published, inventory: base.inventory)
        #expect(pending.edits.count == 2)
        let shown = pending.applied(to: published, inventory: base.inventory)
        #expect(base.strip(of: shown) == expected)

        // Then change 1 is published; change 2 is still to come.
        published.addSpacer(added, in: .shown, at: published.items(in: .shown).count)
        pending.settle(against: published, inventory: base.inventory)
        #expect(pending.edits.count == 1)
        #expect(base.strip(of: pending.applied(to: published, inventory: base.inventory)) == expected)

        // And change 2.
        let model = pending.applied(to: published, inventory: base.inventory)
        pending.settle(against: model, inventory: base.inventory)
        #expect(pending.isEmpty)
    }

    @Test func aPaletteGroupIsLetGoOnceTheModelHasItAndItsFieldsAreTheModels() {
        let base = world()
        let group = IconGroup(id: GroupID(rawValue: "0000000d"))
        var request = dropRequest(.palette(.group), onto: .section(.hidden), at: 0, in: base)
        request.created = .group(group)
        var pending = PendingMoves()
        pending.ask(.drop(request), on: base.sections, inventory: base.inventory)
        #expect(pending.applied(to: base.sections, inventory: base.inventory).groups[group.id] != nil, "shown at once")

        // The session added it, and the person's title followed before the pane saw the add.
        var published = base.sections
        published.addGroup(group, in: .hidden, at: 0)
        var titled = group
        titled.title = "Work"
        published.updateGroup(titled)
        pending.settle(against: published, inventory: base.inventory)

        #expect(pending.isEmpty)
        #expect(pending.applied(to: published, inventory: base.inventory).groups[group.id]?.title == "Work")

        // The same for a spacer's width.
        var spacerRequest = dropRequest(.palette(.spacer), onto: .section(.shown), at: 0, in: base)
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "0000000e"))
        spacerRequest.created = .spacer(spacer)
        var more = PendingMoves()
        more.ask(.drop(spacerRequest), on: base.sections, inventory: base.inventory)
        var wide = spacer
        wide.width = 80
        var model = base.sections
        model.addSpacer(spacer, in: .shown, at: 0)
        model.updateSpacer(wide)
        #expect(more.applied(to: model, inventory: base.inventory).spacers[spacer.id]?.width == 80)
        more.settle(against: model, inventory: base.inventory)
        #expect(more.isEmpty)
    }

    // MARK: What is shown

    private func dropRequest(_ what: EditorDrop, onto strip: StripID, at index: Int, in world: World, shown: SectionModel? = nil) -> DropRequest {
        let context = LayoutEditorModel.DropContext(sections: shown ?? world.sections, canReorder: true, inventory: world.inventory,
                                                    running: world.running)
        return LayoutEditorModel.request(for: what, onto: strip, at: index, in: context)
    }

    @Test func aPendingDropShowsTheIconAtItsPlaceNotAtTheEnd() {
        var base = world()
        base.sections.move(app: appC, to: .hidden)
        var pending = PendingMoves()
        let request = dropRequest(.token(token(appC), from: .section(.hidden)), onto: .section(.shown), at: 1, in: base)
        pending.ask(.drop(request), on: base.sections, inventory: base.inventory)

        let shown = pending.applied(to: base.sections, inventory: base.inventory)

        #expect(base.strip(of: shown) == ["own:\(own.string)", "app:\(appC)", "app:\(appA)", "app:\(appB)", "marker"])
        #expect(base.strip(of: base.sections) == ["own:\(own.string)", "app:\(appA)", "app:\(appB)", "marker"], "the model isn't changed")
        #expect(!pending.isEmpty)
    }

    @Test func aGroupMoveAndTheMarkerKeepTheirPlaces() {
        var base = world()
        let group = IconGroup(id: GroupID(rawValue: "0000000b"))
        base.sections.addGroup(group, in: .hidden, at: 0)
        base.sections.move(app: appA, toGroup: group.id, at: 0)
        var pending = PendingMoves()
        pending.ask(.drop(dropRequest(.token(token(appC), from: .section(.shown)), onto: .group(group.id), at: 0, in: base)),
                    on: base.sections, inventory: base.inventory)
        let shown = pending.applied(to: base.sections, inventory: base.inventory)
        pending.ask(.drop(dropRequest(.token(.marker, from: .section(.shown)), onto: .section(.shown), at: 0, in: base, shown: shown)),
                    on: shown, inventory: base.inventory)

        let after = pending.applied(to: base.sections, inventory: base.inventory)

        #expect(after.groups[group.id]?.members == [appC, appA])
        #expect(base.strip(of: after).first == "marker")
    }

    @Test func aLaterAskForTheSameThingReplacesTheEarlierAndOneThatChangesNothingIsNotKept() {
        let base = world()
        var pending = PendingMoves()
        pending.ask(.drop(dropRequest(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 4, in: base)),
                    on: base.sections, inventory: base.inventory)
        let second = dropRequest(.token(token(appA), from: .section(.shown)), onto: .section(.hidden), at: 0, in: base)
        pending.ask(.drop(second), on: base.sections, inventory: base.inventory)
        #expect(pending.edits == [.drop(second)])

        // Where it is already: nothing to show.
        var none = PendingMoves()
        none.ask(.drop(dropRequest(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 2, in: base)),
                 on: base.sections, inventory: base.inventory)
        #expect(none.isEmpty)
        none.ask(.forget(bundleID: "com.example.never-seen"), on: base.sections, inventory: base.inventory)
        none.ask(.system(module: "wifi", .shown), on: base.sections, inventory: base.inventory)
        #expect(none.isEmpty)
    }

    @Test func eachKindOfChangeEndsWhenTheModelHasItAndNotBefore() {
        let base = world()
        var pending = PendingMoves()
        pending.ask(.system(module: "wifi", .hidden), on: base.sections, inventory: base.inventory)
        pending.ask(.remove(own), on: base.sections, inventory: base.inventory)
        pending.ask(.forget(bundleID: quit), on: base.sections, inventory: base.inventory)
        let moveC = dropRequest(.token(token(appC), from: .section(.shown)), onto: .section(.hidden), at: 0, in: base)
        pending.ask(.drop(moveC), on: base.sections, inventory: base.inventory)
        #expect(pending.edits.count == 4)

        // Another app was moved and a new one placed: nothing here is settled.
        var other = base.sections
        other.move(app: "com.example.other", to: .hidden)
        other.assignNew(apps: ["com.example.fresh"])
        pending.settle(against: other, inventory: base.inventory)
        #expect(pending.edits.count == 4)

        // Each arrives, one at a time.
        var model = base.sections
        model.move(item: .system("wifi"), to: .hidden)
        pending.settle(against: model, inventory: base.inventory)
        #expect(pending.edits.count == 3)
        model.removeOwnItem(own)
        pending.settle(against: model, inventory: base.inventory)
        #expect(pending.edits.count == 2)
        model.forget(app: quit)
        pending.settle(against: model, inventory: base.inventory)
        #expect(pending.edits == [.drop(moveC)])
        LayoutEditorModel.apply(LayoutEditorModel.resolve(moveC, sections: model, inventory: base.inventory)!, created: nil, to: &model)
        pending.settle(against: model, inventory: base.inventory)
        #expect(pending.isEmpty)
    }

    @Test func aForgottenAppThatComesBackIsNotHiddenAgain() {
        let base = world()
        var pending = PendingMoves()
        pending.ask(.forget(bundleID: quit), on: base.sections, inventory: base.inventory)
        #expect(!pending.applied(to: base.sections, inventory: base.inventory).items(in: .shown).contains(id(quit)))

        // The session forgot it: the edit is let go. The app comes back, and it is listed.
        var model = base.sections
        model.forget(app: quit)
        pending.settle(against: model, inventory: base.inventory)
        #expect(pending.isEmpty)
        model.note([Fixtures.item(id(quit))])
        #expect(pending.applied(to: model, inventory: base.inventory).items(in: .shown).contains(id(quit)))
    }

    @Test func aSystemIconMovedBackToWhereItWasIsNotKept() {
        let base = world()
        var pending = PendingMoves()
        pending.ask(.system(module: "wifi", .hidden), on: base.sections, inventory: base.inventory)
        let shown = pending.applied(to: base.sections, inventory: base.inventory)
        #expect(shown.items(in: .hidden) == [.system("wifi")], "the session files it in the other section's list too")
        #expect(shown.items(in: .shown).contains(.system("wifi")) == false)
        pending.ask(.system(module: "wifi", .shown), on: shown, inventory: base.inventory)
        #expect(pending.edits == [.system(module: "wifi", .shown)], "the later ask replaces the earlier")
        pending.settle(against: base.sections, inventory: base.inventory)
        #expect(pending.isEmpty)
    }

    @Test func aPendingMoveToAnotherSectionPutsTheRowThere() {
        var base = world()
        base.sections.move(app: appA, to: .shown)
        var pending = PendingMoves()
        pending.ask(.drop(dropRequest(.token(token(appA), from: .section(.shown)), onto: .section(.hidden), at: 0, in: base)),
                    on: base.sections, inventory: base.inventory)
        let rows = LayoutRows.apps(inventory: base.inventory, sections: pending.applied(to: base.sections, inventory: base.inventory), names: [:])
        #expect(rows[.hidden]?.map(\.id) == [appA])
    }
}
