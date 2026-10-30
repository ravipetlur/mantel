import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Layout editor model", .timeLimit(.minutes(1)))
struct LayoutEditorModelTests {
    private let appA = "com.example.a"
    private let appB = "com.example.b"
    private let appC = "com.example.c"
    private let quitApp = "com.example.quit"

    private func id(_ bundleID: String, _ name: String = "main") -> ItemID {
        Fixtures.itemID(bundleID, name)
    }

    private func model(_ ids: [ItemID]) -> (sections: SectionModel, inventory: Inventory) {
        var sections = SectionModel()
        let items = ids.map { Fixtures.item($0) }
        sections.note(items)
        return (sections, Fixtures.inventory(items))
    }

    private func strips(_ sections: SectionModel, _ inventory: Inventory, running: Set<String>? = nil,
                        widths: ItemWidthCache = ItemWidthCache()) -> [Strip] {
        let running = running ?? Set(inventory.items.map(\.ownerBundleID))
        return LayoutEditorModel.strips(sections: sections, inventory: inventory, running: running, widths: widths)
    }

    private func strip(_ id: StripID, in strips: [Strip]) -> Strip? {
        strips.first { $0.id == id }
    }

    private func tokenIDs(_ strip: Strip?) -> [String] {
        strip?.tokens.map(\.token.id) ?? []
    }

    // MARK: Strips

    @Test func stripsInSectionOrder() {
        var (sections, inventory) = model([id(appA)])
        let group = IconGroup(id: GroupID(rawValue: "00000001"))
        let other = IconGroup(id: GroupID(rawValue: "00000002"))
        sections.addGroup(other, in: .shown, at: 0)
        sections.addGroup(group, in: .shown, at: 0)
        sections.groupOrder = [group.id, other.id]
        inventory = Fixtures.inventory(inventory.items)

        let built = strips(sections, inventory)

        #expect(built.map(\.id) == [.section(.shown), .section(.hidden), .section(.alwaysHidden), .group(group.id), .group(other.id)])
    }

    @Test func systemItemsNeverInStrips() {
        let system = ItemID.system("wifi")
        let (sections, inventory) = model([system, id(appA)])
        #expect(sections.items(in: .shown).contains(system))

        let all = strips(sections, inventory).flatMap(\.tokens).map(\.token)

        for token in all {
            switch token {
            case .app(_, let items): #expect(!items.contains { $0.isSystem })
            case .own, .marker: break
            }
        }
        #expect(all.contains { $0.bundleID == appA })
        #expect(!all.contains { $0.bundleID == ItemID.systemBundleID })
    }

    @Test func appWithSeveralIconsIsOneToken() {
        let one = id(appA, "one"), two = id(appA, "two"), other = id(appB)
        let (sections, inventory) = model([one, other, two])

        let shown = strip(.section(.shown), in: strips(sections, inventory))

        // The app's icons are listed together (the model keeps them next to each other), and make one token.
        let apps = shown?.tokens.compactMap { layout -> [ItemID]? in
            if case .app(let bundleID, let items) = layout.token, bundleID == appA { items } else { nil }
        }
        #expect(apps?.count == 1)
        #expect(Set(apps?.first ?? []) == [one, two])
        #expect(shown?.tokens.filter { $0.token.bundleID == appA }.count == 1)
    }

    @Test func tokenWidthIsClampedSlotWidth() {
        let one = id(appA, "one"), two = id(appA, "two"), narrow = id(appB), wide = id(appC)
        let (sections, inventory) = model([one, two, narrow, wide])
        var widths = ItemWidthCache()
        widths.update(from: Fixtures.inventory([
            Fixtures.item(one, frame: CGRect(x: 0, y: 0, width: 40, height: 24)),
            Fixtures.item(two, frame: CGRect(x: 0, y: 0, width: 50, height: 24)),
            Fixtures.item(narrow, frame: CGRect(x: 0, y: 0, width: 12, height: 24)),
            Fixtures.item(wide, frame: CGRect(x: 0, y: 0, width: 300, height: 24)),
        ]))

        let shown = strip(.section(.shown), in: strips(sections, inventory, widths: widths))
        func width(_ bundleID: String) -> CGFloat? { shown?.tokens.first { $0.token.bundleID == bundleID }?.width }

        #expect(width(appA) == 40 + LayoutEditorModel.tokenGap + 50)
        #expect(width(appB) == 30)
        #expect(width(appC) == 120)
    }

    @Test func aSlotThatWasNeverSeenIsTheLeastWidth() {
        let (sections, inventory) = model([id(appA)])
        let shown = strip(.section(.shown), in: strips(sections, inventory))
        #expect(shown?.tokens.first { $0.token.bundleID == appA }?.width == 30)
    }

    @Test func markerInNewItemsStrip() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        sections.setNewItemsMarker(section: .shown, index: 1)

        let built = strips(sections, inventory)

        #expect(tokenIDs(strip(.section(.shown), in: built)) == ["app:\(appA)", "marker", "app:\(appB)", "app:\(appC)"])
        #expect(!tokenIDs(strip(.section(.hidden), in: built)).contains("marker"))
        #expect(strip(.section(.shown), in: built)?.tokens[1].width == LayoutEditorModel.markerWidth)

        // Before the person puts it anywhere it is last; in another section it is that section's.
        sections.setNewItemsMarker(section: .shown, index: nil)
        #expect(tokenIDs(strip(.section(.shown), in: strips(sections, inventory))).last == "marker")
        sections.newItems = .hidden
        inventory = Fixtures.inventory(inventory.items)
        let moved = strips(sections, inventory)
        #expect(tokenIDs(strip(.section(.hidden), in: moved)) == ["marker"])
        #expect(!tokenIDs(strip(.section(.shown), in: moved)).contains("marker"))
    }

    @Test func spacersAndGroupIconsAreOwnTokens() {
        var (sections, inventory) = model([id(appA)])
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "0000000a"), width: 50)
        let group = IconGroup(id: GroupID(rawValue: "0000000b"))
        sections.addSpacer(spacer, in: .shown, at: 0)
        sections.addGroup(group, in: .shown, at: 2)
        inventory = Fixtures.inventory(inventory.items)

        let shown = strip(.section(.shown), in: strips(sections, inventory))

        #expect(shown?.tokens.map(\.token) == [.own(OwnItems.itemID(spacer.id)), .app(bundleID: appA, items: [id(appA)]),
                                               .own(OwnItems.itemID(group.id)), .marker])
        #expect(shown?.tokens.first?.width == 50)
    }

    @Test func aDotOrTheDividerInAListIsNoToken() {
        var (sections, inventory) = model([id(appA)])
        let dot = ItemID(bundleID: OwnItems.owner, key: .identifier(OwnItems.hiddenDotName))
        let divider = ItemID(bundleID: OwnItems.owner, key: .identifier(OwnItems.dividerName))
        sections.order[.shown] = [dot, id(appA), divider]
        inventory = Fixtures.inventory(inventory.items)

        let shown = strip(.section(.shown), in: strips(sections, inventory))

        #expect(tokenIDs(shown) == ["app:\(appA)", "marker"])
    }

    @Test func appsThatAreNotRunningHaveNoToken() {
        let (sections, inventory) = model([id(appA), id(appB)])
        let shown = strip(.section(.shown), in: strips(sections, inventory, running: [appA]))
        #expect(tokenIDs(shown).filter { $0.hasPrefix("app:") } == ["app:\(appA)"])
    }

    @Test func groupStripsInGroupOrder() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        let first = IconGroup(id: GroupID(rawValue: "00000001"))
        let second = IconGroup(id: GroupID(rawValue: "00000002"))
        sections.addGroup(first, in: .shown, at: 0)
        sections.addGroup(second, in: .shown, at: 0)
        sections.move(app: appB, toGroup: first.id, at: 0)
        sections.move(app: appA, toGroup: first.id, at: 0)
        sections.move(app: appC, toGroup: second.id, at: 0)
        inventory = Fixtures.inventory(inventory.items)

        let built = strips(sections, inventory)

        // Members in their order, and in no section's strip.
        #expect(tokenIDs(strip(.group(first.id), in: built)) == ["app:\(appA)", "app:\(appB)"])
        #expect(tokenIDs(strip(.group(second.id), in: built)) == ["app:\(appC)"])
        #expect(built.filter { if case .section = $0.id { true } else { false } }
            .allSatisfy { !tokenIDs($0).contains("app:\(appA)") })
        #expect(built.compactMap { if case .group(let group) = $0.id { group } else { nil } } == sections.groupOrder)
    }

    // MARK: Drops

    private func drop(_ drop: EditorDrop, onto strip: StripID, at index: Int, _ sections: SectionModel, inventory: Inventory = .empty,
                      canReorder: Bool = true, cantReorder: Set<String> = []) -> EditorOperation {
        LayoutEditorModel.operation(for: drop, onto: strip, at: index, sections: sections, canReorder: canReorder, cantReorder: cantReorder,
                                    inventory: inventory)
    }

    private func token(_ bundleID: String) -> StripToken {
        .app(bundleID: bundleID, items: [id(bundleID)])
    }

    @Test func withinStripReorderNeedsGrant() {
        let (sections, inventory) = model([id(appA), id(appB), id(appC)])

        let without = drop(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 3, sections, inventory: inventory,
                           canReorder: false)
        let with = drop(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 3, sections, inventory: inventory)

        #expect(without == .refused("Grant access to reorder, or ⌘-drag in the menu bar"))
        // Dropped after the third token (index 3, with the app's own token still in the strip): the list is B, C, A.
        #expect(with == .insert(id(appA), .shown, 2))
    }

    @Test func betweenStripsAlwaysAllowed() {
        var (sections, inventory) = model([id(appA), id(appB)])
        sections.move(app: appB, to: .hidden)
        inventory = Fixtures.inventory(inventory.items)

        let without = drop(.token(token(appA), from: .section(.shown)), onto: .section(.hidden), at: 0, sections, inventory: inventory,
                           canReorder: false)

        #expect(without == .insert(id(appA), .hidden, 0))
        // Into a group: the place among the members.
        var grouped = sections
        let group = IconGroup(id: GroupID(rawValue: "00000001"))
        grouped.addGroup(group, in: .shown, at: 0)
        grouped.move(app: appB, toGroup: group.id, at: 0)
        let inGroup = drop(.token(token(appA), from: .section(.shown)), onto: .group(group.id), at: 1, grouped,
                           inventory: Fixtures.inventory(inventory.items), canReorder: false)
        #expect(inGroup == .moveToGroup(bundleID: appA, group.id, 1))
    }

    @Test func paletteSpacerAddsAtIndex() {
        let (sections, inventory) = model([id(appA), id(appB)])

        // Among the tokens as they are drawn: A, B, marker. Between A and B is the place 1 in the list too.
        let between = drop(.palette(.spacer), onto: .section(.shown), at: 1, sections, inventory: inventory)
        let first = drop(.palette(.spacer), onto: .section(.shown), at: 0, sections, inventory: inventory)

        #expect(between == .addSpacer(.shown, 1))
        #expect(first == .addSpacer(.shown, 0))
        #expect(drop(.palette(.group), onto: .section(.hidden), at: 0, sections) == .addGroup(.hidden, 0))
    }

    @Test func paletteWithoutGrantLandsAtTheEnd() {
        let (sections, inventory) = model([id(appA), id(appB)])

        for item in PaletteItem.allCases {
            let operation = drop(.palette(item), onto: .section(.shown), at: 0, sections, inventory: inventory, canReorder: false)
            switch item {
            case .spacer: #expect(operation == .addSpacer(.shown, 2))
            case .group: #expect(operation == .addGroup(.shown, 2))
            // The marker needs no file: it lands where it is dropped, as the marker token does.
            case .marker: #expect(operation == .marker(.shown, 0))
            }
        }
    }

    @Test func paletteMarkerMoves() {
        let (sections, inventory) = model([id(appA), id(appB)])
        #expect(drop(.palette(.marker), onto: .section(.shown), at: 1, sections, inventory: inventory) == .marker(.shown, 1))
        #expect(drop(.palette(.marker), onto: .section(.hidden), at: 0, sections) == .marker(.hidden, 0))
    }

    @Test func theMarkerTokenMovesAsTheMarker() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        sections.setNewItemsMarker(section: .shown, index: 3)
        inventory = Fixtures.inventory(inventory.items)

        // Tokens: A B C marker. Dropped before B: the marker is before the second icon.
        let operation = drop(.token(.marker, from: .section(.shown)), onto: .section(.shown), at: 1, sections, inventory: inventory)
        #expect(operation == .marker(.shown, 1))
        // To another section: its list, at the place dropped.
        #expect(drop(.token(.marker, from: .section(.shown)), onto: .section(.hidden), at: 0, sections, inventory: inventory,
                     canReorder: false) == .marker(.hidden, 0))
    }

    @Test func ownItemsGoThroughInsert() {
        var (sections, inventory) = model([id(appA), id(appB)])
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "0000000a"))
        sections.addSpacer(spacer, in: .shown, at: 2)
        inventory = Fixtures.inventory(inventory.items)
        let own = OwnItems.itemID(spacer.id)

        let within = drop(.token(.own(own), from: .section(.shown)), onto: .section(.shown), at: 0, sections, inventory: inventory)
        let across = drop(.token(.own(own), from: .section(.shown)), onto: .section(.alwaysHidden), at: 0, sections, inventory: inventory,
                          canReorder: false)

        #expect(within == .insert(own, .shown, 0))
        #expect(across == .insert(own, .alwaysHidden, 0))
    }

    @Test func aGroupHoldsAppsOnlyAndAnythingElseIsDeclined() {
        var (sections, inventory) = model([id(appA), id(appB)])
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "0000000a"))
        let group = IconGroup(id: GroupID(rawValue: "00000001"))
        sections.addSpacer(spacer, in: .shown, at: 2)
        sections.addGroup(group, in: .shown, at: 0)
        inventory = Fixtures.inventory(inventory.items)
        let strip = StripID.group(group.id)
        let context = LayoutEditorModel.DropContext(sections: sections, canReorder: true, inventory: inventory)

        let nonApps: [EditorDrop] = [.token(.own(OwnItems.itemID(spacer.id)), from: .section(.shown)),
                                     .token(.own(OwnItems.itemID(group.id)), from: .section(.shown)),
                                     .token(.marker, from: .section(.shown)), .palette(.spacer), .palette(.group), .palette(.marker)]
        for drop in nonApps {
            // No refusal (nothing to say): the model answers no change, and the drag is declined.
            #expect(LayoutEditorModel.operation(for: drop, onto: strip, at: 0, in: context) == .noChange, "\(drop)")
            #expect(LayoutEditorModel.landingPlace(for: drop, onto: strip, near: 0, in: context) == nil, "\(drop)")
        }
        // An app is taken.
        let app = EditorDrop.token(token(appA), from: .section(.shown))
        #expect(LayoutEditorModel.landingPlace(for: app, onto: strip, near: 0, in: context) == 0)
        #expect(LayoutEditorModel.operation(for: app, onto: strip, at: 0, in: context) == .moveToGroup(bundleID: appA, group.id, 0))
    }

    @Test func systemDropIsRefused() {
        let (sections, _) = model([id(appA)])
        let refused = EditorOperation.refused("System icons keep macOS's order.")
        for strip in [StripID.section(.shown), .section(.alwaysHidden), .group(GroupID(rawValue: "00000001"))] {
            #expect(drop(.system(.system("wifi")), onto: strip, at: 0, sections) == refused)
            #expect(drop(.system(.system("wifi")), onto: strip, at: 0, sections, canReorder: false) == refused)
        }
    }

    @Test func dropOnOwnPositionIsNoChange() {
        let (sections, inventory) = model([id(appA), id(appB), id(appC)])

        // Before itself and after itself are the same place; the answer holds without the file too.
        for index in [1, 2] {
            #expect(drop(.token(token(appB), from: .section(.shown)), onto: .section(.shown), at: index, sections, inventory: inventory)
                == .noChange)
            #expect(drop(.token(token(appB), from: .section(.shown)), onto: .section(.shown), at: index, sections, inventory: inventory,
                         canReorder: false) == .noChange)
        }
        #expect(drop(.token(token(appB), from: .section(.shown)), onto: .section(.shown), at: 0, sections, inventory: inventory)
            == .insert(id(appB), .shown, 0))
    }

    @Test func anAppsIconsMoveTogetherInOneInsert() {
        let one = id(appA, "one"), two = id(appA, "two")
        let (sections, inventory) = model([one, two, id(appB)])
        let both = StripToken.app(bundleID: appA, items: [one, two])

        let operation = drop(.token(both, from: .section(.shown)), onto: .section(.hidden), at: 0, sections, inventory: inventory)

        // The model takes the whole app with the first icon.
        #expect(operation == .insert(one, .hidden, 0))
    }

    // MARK: The marker, and what a strip declines

    private func context(_ sections: SectionModel, _ inventory: Inventory, canReorder: Bool = true, cantReorder: Set<String> = [],
                         running: Set<String>? = nil) -> LayoutEditorModel.DropContext {
        .init(sections: sections, canReorder: canReorder, cantReorder: cantReorder, inventory: inventory, running: running)
    }

    @Test func theMarkerMovesWithinItsStripWithoutTheFile() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        sections.setNewItemsMarker(section: .shown, index: 3)
        inventory = Fixtures.inventory(inventory.items)

        // The marker moves no icon, only where new icons go: nothing to grant.
        let marker = drop(.token(.marker, from: .section(.shown)), onto: .section(.shown), at: 1, sections, inventory: inventory,
                          canReorder: false)
        #expect(marker == .marker(.shown, 1))
        // Anything that is an icon still is refused.
        #expect(drop(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 3, sections, inventory: inventory,
                     canReorder: false) == .refused("Grant access to reorder, or ⌘-drag in the menu bar"))
        // A palette spacer still lands at the end of the section without the file; the palette's marker lands where it is dropped.
        #expect(drop(.palette(.spacer), onto: .section(.shown), at: 0, sections, inventory: inventory, canReorder: false)
            == .addSpacer(.shown, 3))
        #expect(drop(.palette(.marker), onto: .section(.shown), at: 0, sections, inventory: inventory, canReorder: false)
            == .marker(.shown, 0))
    }

    @Test func aDragTheModelWouldRefuseIsNotAllowed() {
        let (sections, inventory) = model([id(appA), id(appB), .system("wifi")])
        let within = EditorDrop.token(token(appA), from: .section(.shown))

        func lands(_ drop: EditorDrop, onto strip: StripID, near place: Int, _ context: LayoutEditorModel.DropContext) -> Bool {
            LayoutEditorModel.landingPlace(for: drop, onto: strip, near: place, in: context) != nil
        }
        // A system icon, a reorder without the file, and an app that can't be reordered, within its strip.
        #expect(!lands(.system(.system("wifi")), onto: .section(.hidden), near: 0, context(sections, inventory)))
        #expect(!lands(within, onto: .section(.shown), near: 2, context(sections, inventory, canReorder: false)))
        #expect(!lands(within, onto: .section(.shown), near: 2, context(sections, inventory, cantReorder: [appA])))
        // And what it takes: the reorder with the file, a move to another strip whatever the file or the app says, and the place it is on.
        #expect(lands(within, onto: .section(.shown), near: 2, context(sections, inventory)))
        #expect(lands(within, onto: .section(.hidden), near: 0, context(sections, inventory, canReorder: false, cantReorder: [appA])))
        #expect(lands(within, onto: .section(.shown), near: 0, context(sections, inventory, canReorder: false)))
    }

    @Test func aDropBesideTheMarkerIsDeclinedWhenTheListCantTellItsSidesApart() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        sections.move(app: appC, to: .hidden)
        sections.setNewItemsMarker(section: .shown, index: 1)
        inventory = Fixtures.inventory(inventory.items)
        let moved = EditorDrop.token(token(appC), from: .section(.hidden))
        // The strip is A, marker, B.
        #expect(tokenIDs(strip(.section(.shown), in: strips(sections, inventory))) == ["app:\(appA)", "marker", "app:\(appB)"])

        // Left of the marker is the place before B, where it lands left of the marker.
        #expect(drop(moved, onto: .section(.shown), at: 1, sections, inventory: inventory) == .insert(id(appC), .shown, 1))
        // Right of it would be the same place in the list: it would land on the other side, so it is declined.
        #expect(drop(moved, onto: .section(.shown), at: 2, sections, inventory: inventory) == .noChange)
        #expect(LayoutEditorModel.landingPlace(for: moved, onto: .section(.shown), near: 2, in: context(sections, inventory)) == 1)
        // Around the others there is no question.
        #expect(drop(moved, onto: .section(.shown), at: 0, sections, inventory: inventory) == .insert(id(appC), .shown, 0))
        #expect(drop(moved, onto: .section(.shown), at: 3, sections, inventory: inventory) == .insert(id(appC), .shown, 2))
    }

    @Test func aQuitAppBetweenTheMarkerAndTheNextIconGivesTheListRoomOnBothSides() {
        var (sections, inventory) = model([id(appA), id(quitApp), id(appB), id(appC)])
        sections.move(app: appC, to: .hidden)
        sections.setNewItemsMarker(section: .shown, index: 1)
        inventory = Fixtures.inventory(inventory.items)
        let running = Set([appA, appB, appC])
        let moved = EditorDrop.token(token(appC), from: .section(.hidden))

        // The list is A, quit, B and the marker is before quit: left of it at 1, right of it after quit.
        let left = LayoutEditorModel.operation(for: moved, onto: .section(.shown), at: 1, in: context(sections, inventory, running: running))
        let right = LayoutEditorModel.operation(for: moved, onto: .section(.shown), at: 2, in: context(sections, inventory, running: running))
        #expect(left == .insert(id(appC), .shown, 1))
        #expect(right == .insert(id(appC), .shown, 2))
    }

    @Test func aDropAfterAnAppNoListHoldsYetIsDeclined() {
        var (sections, inventory) = model([id(appA), id(appB)])
        // An app the model placed but hasn't listed an icon of: its token follows the listed ones.
        sections.apps[appC] = AppPlacement(section: .shown, isAuto: false)
        sections.newItems = .hidden
        inventory = Fixtures.inventory(inventory.items + [Fixtures.item(id(appC))])
        let moved = EditorDrop.token(token(appA), from: .section(.shown))
        let built = strips(sections, inventory)
        #expect(tokenIDs(strip(.section(.shown), in: built)) == ["app:\(appA)", "app:\(appB)", "app:\(appC)"])

        // Dropped after it, A would be listed before it and drawn before it.
        #expect(drop(moved, onto: .section(.shown), at: 3, sections, inventory: inventory) == .noChange)
        #expect(LayoutEditorModel.landingPlace(for: moved, onto: .section(.shown), near: 3, in: context(sections, inventory)) == 2)
        // Before it, it is the end of the list.
        #expect(drop(moved, onto: .section(.shown), at: 2, sections, inventory: inventory) == .insert(id(appA), .shown, 1))
    }

    @Test func aMenuPutsAnIconAtTheEndOfAStripBeforeAMarkerThatIsLast() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        sections.move(app: appC, to: .hidden)
        inventory = Fixtures.inventory(inventory.items)
        let moved = EditorDrop.token(token(appC), from: .section(.hidden))
        // The strip is A, B, marker: "at the end" can't be after the marker.
        #expect(tokenIDs(strip(.section(.shown), in: strips(sections, inventory))) == ["app:\(appA)", "app:\(appB)", "marker"])
        let ordinaryEnd = LayoutEditorModel.endPlace(for: moved, onto: .section(.shown), in: context(sections, inventory))
        #expect(ordinaryEnd == 2)
        #expect(drop(moved, onto: .section(.shown), at: ordinaryEnd, sections, inventory: inventory) == .insert(id(appC), .shown, 2))
        #expect(LayoutEditorModel.endPlace(for: .palette(.spacer), onto: .section(.shown), in: context(sections, inventory)) == 2)
        // A strip without the marker: after its last token. An empty one: 0.
        let shownToHidden = EditorDrop.token(token(appA), from: .section(.shown))
        #expect(LayoutEditorModel.endPlace(for: shownToHidden, onto: .section(.hidden), in: context(sections, inventory)) == 1)
        #expect(LayoutEditorModel.endPlace(for: shownToHidden, onto: .section(.alwaysHidden), in: context(sections, inventory)) == 0)
    }

    // MARK: Move Left and Move Right

    @Test func moveLeftAndRightDropTheTokenAtTheNeighbouringPlace() {
        var (sections, inventory) = model([id(appA), id(appB), id(appC)])
        sections.setNewItemsMarker(section: .shown, index: 3)
        inventory = Fixtures.inventory(inventory.items)
        let shown = strip(.section(.shown), in: strips(sections, inventory))!
        let b = token(appB)

        let left = LayoutEditorModel.neighbourPlace(of: b, toward: .left, in: shown, context: context(sections, inventory))
        let right = LayoutEditorModel.neighbourPlace(of: b, toward: .right, in: shown, context: context(sections, inventory))

        #expect(left == 0)
        #expect(right == 3)
        #expect(drop(.token(b, from: .section(.shown)), onto: .section(.shown), at: left!, sections, inventory: inventory)
            == .insert(id(appB), .shown, 0))
        #expect(drop(.token(b, from: .section(.shown)), onto: .section(.shown), at: right!, sections, inventory: inventory)
            == .insert(id(appB), .shown, 2))
        // The ends have nowhere to go on that side.
        #expect(LayoutEditorModel.neighbourPlace(of: token(appA), toward: .left, in: shown, context: context(sections, inventory)) == nil)
        #expect(LayoutEditorModel.neighbourPlace(of: .marker, toward: .right, in: shown, context: context(sections, inventory)) == nil)
        #expect(LayoutEditorModel.neighbourPlace(of: token("com.example.gone"), toward: .left, in: shown, context: context(sections, inventory)) == nil)
        #expect(LayoutCopy.moveLeft == "Move Left" && LayoutCopy.moveRight == "Move Right")
    }

    @Test func moveLeftAndRightAreRefusedExactlyAsADragIs() {
        let (sections, inventory) = model([id(appA), id(appB), id(appC)])
        let shown = strip(.section(.shown), in: strips(sections, inventory))!
        let b = EditorDrop.token(token(appB), from: .section(.shown))
        let place = LayoutEditorModel.neighbourPlace(of: token(appB), toward: .right, in: shown, context: context(sections, inventory))!

        // Without the file, and for an app that can't be reordered: the refusals of the drag.
        #expect(drop(b, onto: .section(.shown), at: place, sections, inventory: inventory, canReorder: false)
            == .refused("Grant access to reorder, or ⌘-drag in the menu bar"))
        #expect(drop(b, onto: .section(.shown), at: place, sections, inventory: inventory, cantReorder: [appB])
            == .refused("macOS gives Mantel no way to place this icon. ⌘-drag it in the menu bar."))
    }

    // MARK: Apps that can't be reordered

    @Test func cantReorderAppWithinStripIsRefused() {
        let (sections, inventory) = model([id(appA), id(appB)])

        let operation = drop(.token(token(appA), from: .section(.shown)), onto: .section(.shown), at: 2, sections, inventory: inventory,
                             cantReorder: [appA])

        #expect(operation == .refused("macOS gives Mantel no way to place this icon. ⌘-drag it in the menu bar."))
        // Another app of the strip is placed as usual.
        #expect(drop(.token(token(appB), from: .section(.shown)), onto: .section(.shown), at: 0, sections, inventory: inventory,
                     cantReorder: [appA]) == .insert(id(appB), .shown, 0))
    }

    @Test func cantReorderAppBetweenStripsIsAllowed() {
        let (sections, inventory) = model([id(appA), id(appB)])

        let operation = drop(.token(token(appA), from: .section(.shown)), onto: .section(.hidden), at: 0, sections, inventory: inventory,
                             canReorder: false, cantReorder: [appA])

        #expect(operation == .insert(id(appA), .hidden, 0))
    }

    // MARK: Geometry and words

    @Test func insertionIndexFollowsTheTokenMidpoints() {
        let tokens = [StripTokenLayout(token: token(appA), width: 30), StripTokenLayout(token: token(appB), width: 40),
                      StripTokenLayout(token: .marker, width: 12)]
        // Tokens start at 8, 42 and 86 (8 of room, 4 between): their middles are 23, 62 and 92.
        #expect(LayoutEditorModel.insertionIndex(atX: 0, in: tokens) == 0)
        #expect(LayoutEditorModel.insertionIndex(atX: 22, in: tokens) == 0)
        #expect(LayoutEditorModel.insertionIndex(atX: 24, in: tokens) == 1)
        #expect(LayoutEditorModel.insertionIndex(atX: 61, in: tokens) == 1)
        #expect(LayoutEditorModel.insertionIndex(atX: 63, in: tokens) == 2)
        #expect(LayoutEditorModel.insertionIndex(atX: 91, in: tokens) == 2)
        #expect(LayoutEditorModel.insertionIndex(atX: 500, in: tokens) == 3)
        #expect(LayoutEditorModel.insertionIndex(atX: 10, in: []) == 0)
    }

    @Test func theInsertionLineIsInTheGapBeforeTheToken() {
        let tokens = [StripTokenLayout(token: token(appA), width: 30), StripTokenLayout(token: token(appB), width: 40)]
        #expect(LayoutEditorModel.insertionOffset(forIndex: 0, in: tokens) == 4)
        #expect(LayoutEditorModel.insertionOffset(forIndex: 1, in: tokens) == 40)
        #expect(LayoutEditorModel.insertionOffset(forIndex: 2, in: tokens) == 84)
        #expect(LayoutEditorModel.insertionOffset(forIndex: 9, in: tokens) == 84)
    }

    @Test func aPictureIsOnlyScaledDownToFit() {
        let room = CGSize(width: 30, height: 24)
        #expect(LayoutEditorModel.fittedSize(CGSize(width: 18, height: 18), in: room) == CGSize(width: 18, height: 18))
        #expect(LayoutEditorModel.fittedSize(CGSize(width: 60, height: 12), in: room) == CGSize(width: 30, height: 6))
        #expect(LayoutEditorModel.fittedSize(CGSize(width: 20, height: 48), in: room) == CGSize(width: 10, height: 24))
        #expect(LayoutEditorModel.fittedSize(.zero, in: room) == .zero)
    }

    @Test func tokensAreNamedAndCantReorderIsSaid() {
        var (sections, _) = model([id(appA)])
        let group = IconGroup(id: GroupID(rawValue: "00000001"), title: "Work")
        let plain = IconGroup(id: GroupID(rawValue: "00000002"))
        let other = IconGroup(id: GroupID(rawValue: "00000003"))
        sections.addGroup(group, in: .shown, at: 0)
        sections.addGroup(plain, in: .shown, at: 0)
        sections.addGroup(other, in: .shown, at: 0)
        let names = [appA: "Alpha"]

        #expect(LayoutEditorModel.title(of: token(appA), names: names, sections: sections) == "Alpha")
        #expect(LayoutEditorModel.title(of: token(appB), names: names, sections: sections) == appB)
        #expect(LayoutEditorModel.title(of: .marker, names: names, sections: sections) == "New icons go here")
        #expect(LayoutEditorModel.title(of: .own(OwnItems.itemID(group.id)), names: names, sections: sections) == "Work")
        // Groups without a title are told apart by their place.
        #expect(LayoutEditorModel.groupTitle(plain.id, in: sections) == "Group 1")
        #expect(LayoutEditorModel.groupTitle(other.id, in: sections) == "Group 2")
        sections.removeOwnItem(OwnItems.itemID(other.id))
        #expect(LayoutEditorModel.groupTitle(plain.id, in: sections) == "Group")

        #expect(LayoutEditorModel.tooltip(of: token(appA), names: names, sections: sections, cantReorder: []) == "Alpha")
        #expect(LayoutEditorModel.tooltip(of: token(appA), names: names, sections: sections, cantReorder: [appA])
            == "Alpha\nCan't reorder: ⌘-drag it in the menu bar.")
        #expect(LayoutEditorModel.accessibilityLabel(of: token(appA), names: names, sections: sections, cantReorder: [appA])
            == "Alpha, can't reorder")
        #expect(LayoutEditorModel.accessibilityLabel(of: token(appA), names: names, sections: sections, cantReorder: []) == "Alpha")
    }

    @Test func aDropIsKnownWhileItsTokenIsInTheStripItCameFrom() {
        let (sections, inventory) = model([id(appA), id(appB)])
        let built = strips(sections, inventory)
        let moved = token(appB)

        #expect(LayoutEditorModel.current(.token(moved, from: .section(.shown)), in: built) == .token(moved, from: .section(.shown)))
        #expect(LayoutEditorModel.current(.token(.marker, from: .section(.shown)), in: built) == .token(.marker, from: .section(.shown)))
        // A token that no strip holds there any more: no drop.
        #expect(LayoutEditorModel.current(.token(token(appC), from: .section(.shown)), in: built) == nil)
        #expect(LayoutEditorModel.current(.token(moved, from: .section(.hidden)), in: built) == nil)
        // A palette item and a system icon are always what they are.
        #expect(LayoutEditorModel.current(.palette(.marker), in: built) == .palette(.marker))
        #expect(LayoutEditorModel.current(.system(.system("wifi")), in: built) == .system(.system("wifi")))
    }
}
