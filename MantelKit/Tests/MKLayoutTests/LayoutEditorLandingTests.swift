import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// A drop must land exactly where the strip shows it, or be declined. The section's list holds icons that have no token (system items,
/// apps that aren't running), so a place among the tokens is not a place in the list.
@Suite("Layout editor landings", .timeLimit(.minutes(1)))
struct LayoutEditorLandingTests {
    private let appA = "com.example.a"
    private let appB = "com.example.b"
    private let appC = "com.example.c"
    private let quit = "com.example.quit"
    private let unlisted = "com.example.unlisted"
    private let member1 = "com.example.member1"
    private let member2 = "com.example.member2"
    private let memberQuit = "com.example.memberquit"

    private func id(_ bundleID: String, _ name: String = "main") -> ItemID {
        Fixtures.itemID(bundleID, name)
    }

    private func simple(_ ids: [ItemID], running: Set<String>? = nil) -> World {
        var sections = SectionModel()
        let items = ids.map { Fixtures.item($0) }
        sections.note(items)
        let inventory = Fixtures.inventory(items)
        return World(sections: sections, inventory: inventory, running: running ?? Set(inventory.items.map(\.ownerBundleID)))
    }

    private struct World {
        var sections: SectionModel
        var inventory: Inventory
        var running: Set<String>

        var strips: [Strip] {
            LayoutEditorModel.strips(sections: sections, inventory: inventory, running: running, widths: ItemWidthCache())
        }
    }

    private func operation(_ drop: EditorDrop, onto strip: StripID, at index: Int, _ world: World, canReorder: Bool = true) -> EditorOperation {
        LayoutEditorModel.operation(for: drop, onto: strip, at: index, sections: world.sections, canReorder: canReorder,
                                    inventory: world.inventory, running: world.running)
    }

    private func app(_ bundleID: String, in world: World) -> StripToken {
        world.strips.flatMap(\.tokens).map(\.token).first { $0.bundleID == bundleID }!
    }

    private func ids(_ strip: StripID, in world: World) -> [String] {
        world.strips.first { $0.id == strip }?.tokens.map(\.token.id) ?? []
    }

    /// What the session does with an operation, on a model; the id of the token a palette drop makes.
    @discardableResult
    private func apply(_ operation: EditorOperation, to sections: inout SectionModel) -> String? {
        switch operation {
        case .insert(let item, let section, let index):
            sections.insert(item, in: section, at: index)
        case .moveToGroup(let bundleID, let group, let index):
            sections.move(app: bundleID, toGroup: group, at: index)
        case .addSpacer(let section, let index):
            let spacer = LayoutSpacer()
            sections.addSpacer(spacer, in: section, at: index)
            return "own:\(OwnItems.itemID(spacer.id).string)"
        case .addGroup(let section, let index):
            let group = IconGroup()
            sections.addGroup(group, in: section, at: index)
            return "own:\(OwnItems.itemID(group.id).string)"
        case .marker(let section, let index):
            sections.setNewItemsMarker(section: section, index: index)
        case .noChange, .refused:
            break
        }
        return nil
    }

    // MARK: The cases the review names

    @Test func aDropAfterTheLastTokenWithASystemItemBeforeItKeepsItsPlace() {
        let world = simple([.system("wifi"), id(appA), id(appB)])
        #expect(world.sections.items(in: .shown) == [.system("wifi"), id(appA), id(appB)])
        #expect(ids(.section(.shown), in: world) == ["app:\(appA)", "app:\(appB)", "marker"])

        // A dropped after B: the list is wifi, B, A.
        let reorder = operation(.token(app(appA, in: world), from: .section(.shown)), onto: .section(.shown), at: 2, world)
        #expect(reorder == .insert(id(appA), .shown, 2))
        // A spacer between A and B, the marker between them.
        #expect(operation(.palette(.spacer), onto: .section(.shown), at: 1, world) == .addSpacer(.shown, 2))
        #expect(operation(.palette(.marker), onto: .section(.shown), at: 1, world) == .marker(.shown, 2))
    }

    @Test func aQuitAppBeforeTheDropDoesNotMoveItLeft() {
        var world = simple([id(appA), id(quit), id(appB)], running: [appA, appB])
        world.sections.move(app: appA, to: .hidden)
        world.sections.move(app: quit, to: .hidden)
        world.sections.move(app: appB, to: .hidden)
        world.sections.move(app: appC, to: .shown)
        let x = StripToken.app(bundleID: appC, items: [id(appC)])
        world.inventory = Fixtures.inventory(world.inventory.items + [Fixtures.item(id(appC))])
        world.running.insert(appC)
        #expect(world.sections.items(in: .hidden) == [id(appA), id(quit), id(appB)])
        #expect(ids(.section(.hidden), in: world) == ["app:\(appA)", "app:\(appB)"])

        // "Move to › Hidden" puts X at the end of the strip.
        let end = operation(.token(x, from: .section(.shown)), onto: .section(.hidden), at: 2, world)
        var after = world.sections
        apply(end, to: &after)
        let shown = LayoutEditorModel.strips(sections: after, inventory: world.inventory, running: world.running, widths: ItemWidthCache())
        #expect(shown.first { $0.id == .section(.hidden) }?.tokens.map(\.token.id) == ["app:\(appA)", "app:\(appB)", "app:\(appC)"])
    }

    @Test func aGroupMemberThatIsNotRunningDoesNotShiftTheDrop() {
        var world = simple([id(appA), id(appB), id(quit)], running: [appA, appB])
        let group = IconGroup(id: GroupID(rawValue: "0000000b"))
        world.sections.addGroup(group, in: .hidden, at: 0)
        world.sections.move(app: quit, toGroup: group.id, at: 0)
        world.sections.move(app: appA, toGroup: group.id, at: 1)
        world.sections.move(app: appB, toGroup: group.id, at: 2)
        #expect(world.sections.groups[group.id]?.members == [quit, appA, appB])
        #expect(ids(.group(group.id), in: world) == ["app:\(appA)", "app:\(appB)"])

        // A dragged after B.
        let token = app(appA, in: world)
        let operation = operation(.token(token, from: .group(group.id)), onto: .group(group.id), at: 2, world)
        var after = world.sections
        apply(operation, to: &after)

        #expect(after.groups[group.id]?.members == [quit, appB, appA])
    }

    // MARK: Where a drop is snapped to

    private func context(_ world: World, canReorder: Bool = true, cantReorder: Set<String> = []) -> LayoutEditorModel.DropContext {
        .init(sections: world.sections, canReorder: canReorder, cantReorder: cantReorder, inventory: world.inventory, running: world.running)
    }

    /// The drop as the pane makes it: where it lands near a place, then the request and what the session makes of it. The strip after it.
    private func dropped(_ drop: EditorDrop, onto strip: StripID, near place: Int, _ world: World, canReorder: Bool = true) -> (landing: Int?, strip: [String]) {
        let context = context(world, canReorder: canReorder)
        guard let landing = LayoutEditorModel.landingPlace(for: drop, onto: strip, near: place, in: context) else { return (nil, ids(strip, in: world)) }
        let request = LayoutEditorModel.request(for: drop, onto: strip, at: landing, in: context)
        var after = world.sections
        if let operation = LayoutEditorModel.resolve(request, sections: world.sections, inventory: world.inventory) {
            LayoutEditorModel.apply(operation, created: request.created, to: &after)
        }
        var moved = world
        moved.sections = after
        return (landing, ids(strip, in: moved))
    }

    @Test func aGroupStripTakesAnAppAnywhereAndNothingElse() {
        var world = simple([id(appA), id(appB)])
        let group = IconGroup(id: GroupID(rawValue: "0000000b"))
        world.sections.addGroup(group, in: .hidden, at: 0)
        world.sections.move(app: appB, toGroup: group.id, at: 0)
        let strip = StripID.group(group.id)
        for place in 0...1 {
            #expect(LayoutEditorModel.landingPlace(for: .token(app(appA, in: world), from: .section(.shown)), onto: strip, near: place,
                                                   in: context(world)) == place)
            #expect(LayoutEditorModel.landingPlace(for: .palette(.spacer), onto: strip, near: place, in: context(world)) == nil)
            #expect(LayoutEditorModel.landingPlace(for: .token(.marker, from: .section(.shown)), onto: strip, near: place,
                                                   in: context(world)) == nil)
        }
    }

    @Test func aRefusalIsKnownDuringADragToo() {
        let world = simple([id(appA), id(appB)])
        let drop = EditorDrop.token(app(appA, in: world), from: .section(.shown))
        let own = context(world, cantReorder: [appA])

        #expect(LayoutEditorModel.refusal(for: drop, onto: .section(.shown), near: 2, in: own) == LayoutEditorCopy.cantPlaceThisIcon)
        #expect(LayoutEditorModel.landingPlace(for: drop, onto: .section(.shown), near: 2, in: own) == nil)
        // Another strip, or no refusal: nothing to say.
        #expect(LayoutEditorModel.refusal(for: drop, onto: .section(.hidden), near: 0, in: own) == nil)
        #expect(LayoutEditorModel.refusal(for: drop, onto: .section(.shown), near: 2, in: context(world)) == nil)
        #expect(LayoutEditorModel.refusal(for: drop, onto: .section(.shown), near: 2, in: context(world, canReorder: false))
            == LayoutCopy.needsGrantBanner)
    }

    // MARK: The round trip

    /// A shown list with a system item, a two-icon app, an app that isn't running, the marker and a spacer; an app no list has yet; a
    /// hidden list with a group, and a group with a member that isn't running. `marker` says where the marker is in the shown list.
    private func roundTripWorld(marker: Int? = 3, newItems: MenuBarSection = .shown) -> World {
        let wifi = ItemID.system("wifi"), battery = ItemID.system("battery")
        let a1 = id(appA, "one"), a2 = id(appA, "two")
        let listed = [wifi, a1, a2, id(quit), id(appB), id(appC), id(member1), id(member2), id(memberQuit), battery]
        var sections = SectionModel()
        sections.note(listed.map { Fixtures.item($0) })
        sections.move(app: appC, to: .hidden)
        sections.move(item: battery, to: .hidden)
        sections.addSpacer(LayoutSpacer(id: SpacerID(rawValue: "0000000a")), in: .shown, at: 5)
        let group = IconGroup(id: GroupID(rawValue: "0000000b"))
        sections.addGroup(group, in: .hidden, at: 0)
        sections.move(app: memberQuit, toGroup: group.id, at: 0)
        sections.move(app: member1, toGroup: group.id, at: 1)
        sections.move(app: member2, toGroup: group.id, at: 2)
        sections.setNewItemsMarker(section: newItems, index: marker)
        let inventory = Fixtures.inventory((listed + [id(unlisted)]).map { Fixtures.item($0) })
        let running = Set(inventory.items.map(\.ownerBundleID)).subtracting([quit, memberQuit])
        return World(sections: sections, inventory: inventory, running: running)
    }

    /// Whether any place in the list (or among the members) puts the thing where the strip showed it dropped: the oracle for a decline,
    /// which doesn't go through the model's own landing check.
    private func couldLand(_ drop: EditorDrop, onto target: Strip, expected: [String], movedID: String, world: World) -> Bool {
        var operations: [EditorOperation] = []
        switch target.id {
        case .section(let section):
            for index in 0...world.sections.items(in: section).count + 1 {
                switch drop {
                case .token(.app(_, let items), _): operations.append(.insert(items[0], section, index))
                case .token(.own(let item), _): operations.append(.insert(item, section, index))
                case .token(.marker, _), .palette(.marker): operations.append(.marker(section, index))
                case .palette(.spacer): operations.append(.addSpacer(section, index))
                case .palette(.group): operations.append(.addGroup(section, index))
                case .system: break
                }
            }
        case .group(let group):
            guard case .token(.app(let bundleID, _), _) = drop else { return false }
            for index in 0...(world.sections.groups[group]?.members.count ?? 0) + 1 { operations.append(.moveToGroup(bundleID: bundleID, group, index)) }
        }
        let known = Set(expected)
        return operations.contains { operation in
            var after = world.sections
            var made = movedID
            if let own = LayoutEditorModel.apply(operation, created: nil, to: &after) { made = own }
            var moved = world
            moved.sections = after
            let shown = ids(target.id, in: moved).filter(known.contains)
            return shown == expected.map { $0 == movedID ? made : $0 }
        }
    }

    @Test func everyDropLandsWhereTheStripShowsItAndIsSnappedOnlyWhereNothingLands() {
        let worlds = [roundTripWorld(), roundTripWorld(marker: 0), roundTripWorld(marker: nil),
                      roundTripWorld(marker: 0, newItems: .alwaysHidden), roundTripWorld(marker: 6)]
        var landed = 0, snapped = 0
        for world in worlds {
            let built = world.strips
            var things: [(drop: EditorDrop, source: StripID?)] = []
            for strip in built {
                for layout in strip.tokens { things.append((.token(layout.token, from: strip.id), strip.id)) }
            }
            for item in PaletteItem.allCases { things.append((.palette(item), nil)) }

            for thing in things {
                for target in built {
                    for place in 0...target.tokens.count {
                        let near = LayoutEditorModel.landingPlace(for: thing.drop, onto: target.id, near: place, in: context(world))
                        // A group holds apps only.
                        if case .group = target.id, !isApp(thing.drop) {
                            #expect(near == nil, "\(thing.drop) near \(place) on \(target.id)")
                            continue
                        }
                        guard let landing = near else {
                            Issue.record("\(thing.drop) dropped near \(place) on \(target.id) has no place to land")
                            continue
                        }
                        let proposed = operation(thing.drop, onto: target.id, at: landing, world)
                        var ids = target.tokens.map(\.token.id)
                        var at = landing
                        var movedID: String
                        switch thing.drop {
                        case .token(let token, let source):
                            movedID = token.id
                            if source == target.id, let position = ids.firstIndex(of: movedID) {
                                ids.remove(at: position)
                                if position < landing { at -= 1 }
                                if landing == position || landing == position + 1 {
                                    #expect(proposed == .noChange)
                                    continue
                                }
                            }
                        case .palette(let item):
                            movedID = item == .marker ? "marker" : "?"
                            if item == .marker, let position = ids.firstIndex(of: "marker") {
                                ids.remove(at: position)
                                if position < landing { at -= 1 }
                            }
                        case .system:
                            continue
                        }
                        if landing != place {
                            snapped += 1
                            // Where the pointer was, nothing lands: no place in the list shows the thing there.
                            var wanted = target.tokens.map(\.token.id)
                            var wantedAt = place
                            if let position = wanted.firstIndex(of: movedID), case .token(_, let source) = thing.drop, source == target.id {
                                wanted.remove(at: position)
                                if position < place { wantedAt -= 1 }
                            } else if movedID == "marker", let position = wanted.firstIndex(of: "marker") {
                                wanted.remove(at: position)
                                if position < place { wantedAt -= 1 }
                            }
                            wanted.insert(movedID, at: min(wantedAt, wanted.count))
                            #expect(!couldLand(thing.drop, onto: target, expected: wanted, movedID: movedID, world: world),
                                    "\(thing.drop) near \(place) on \(target.id) was moved to \(landing), where \(place) lands")
                        }
                        if case .refused(let text) = proposed {
                            Issue.record("\(thing.drop) dropped on \(target.id) at \(landing) was refused: \(text)")
                            continue
                        }
                        if case .noChange = proposed {
                            Issue.record("\(thing.drop) dropped on \(target.id) at \(landing) was declined")
                            continue
                        }
                        // Through the request, as the session makes it.
                        let request = LayoutEditorModel.request(for: thing.drop, onto: target.id, at: landing, in: context(world))
                        var after = world.sections
                        guard let resolved = LayoutEditorModel.resolve(request, sections: world.sections, inventory: world.inventory) else {
                            Issue.record("\(thing.drop) dropped on \(target.id) at \(landing): the request wasn't made")
                            continue
                        }
                        #expect(resolved == proposed, "the request is the same drop")
                        if let made = LayoutEditorModel.apply(resolved, created: request.created, to: &after) { movedID = made }
                        ids.insert(movedID, at: min(at, ids.count))
                        var moved = world
                        moved.sections = after
                        // A token that arrives with the drop (an app no list has follows the marker to its section) isn't the drop's.
                        let kept = self.ids(target.id, in: moved).filter(ids.contains)
                        #expect(kept == ids, "\(thing.drop) dropped on \(target.id) near \(place) at \(landing): \(proposed)")
                        landed += 1
                    }
                }
            }
        }
        #expect(landed > 400)
        #expect(snapped > 0)
    }

    private func isApp(_ drop: EditorDrop) -> Bool {
        if case .token(.app, _) = drop { true } else { false }
    }
}
