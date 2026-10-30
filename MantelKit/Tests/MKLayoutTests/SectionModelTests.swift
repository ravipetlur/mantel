import Foundation
import MKCore
import Testing

@testable import MKLayout

@Suite("Section model", .timeLimit(.minutes(1)))
struct SectionModelTests {
    private let appA = "com.example.a"
    private let appB = "com.example.b"

    private func noted(_ ids: [ItemID]) -> SectionModel {
        var model = SectionModel()
        model.note(ids.map { Fixtures.item($0) })
        return model
    }

    @Test func sectionTitlesAreTheWordsSettingsUses() {
        #expect(MenuBarSection.allCases == [.shown, .hidden, .alwaysHidden])
        #expect(MenuBarSection.allCases.map(\.title) == ["Shown", "Hidden", "Always Hidden"])
    }

    @Test func appsMoveAsOne() {
        let one = Fixtures.itemID(appA, "one")
        let two = Fixtures.itemID(appA, "two")
        let other = Fixtures.itemID(appB)
        var model = noted([one, two, other])
        #expect(model.order[.shown] == [one, two, other])

        // Moving one icon of the app moves both, and the app's other icon follows in the order lists.
        model.move(item: one, to: .hidden)
        #expect(model.section(ofApp: appA) == .hidden)
        #expect(model.section(of: one) == .hidden)
        #expect(model.section(of: two) == .hidden)
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: false))
        #expect(model.order[.hidden] == [one, two])
        #expect(model.order[.shown] == [other])
        // Another app is where it was.
        #expect(model.section(ofApp: appB) == .shown)

        // And back, by the other icon.
        model.move(item: two, to: .shown)
        #expect(model.section(of: one) == .shown)
        #expect(model.order[.hidden] == nil)
        #expect(Set(model.order[.shown] ?? []) == [one, two, other])
    }

    @Test func newAppGetsNewItemsSection() {
        var model = SectionModel()
        #expect(model.newItems == .shown)
        #expect(model.section(ofApp: "com.example.new") == .shown)
        #expect(model.section(of: Fixtures.itemID("com.example.new")) == .shown)

        model.newItems = .hidden
        #expect(model.section(ofApp: "com.example.new") == .hidden)
        #expect(model.section(of: ItemID(bundleID: "com.example.new", key: .index(2))) == .hidden)

        // A system item that was never moved is Shown, whatever new apps get.
        #expect(model.section(of: .system("wifi")) == .shown)

        // An app that has a place keeps it.
        model.move(app: appA, to: .alwaysHidden)
        #expect(model.section(ofApp: appA) == .alwaysHidden)
    }

    @Test func assignNewSkipsPlacedApps() {
        var model = SectionModel()
        model.move(app: appA, to: .hidden)
        model.newItems = .alwaysHidden

        let placed = model.assignNew(apps: [appA, appB, "com.example.c", appB])
        #expect(placed == [appB, "com.example.c"])
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: false))
        #expect(model.apps[appB] == AppPlacement(section: .alwaysHidden, isAuto: false))
        #expect(model.apps["com.example.c"] == AppPlacement(section: .alwaysHidden, isAuto: false))

        // Nothing left to place, and an app with no items was never offered.
        #expect(model.assignNew(apps: [appA, appB]) == [])
        #expect(model.apps.count == 3)
    }

    @Test func personMoveClearsAuto() {
        var model = SectionModel()
        model.apps[appA] = AppPlacement(section: .hidden, isAuto: true)
        model.apps[appB] = AppPlacement(section: .hidden, isAuto: true)

        // Even a move to the section the app is in is the person's say.
        model.move(app: appA, to: .hidden)
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: false))
        model.move(item: Fixtures.itemID(appB), to: .shown)
        #expect(model.apps[appB] == AppPlacement(section: .shown, isAuto: false))
    }

    @Test func forgetRemovesPlacement() {
        let one = Fixtures.itemID(appA, "one")
        let two = Fixtures.itemID(appA, "two")
        let other = Fixtures.itemID(appB)
        var model = noted([one, two, other])
        model.move(app: appA, to: .hidden)
        model.move(app: appB, to: .alwaysHidden)
        model.newItems = .alwaysHidden

        model.forget(app: appA)
        #expect(model.apps[appA] == nil)
        // It is where new apps go again, and its icons are gone from the order lists.
        #expect(model.section(ofApp: appA) == .alwaysHidden)
        #expect(model.order[.hidden] == nil)
        #expect(model.order[.alwaysHidden] == [other])
        // The other app is untouched, and forgetting an app that isn't known does nothing.
        #expect(model.apps[appB] == AppPlacement(section: .alwaysHidden, isAuto: false))
        let before = model
        model.forget(app: "com.example.unknown")
        #expect(model == before)
    }

    @Test func orderFollowsMoves() {
        let a1 = Fixtures.itemID(appA, "one")
        let a2 = Fixtures.itemID(appA, "two")
        let b1 = Fixtures.itemID(appB)
        let wifi = ItemID.system("wifi")
        var model = SectionModel()

        // Icons are listed in the order they are noted, each under its own section, an app's icons together (a system item goes to the
        // end); noting one again changes nothing.
        model.note([Fixtures.item(a1), Fixtures.item(b1), Fixtures.item(wifi), Fixtures.item(a2)])
        #expect(model.order == [.shown: [a1, a2, b1, wifi]])
        model.note([Fixtures.item(b1), Fixtures.item(a1)])
        #expect(model.order == [.shown: [a1, a2, b1, wifi]])

        // An app's icons follow it, together and in their order, to the end of the other list.
        model.move(app: appB, to: .hidden)
        model.move(app: appA, to: .hidden)
        #expect(model.order == [.shown: [wifi], .hidden: [b1, a1, a2]])

        // A system item moves by itself.
        model.move(item: wifi, to: .alwaysHidden)
        #expect(model.systemItems == ["wifi": .alwaysHidden])
        #expect(model.section(of: wifi) == .alwaysHidden)
        #expect(model.order == [.hidden: [b1, a1, a2], .alwaysHidden: [wifi]])

        // Moving an app to the section it is in leaves the lists alone.
        let before = model
        model.move(app: appA, to: .hidden)
        #expect(model.order == before.order)

        // An icon the lists don't know yet joins its section when it is moved, and a new icon of a moved app joins that app.
        let a3 = Fixtures.itemID(appA, "three")
        model.note([Fixtures.item(a3)])
        #expect(model.order[.hidden] == [b1, a1, a2, a3])
        let c1 = Fixtures.itemID("com.example.c")
        model.move(item: c1, to: .alwaysHidden)
        #expect(model.order[.alwaysHidden] == [wifi, c1])

        // An icon listed under a section that isn't its own is filed under the one that is.
        model.apps[appB] = AppPlacement(section: .shown, isAuto: false)
        model.note([Fixtures.item(b1)])
        #expect(model.order[.shown] == [b1])
        #expect(model.order[.hidden] == [a1, a2, a3])
    }

    @Test func mantelsOwnItemsAreNotListed() {
        var model = SectionModel()
        model.note([Fixtures.item(Fixtures.itemID("com.example.mantel", "dot"), isMantel: true), Fixtures.item(Fixtures.itemID(appA))])
        #expect(model.order == [.shown: [Fixtures.itemID(appA)]])
    }

    @Test func codableRoundTrip() throws {
        let a1 = Fixtures.itemID(appA, "one")
        let b1 = ItemID(bundleID: appB, key: .index(1))
        var model = noted([a1, b1, .system("battery")])
        model.move(app: appA, to: .hidden)
        model.move(item: .system("battery"), to: .alwaysHidden)
        model.apps[appB] = AppPlacement(section: .hidden, isAuto: true)
        model.newItems = .hidden

        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(SectionModel.self, from: data) == model)

        // The order is an object keyed by the section's name, and a placement says whether it is automatic.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let order = try #require(object["order"] as? [String: [String]])
        #expect(order == ["shown": [b1.string], "hidden": [a1.string], "alwaysHidden": ["system:battery"]])
        #expect(b1.string == "com.example.b#1")
        let apps = try #require(object["apps"] as? [String: [String: Any]])
        #expect(apps[appB]?["isAuto"] as? Bool == true)
        #expect(apps[appB]?["section"] as? String == "hidden")
        #expect(object["newItems"] as? String == "hidden")
        #expect((object["systemItems"] as? [String: String]) == ["battery": "alwaysHidden"])

        // Keys missing from a file take their defaults; keys this version doesn't know are ignored.
        #expect(try JSONDecoder().decode(SectionModel.self, from: Data("{}".utf8)) == SectionModel())
        let partial = try JSONDecoder().decode(SectionModel.self, from: Data(#"{"newItems":"alwaysHidden","extra":1}"#.utf8))
        #expect(partial.newItems == .alwaysHidden)
    }

    @Test func sectionKeysStillDecodeFromTheStoredJSON() throws {
        // The names in a file are the raw values, which the types' names don't change.
        #expect(MenuBarSection.allCases.map(\.rawValue) == ["shown", "hidden", "alwaysHidden"])
        let json = #"{"apps":{"com.example.a":{"section":"alwaysHidden","isAuto":true}},"systemItems":{"wifi":"hidden"},"#
            + #""order":{"hidden":["com.example.a::one"],"alwaysHidden":["system:wifi"]},"newItems":"hidden"}"#
        let model = try JSONDecoder().decode(SectionModel.self, from: Data(json.utf8))
        #expect(model.apps[appA] == AppPlacement(section: .alwaysHidden, isAuto: true))
        #expect(model.systemItems == ["wifi": .hidden])
        #expect(model.order == [.hidden: [Fixtures.itemID(appA, "one")], .alwaysHidden: [.system("wifi")]])
        #expect(model.newItems == .hidden)

        // A dictionary keyed by the section is an object, both ways.
        let plain = try JSONDecoder().decode([MenuBarSection: [ItemID]].self, from: Data(#"{"shown":[],"hidden":["com.example.b#1"]}"#.utf8))
        #expect(plain == [.shown: [], .hidden: [ItemID(bundleID: appB, key: .index(1))]])
        let written = try JSONEncoder().encode([MenuBarSection.alwaysHidden: ["x"]])
        #expect(String(decoding: written, as: UTF8.self) == #"{"alwaysHidden":["x"]}"#)

        // The reveal level that says nothing is revealed is still `none` in a file.
        #expect(RevealLevel.off.rawValue == "none")
        #expect(try JSONDecoder().decode([RevealLevel].self, from: Data(#"["none","hidden","all"]"#.utf8)) == [.off, .hidden, .all])
        #expect(String(decoding: try JSONEncoder().encode([RevealLevel.off]), as: UTF8.self) == #"["none"]"#)
    }

    // MARK: Dropping icons: insert

    private let appC = "com.example.c"
    private let appD = "com.example.d"

    private func ids(_ bundleID: String, _ names: String...) -> [ItemID] {
        names.map { Fixtures.itemID(bundleID, $0) }
    }

    private func spacer(_ raw: String, width: Int = LayoutSpacer.defaultWidth) -> LayoutSpacer {
        LayoutSpacer(id: SpacerID(rawValue: raw), width: width)
    }

    private func group(_ raw: String, members: [String] = []) -> IconGroup {
        IconGroup(id: GroupID(rawValue: raw), title: "Chat", members: members)
    }

    @Test func insertMovesWholeAppAdjacent() {
        let a = ids(appA, "one", "two", "three")
        let b = ids(appB, "main")
        let c = ids(appC, "main")
        let h = ids(appD, "main")
        // The app's icons are listed apart (a file written by an earlier version has them so).
        var model = SectionModel()
        model.order = [.shown: [a[0], b[0], a[1], c[0], a[2], h[0]]]
        model.move(app: appD, to: .hidden)
        model.apps[appA] = AppPlacement(section: .shown, isAuto: true)
        #expect(model.order[.shown] == [a[0], b[0], a[1], c[0], a[2]])
        #expect(model.order[.hidden] == [h[0]])

        // Dropping one of the three takes all three, together and in their order, to the place.
        model.insert(a[1], in: .hidden, at: 0)
        #expect(model.order[.hidden] == [a[0], a[1], a[2], h[0]])
        #expect(model.order[.shown] == [b[0], c[0]])
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: false), "the person's move: not automatic, in no group")
        #expect(model.section(of: a[2]) == .hidden)

        // Between the icons of other apps, and the three are still together.
        model.insert(b[0], in: .hidden, at: 3)
        #expect(model.order[.hidden] == [a[0], a[1], a[2], b[0], h[0]])
        model.insert(a[2], in: .hidden, at: 1)
        #expect(model.order[.hidden] == [b[0], a[0], a[1], a[2], h[0]])
        #expect(model.order[.shown] == [c[0]])

        // A system item is moved by itself, and an icon the lists don't know yet is listed with its app.
        model.insert(.system("wifi"), in: .shown, at: 0)
        #expect(model.systemItems == ["wifi": .shown])
        #expect(model.order[.shown] == [.system("wifi"), c[0]])
        let fresh = Fixtures.itemID(appC, "second")
        model.insert(fresh, in: .shown, at: 1)
        #expect(model.order[.shown] == [.system("wifi"), c[0], fresh], "the app's icons are together")
    }

    @Test func insertWithinSectionReorders() {
        let a = ids(appA, "one", "two")
        let b = ids(appB, "main")
        let c = ids(appC, "main")
        var model = noted([a[0], a[1], b[0], c[0]])
        #expect(model.order[.shown] == [a[0], a[1], b[0], c[0]])

        model.insert(c[0], in: .shown, at: 0)
        #expect(model.order == [.shown: [c[0], a[0], a[1], b[0]]])
        // The index is a place among the icons that are left once the moved ones are out: after b is the end.
        model.insert(a[1], in: .shown, at: 2)
        #expect(model.order == [.shown: [c[0], b[0], a[0], a[1]]])
        model.insert(a[0], in: .shown, at: 1)
        #expect(model.order == [.shown: [c[0], a[0], a[1], b[0]]])
        // The apps are where they were, and are the person's.
        #expect(model.section(ofApp: appA) == .shown)
        #expect(model.apps[appA] == AppPlacement(section: .shown, isAuto: false))
        // Nothing else was made.
        #expect(model.spacers.isEmpty && model.groups.isEmpty && model.groupItems.isEmpty)
    }

    @Test func insertClampsIndex() {
        let a = ids(appA, "main")
        let b = ids(appB, "main")
        let c = ids(appC, "main")
        var model = noted([a[0], b[0]])
        model.insert(c[0], in: .shown, at: 99)
        #expect(model.order[.shown] == [a[0], b[0], c[0]])
        model.insert(c[0], in: .shown, at: -4)
        #expect(model.order[.shown] == [c[0], a[0], b[0]])
        model.insert(a[0], in: .shown, at: Int.max)
        #expect(model.order[.shown] == [c[0], b[0], a[0]])
        // Into a section that has nothing, at any place.
        model.insert(b[0], in: .alwaysHidden, at: 7)
        #expect(model.order == [.shown: [c[0], a[0]], .alwaysHidden: [b[0]]])
        model.insert(c[0], in: .alwaysHidden, at: Int.min)
        #expect(model.order == [.shown: [a[0]], .alwaysHidden: [c[0], b[0]]])
        // A spacer is clamped the same way.
        model.addSpacer(spacer("00000001"), in: .shown, at: 50)
        #expect(model.order[.shown] == [a[0], OwnItems.itemID(SpacerID(rawValue: "00000001"))])
        model.insert(OwnItems.itemID(SpacerID(rawValue: "00000001")), in: .hidden, at: -1)
        #expect(model.order[.hidden] == [OwnItems.itemID(SpacerID(rawValue: "00000001"))])
    }

    // MARK: Spacers and groups in the lists

    @Test func ownItemSectionIsItsList() {
        var model = noted(ids(appA, "main"))
        let s = SpacerID(rawValue: "0000000a")
        let g = GroupID(rawValue: "0000000b")
        model.addSpacer(LayoutSpacer(id: s), in: .hidden, at: 0)
        model.addGroup(IconGroup(id: g), in: .alwaysHidden, at: 0)
        #expect(model.section(ofOwn: OwnItems.itemID(s)) == .hidden)
        #expect(model.section(ofOwn: OwnItems.itemID(g)) == .alwaysHidden)
        #expect(model.section(of: OwnItems.itemID(s)) == .hidden)
        #expect(model.items(in: .hidden) == [OwnItems.itemID(s)])
        #expect(model.items(in: .alwaysHidden) == [OwnItems.itemID(g)])
        #expect(model.items(in: .shown) == ids(appA, "main"))

        model.insert(OwnItems.itemID(s), in: .shown, at: 0)
        #expect(model.section(ofOwn: OwnItems.itemID(s)) == .shown)
        #expect(model.items(in: .shown) == [OwnItems.itemID(s)] + ids(appA, "main"))
        #expect(model.items(in: .hidden) == [])

        // Nothing else has a section of its own to ask: an app's icon, a spacer that was never added, a dot, a system item.
        #expect(model.section(ofOwn: Fixtures.itemID(appA)) == nil)
        #expect(model.section(ofOwn: OwnItems.itemID(SpacerID(rawValue: "0000000c"))) == nil)
        #expect(model.section(ofOwn: ItemID(bundleID: OwnItems.owner, key: .identifier(OwnItems.hiddenDotName))) == nil)
        #expect(model.section(ofOwn: .system("wifi")) == nil)
    }

    @Test func ownItemMovesOnlyThroughInsert() {
        var model = noted(ids(appA, "main"))
        let s = OwnItems.itemID(SpacerID(rawValue: "0000000a"))
        let g = OwnItems.itemID(GroupID(rawValue: "0000000b"))
        model.addSpacer(spacer("0000000a"), in: .hidden, at: 0)
        model.addGroup(group("0000000b"), in: .hidden, at: 1)
        let before = model

        // Moving it as an icon does nothing: it has no app, and would have made one (`mantel`) with a place of its own.
        model.move(item: s, to: .shown)
        model.move(item: g, to: .alwaysHidden)
        #expect(model == before)
        #expect(model.apps["mantel"] == nil)
        #expect(model.section(ofOwn: s) == .hidden)

        // Dropping it moves it alone, and never makes an app.
        model.insert(s, in: .shown, at: 0)
        model.insert(g, in: .alwaysHidden, at: 0)
        #expect(model.section(ofOwn: s) == .shown)
        #expect(model.section(ofOwn: g) == .alwaysHidden)
        #expect(model.order == [.shown: [s] + ids(appA, "main"), .alwaysHidden: [g]])
        #expect(model.apps["mantel"] == nil)
        #expect(model.apps.isEmpty)

        // The apps' icons next to it stay as they were, and one that the model doesn't have is not made.
        let unknown = OwnItems.itemID(SpacerID(rawValue: "0000000f"))
        let kept = model
        model.insert(unknown, in: .hidden, at: 0)
        model.insert(ItemID(bundleID: OwnItems.owner, key: .identifier(OwnItems.hiddenDotName)), in: .hidden, at: 0)
        #expect(model == kept)
    }

    @Test func addSpacerAtIndex() {
        let a = ids(appA, "main")
        let b = ids(appB, "main")
        var model = noted([a[0], b[0]])
        let first = spacer("00000001", width: 30)
        model.addSpacer(first, in: .shown, at: 1)
        #expect(model.order[.shown] == [a[0], OwnItems.itemID(first.id), b[0]])
        #expect(model.spacers == [first.id: first])

        let second = LayoutSpacer(id: SpacerID(rawValue: "00000002"), width: 8, label: .emoji("🙂"))
        model.addSpacer(second, in: .shown, at: 0)
        model.addSpacer(spacer("00000003"), in: .hidden, at: 5)
        #expect(model.order[.shown] == [OwnItems.itemID(second.id), a[0], OwnItems.itemID(first.id), b[0]])
        #expect(model.order[.hidden] == [OwnItems.itemID(SpacerID(rawValue: "00000003"))])
        #expect(model.spacers[second.id]?.label == .emoji("🙂"))
        // The apps' placements are untouched, and a spacer is no app.
        #expect(model.apps.isEmpty)

        // A width outside 4 to 200 is brought into it when it is added.
        var narrow = spacer("00000004")
        narrow.width = 0
        var wide = spacer("00000005")
        wide.width = 1000
        model.addSpacer(narrow, in: .shown, at: 0)
        model.addSpacer(wide, in: .shown, at: 0)
        #expect(model.spacers[SpacerID(rawValue: "00000004")]?.width == 4)
        #expect(model.spacers[SpacerID(rawValue: "00000005")]?.width == 200)

        // A spacer that is added again is moved, not listed twice.
        model.addSpacer(first, in: .hidden, at: 0)
        #expect(model.order[.hidden] == [OwnItems.itemID(first.id), OwnItems.itemID(SpacerID(rawValue: "00000003"))])
        #expect(model.order.values.flatMap { $0 }.filter { $0 == OwnItems.itemID(first.id) }.count == 1)
    }

    @Test func newSpacerIsTwelvePoints() {
        #expect(LayoutSpacer.defaultWidth == 12)
        let made = LayoutSpacer(id: .make())
        #expect(made.width == 12)
        #expect(made.label == nil)
        var model = SectionModel()
        model.addSpacer(made, in: .shown, at: 0)
        #expect(model.spacers[made.id]?.width == 12)
    }

    @Test func updateSpacerClampsWidth() {
        var model = SectionModel()
        model.addSpacer(spacer("00000001", width: 20), in: .shown, at: 0)
        let id = SpacerID(rawValue: "00000001")
        // A width that is set after the spacer is made is brought into range when the layout is given it.
        var changed = LayoutSpacer(id: id, width: 40, label: .text("Work"))
        changed.width = 500
        model.updateSpacer(changed)
        #expect(model.spacers[id] == LayoutSpacer(id: id, width: 200, label: .text("Work")))
        changed.width = 1
        changed.label = nil
        model.updateSpacer(changed)
        #expect(model.spacers[id] == LayoutSpacer(id: id, width: 4, label: nil))
        model.updateSpacer(LayoutSpacer(id: id, width: 77, label: .symbol("star")))
        #expect(model.spacers[id]?.width == 77)
        #expect(model.spacers[id]?.label == .symbol("star"))
        // Its place is where it was, and a spacer the model doesn't have is not made by an update.
        #expect(model.order == [.shown: [OwnItems.itemID(id)]])
        let before = model
        model.updateSpacer(LayoutSpacer(id: SpacerID(rawValue: "00000009"), width: 50))
        #expect(model == before)
    }

    @Test func removeSpacer() {
        let a = ids(appA, "main")
        var model = noted([a[0]])
        let id = SpacerID(rawValue: "00000001")
        model.addSpacer(LayoutSpacer(id: id), in: .shown, at: 0)
        model.addSpacer(spacer("00000002"), in: .hidden, at: 0)
        model.removeOwnItem(OwnItems.itemID(id))
        #expect(model.spacers[id] == nil)
        #expect(model.spacers.count == 1)
        #expect(model.order[.shown] == [a[0]])
        #expect(model.section(ofOwn: OwnItems.itemID(id)) == nil)
        // The only thing in a list: the list goes.
        model.removeOwnItem(OwnItems.itemID(SpacerID(rawValue: "00000002")))
        #expect(model.order == [.shown: [a[0]]])
        #expect(model.spacers.isEmpty)
        // One that isn't there, an app's icon and a dot are left alone.
        let before = model
        model.removeOwnItem(OwnItems.itemID(id))
        model.removeOwnItem(a[0])
        model.removeOwnItem(ItemID(bundleID: OwnItems.owner, key: .identifier(OwnItems.alwaysDotName)))
        #expect(model == before)
    }

    // MARK: Groups

    @Test func groupMoveSetsAlwaysHiddenAndMembers() {
        let a = ids(appA, "one", "two")
        let b = ids(appB, "main")
        let c = ids(appC, "main")
        let g = GroupID(rawValue: "00000001")
        var model = noted([a[0], a[1], b[0], c[0]])
        model.addGroup(group("00000001"), in: .shown, at: 0)
        let groupIcon = OwnItems.itemID(g)
        #expect(model.groupOrder == [g])
        #expect(model.order[.shown] == [groupIcon, a[0], a[1], b[0], c[0]])

        model.move(app: appA, toGroup: g, at: 0)
        #expect(model.apps[appA] == AppPlacement(section: .alwaysHidden, isAuto: false, group: g))
        #expect(model.groups[g]?.members == [appA])
        #expect(model.groupItems[g] == [a[0], a[1]])
        #expect(model.order[.shown] == [groupIcon, b[0], c[0]], "its icons left the section's list")
        #expect(model.order[.alwaysHidden] == nil, "and are not in Always Hidden's list")
        #expect(model.section(of: a[0]) == .alwaysHidden)

        // The next is put in at its index, and its icons after those of the members before it.
        model.move(app: appB, toGroup: g, at: 1)
        #expect(model.groups[g]?.members == [appA, appB])
        #expect(model.groupItems[g] == [a[0], a[1], b[0]])
        model.move(app: appC, toGroup: g, at: 0)
        #expect(model.groups[g]?.members == [appC, appA, appB])
        #expect(model.groupItems[g] == [c[0], a[0], a[1], b[0]])
        #expect(model.order == [.shown: [groupIcon]])

        // An app that is in the group moves within it: its icons go with it, and it isn't in the members twice.
        model.move(app: appA, toGroup: g, at: 2)
        #expect(model.groups[g]?.members == [appC, appB, appA])
        #expect(model.groupItems[g] == [c[0], b[0], a[0], a[1]])
        model.move(app: appA, toGroup: g, at: 99)
        #expect(model.groups[g]?.members == [appC, appB, appA])
        model.move(app: appB, toGroup: g, at: -3)
        #expect(model.groups[g]?.members == [appB, appC, appA])
        #expect(model.groupItems[g] == [b[0], c[0], a[0], a[1]])

        // Moving it to a section takes it out of the group: its icons go to the end of that section's list.
        model.move(app: appA, to: .hidden)
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: false))
        #expect(model.groups[g]?.members == [appB, appC])
        #expect(model.groupItems[g] == [b[0], c[0]])
        #expect(model.order[.hidden] == [a[0], a[1]])
        // So does dropping an icon of it (the app moves as one) at a place in a section.
        model.insert(c[0], in: .alwaysHidden, at: 0)
        #expect(model.apps[appC] == AppPlacement(section: .alwaysHidden, isAuto: false))
        #expect(model.groups[g]?.members == [appB])
        #expect(model.groupItems[g] == [b[0]])
        #expect(model.order[.alwaysHidden] == [c[0]])

        // A group the model doesn't have takes no one.
        let before = model
        model.move(app: appD, toGroup: GroupID(rawValue: "0000ffff"), at: 0)
        #expect(model == before)
    }

    @Test func groupMoveBetweenGroupsLeavesTheFirst() {
        let a = ids(appA, "main")
        let b = ids(appB, "main")
        let one = GroupID(rawValue: "00000001")
        let two = GroupID(rawValue: "00000002")
        var model = noted([a[0], b[0]])
        model.addGroup(IconGroup(id: one, members: [appA, appB]), in: .shown, at: 0)
        model.addGroup(IconGroup(id: two), in: .shown, at: 1)
        #expect(model.groups[one]?.members == [appA, appB])
        #expect(model.groupItems[one] == [a[0], b[0]])
        #expect(model.groupOrder == [one, two])

        model.move(app: appA, toGroup: two, at: 0)
        #expect(model.groups[one]?.members == [appB])
        #expect(model.groups[two]?.members == [appA])
        #expect(model.groupItems == [one: [b[0]], two: [a[0]]])
        #expect(model.apps[appA]?.group == two)
        #expect(model.apps[appB]?.group == one)

        // Changing a group's look and title leaves its members as the model has them, whatever the update says.
        model.updateGroup(IconGroup(id: one, title: "Renamed", look: .emoji("💬"), opensOnHover: true, members: ["com.example.nobody"]))
        #expect(model.groups[one] == IconGroup(id: one, title: "Renamed", look: .emoji("💬"), opensOnHover: true, members: [appB]))
        let before = model
        model.updateGroup(IconGroup(id: GroupID(rawValue: "0000ffff"), title: "Nobody"))
        #expect(model == before)
    }

    @Test func noteKeepsGroupedItemsInTheirGroup() {
        let a = ids(appA, "one", "two")
        let b = ids(appB, "one", "two")
        let c = ids(appC, "main")
        let g = GroupID(rawValue: "00000001")
        var model = SectionModel()
        model.addGroup(IconGroup(id: g, members: [appA, appB]), in: .shown, at: 0)
        model.note([Fixtures.item(a[0]), Fixtures.item(b[0]), Fixtures.item(c[0])])
        #expect(model.groupItems[g] == [a[0], b[0]])
        #expect(model.order[.alwaysHidden] == nil, "never in Always Hidden's list")
        #expect(model.order[.shown] == [OwnItems.itemID(g), c[0]])

        // A new icon of a member goes after the icons of the members before it, and the app's own.
        model.note([Fixtures.item(a[1]), Fixtures.item(b[1])])
        #expect(model.groupItems[g] == [a[0], a[1], b[0], b[1]])
        // Noting what is listed again changes nothing.
        let before = model
        model.note([Fixtures.item(b[1]), Fixtures.item(a[0]), Fixtures.item(c[0])])
        #expect(model == before)

        // An icon of a grouped app that an earlier file listed in Always Hidden's list goes to its group.
        var older = before
        older.order[.alwaysHidden] = [a[0]]
        older.groupItems[g] = [a[1], b[0], b[1]]
        older.note([Fixtures.item(a[0])])
        #expect(older.groupItems[g] == [a[1], a[0], b[0], b[1]], "after the app's icons that are there")
        #expect(older.order[.alwaysHidden] == nil)

        // A grouped app never lands at the marker, and the apps that are not grouped are listed as ever.
        var marked = before
        marked.setNewItemsMarker(section: .shown, index: 0)
        marked.note([Fixtures.item(Fixtures.itemID(appA, "three")), Fixtures.item(Fixtures.itemID(appD, "main"))])
        #expect(marked.groupItems[g]?.contains(Fixtures.itemID(appA, "three")) == true)
        #expect(marked.order[.shown]?.first == Fixtures.itemID(appD, "main"))
    }

    @Test func removingGroupReturnsMembersToAlwaysHidden() {
        let a = ids(appA, "one", "two")
        let b = ids(appB, "main")
        let hidden = ids(appD, "main")
        let g = GroupID(rawValue: "00000001")
        var model = noted([a[0], a[1], b[0], hidden[0]])
        model.move(app: appD, to: .alwaysHidden)
        model.addGroup(IconGroup(id: g, members: [appB, appA]), in: .hidden, at: 0)
        #expect(model.groupItems[g] == [b[0], a[0], a[1]])
        #expect(model.order[.alwaysHidden] == [hidden[0]])
        let neighbour = ids(appC, "main")
        model.note([Fixtures.item(neighbour[0])])

        model.removeOwnItem(OwnItems.itemID(g))
        #expect(model.groups[g] == nil)
        #expect(model.groupOrder.isEmpty)
        #expect(model.groupItems[g] == nil)
        #expect(model.groupItems.isEmpty)
        // The members stay in Always Hidden, in no group, and their icons are at the end of its list in the order of the members.
        #expect(model.apps[appA] == AppPlacement(section: .alwaysHidden, isAuto: false, group: nil))
        #expect(model.apps[appB] == AppPlacement(section: .alwaysHidden, isAuto: false, group: nil))
        #expect(model.order[.alwaysHidden] == [hidden[0], b[0], a[0], a[1]])
        #expect(model.section(of: a[0]) == .alwaysHidden)
        // The group's own icon is gone from the list that held it.
        #expect(model.section(ofOwn: OwnItems.itemID(g)) == nil)
        #expect(model.order[.hidden] == nil)
        #expect(model.order[.shown] == neighbour)

        // The apps are ordinary Always Hidden apps now: they can be moved like any.
        model.move(app: appB, to: .shown)
        #expect(model.order[.shown] == neighbour + b)
        #expect(model.order[.alwaysHidden] == [hidden[0], a[0], a[1]])
    }

    // MARK: Apps that are new, and the marker

    @Test func newAppsLandAtMarkerInArrivalOrder() {
        let a = ids(appA, "main")
        let b = ids(appB, "main")
        let c = ids(appC, "one", "two")
        let d = ids(appD, "main")

        // Before an icon: the apps that come after are put there one after another, in the order they come, and the marker moves past them.
        for assignFirst in [false, true] {
            var model = noted([a[0], b[0]])
            model.setNewItemsMarker(section: .shown, index: 1)
            let arriving = [Fixtures.item(c[0]), Fixtures.item(c[1]), Fixtures.item(d[0])]
            if assignFirst { model.assignNew(apps: [appC, appD]) }
            model.note(arriving)
            if !assignFirst { model.assignNew(apps: [appC, appD]) }
            #expect(model.order[.shown] == [a[0], c[0], c[1], d[0], b[0]], "assigned first: \(assignFirst)")
            #expect(model.newItemsIndex == 4, "still before the same icon")
            #expect(model.apps[appC]?.section == .shown)
            #expect(model.apps[appD]?.section == .shown)
        }

        // An app that comes later again is after those, and an icon an app gets later is at the end of its section.
        var model = noted([a[0], b[0]])
        model.setNewItemsMarker(section: .shown, index: 1)
        model.note([Fixtures.item(c[0])])
        model.note([Fixtures.item(d[0])])
        #expect(model.order[.shown] == [a[0], c[0], d[0], b[0]])
        model.note([Fixtures.item(c[1])])
        #expect(model.order[.shown] == [a[0], c[0], c[1], d[0], b[0]], "not a new app: right after its app's last icon")
        #expect(model.newItemsIndex == 4, "still before the same icon")
        // An app that has none in the section goes at the end of it.
        var elsewhere = model
        elsewhere.order[.hidden] = [Fixtures.itemID(appA, "other")]
        elsewhere.apps[appC] = AppPlacement(section: .hidden, isAuto: false)
        elsewhere.note([Fixtures.item(c[1])])
        #expect(elsewhere.order[.hidden] == [Fixtures.itemID(appA, "other"), c[1]])
        #expect(elsewhere.order[.shown] == [a[0], c[0], d[0], b[0]])

        // Apps whose icons arrive interleaved in one call are put together, each after its own last icon, at the marker or at the end.
        let d2 = ids(appD, "one", "two")
        var interleaved = noted([a[0], b[0]])
        interleaved.setNewItemsMarker(section: .shown, index: 1)
        interleaved.note([Fixtures.item(c[0]), Fixtures.item(d2[0]), Fixtures.item(c[1]), Fixtures.item(d2[1])])
        #expect(interleaved.order[.shown] == [a[0], c[0], c[1], d2[0], d2[1], b[0]])
        #expect(interleaved.newItemsIndex == 5)
        var unmarked = noted([a[0], b[0]])
        unmarked.note([Fixtures.item(c[0]), Fixtures.item(d2[0]), Fixtures.item(c[1]), Fixtures.item(d2[1])])
        #expect(unmarked.order[.shown] == [a[0], b[0], c[0], c[1], d2[0], d2[1]])
        #expect(unmarked.newItemsIndex == nil)

        // No marker: the end, as ever. The marker at the end: the end, and it stays at the end.
        var unplaced = noted([a[0], b[0]])
        unplaced.note([Fixtures.item(c[0]), Fixtures.item(d[0])])
        #expect(unplaced.order[.shown] == [a[0], b[0], c[0], d[0]])
        #expect(unplaced.newItemsIndex == nil)
        // An icon that is given twice is listed once.
        var twice = noted([a[0]])
        twice.setNewItemsMarker(section: .shown, index: 0)
        twice.note([Fixtures.item(c[0]), Fixtures.item(c[0])])
        #expect(twice.order[.shown] == [c[0], a[0]])
        #expect(twice.newItemsIndex == 1)
        var atEnd = noted([a[0], b[0]])
        atEnd.setNewItemsMarker(section: .shown, index: 2)
        atEnd.note([Fixtures.item(c[0]), Fixtures.item(d[0])])
        #expect(atEnd.order[.shown] == [a[0], b[0], c[0], d[0]])
        #expect(atEnd.newItemsIndex == 4)

        // The marker is in the list of the section new apps go to: Hidden, here. An app the person had put elsewhere isn't at the marker.
        var hiddenMarker = noted([a[0], b[0]])
        hiddenMarker.move(app: appA, to: .hidden)
        hiddenMarker.move(app: appB, to: .hidden)
        hiddenMarker.setNewItemsMarker(section: .hidden, index: 1)
        hiddenMarker.move(app: appD, to: .shown)
        hiddenMarker.note([Fixtures.item(c[0]), Fixtures.item(d[0])])
        #expect(hiddenMarker.order[.hidden] == [a[0], c[0], b[0]])
        #expect(hiddenMarker.order[.shown] == [d[0]])
        #expect(hiddenMarker.newItemsIndex == 2)
    }

    @Test func markerFollowsItsNeighbour() {
        let p = ids(appA, "main")
        let q = ids(appB, "main")
        let r = ids(appC, "main")
        let s = ids(appD, "main")
        func model() -> SectionModel {
            var model = noted([p[0], q[0], r[0], s[0]])
            model.setNewItemsMarker(section: .shown, index: 2)   // p q | r s
            return model
        }

        // Icons before the marker leave: it is before the same icon.
        var m = model()
        m.move(app: appA, to: .hidden)
        #expect(m.order[.shown] == [q[0], r[0], s[0]])
        #expect(m.newItemsIndex == 1)
        m.insert(s[0], in: .shown, at: 0)
        #expect(m.order[.shown] == [s[0], q[0], r[0]])
        #expect(m.newItemsIndex == 2)
        // A spacer put before it pushes it along; one put after it doesn't.
        m.addSpacer(spacer("00000001"), in: .shown, at: 0)
        #expect(m.newItemsIndex == 3)
        m.addSpacer(spacer("00000002"), in: .shown, at: 4)
        #expect(m.newItemsIndex == 3)
        #expect(m.order[.shown]?[3] == r[0])
        m.removeOwnItem(OwnItems.itemID(SpacerID(rawValue: "00000001")))
        #expect(m.newItemsIndex == 2)
        m.forget(app: appB)
        #expect(m.order[.shown] == [s[0], r[0], OwnItems.itemID(SpacerID(rawValue: "00000002"))])
        #expect(m.newItemsIndex == 1)

        // The icon it is before is the one that moves: it is before the next that stays.
        var moved = model()
        moved.insert(r[0], in: .shown, at: 0)
        #expect(moved.order[.shown] == [r[0], p[0], q[0], s[0]])
        #expect(moved.newItemsIndex == 3, "between q and s, where it was")
        moved.insert(s[0], in: .hidden, at: 0)
        #expect(moved.order[.shown] == [r[0], p[0], q[0]])
        #expect(moved.newItemsIndex == 3, "nothing is left after it: it is at the end")

        // An icon dropped at its place is put before it.
        var dropped = model()
        dropped.insert(Fixtures.itemID("com.example.e"), in: .shown, at: 2)
        #expect(dropped.order[.shown]?[2] == Fixtures.itemID("com.example.e"))
        #expect(dropped.newItemsIndex == 3)

        // What a scan does again and again leaves it where it is.
        var scanned = model()
        for _ in 0..<5 { scanned.note([Fixtures.item(p[0]), Fixtures.item(q[0]), Fixtures.item(r[0]), Fixtures.item(s[0])]) }
        #expect(scanned == model())
        scanned.assignNew(apps: [appA, appB])
        #expect(scanned.newItemsIndex == 2)

        // It is a place in the list of the section new apps go to: another list has no marker, and the person's choice of section
        // without a place leaves it unplaced.
        var other = model()
        other.move(app: appC, to: .hidden)
        #expect(other.newItemsIndex == 2)
        #expect(other.order[.shown] == [p[0], q[0], s[0]], "the marker is before s now")
        other.newItems = .hidden
        #expect(other.newItemsIndex == nil)
        other.setNewItemsMarker(section: .hidden, index: 9)
        #expect(other.newItems == .hidden)
        #expect(other.newItemsIndex == 1, "brought into the list's length")
        other.setNewItemsMarker(section: .hidden, index: -4)
        #expect(other.newItemsIndex == 0)
        other.setNewItemsMarker(section: .alwaysHidden, index: 5)
        #expect(other.newItems == .alwaysHidden)
        #expect(other.newItemsIndex == 0)
        other.setNewItemsMarker(section: .alwaysHidden, index: nil)
        #expect(other.newItemsIndex == nil)
    }

    @Test func ownItemsNeverNoted() {
        var model = SectionModel()
        let spacerID = SpacerID(rawValue: "00000001")
        let frame = CGRect(x: 0, y: 0, width: 30, height: 20)
        func item(_ id: ItemID, isMantel: Bool, kind: OwnItemKind? = nil) -> MenuBarItem {
            MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil, frames: [Fixtures.display: frame], overflowedOn: [],
                        isMantel: isMantel, ownKind: kind)
        }
        let live = "com.example.mantel"
        model.note([
            item(ItemID(bundleID: live, key: .identifier(OwnItems.hiddenDotName)), isMantel: true, kind: .hiddenDot),
            item(ItemID(bundleID: live, key: .identifier(OwnItems.alwaysDotName)), isMantel: true, kind: .alwaysDot),
            item(ItemID(bundleID: live, key: .identifier(OwnItems.dividerName)), isMantel: true, kind: .divider),
            item(ItemID(bundleID: live, key: .identifier("mantel.spacer.00000001")), isMantel: true, kind: .spacer),
            item(ItemID(bundleID: live, key: .identifier("mantel.spacer.divider")), isMantel: true),
            // However one is marked, an own item is never listed as an app's.
            item(OwnItems.itemID(spacerID), isMantel: false),
            item(Fixtures.itemID("com.example.other", "marked"), isMantel: false, kind: .group),
        ])
        #expect(model.order.isEmpty)
        #expect(model.apps.isEmpty)
        #expect(model == SectionModel())

        // The apps' icons beside them are listed.
        model.note([item(Fixtures.itemID(appA), isMantel: false), item(OwnItems.itemID(spacerID), isMantel: false)])
        #expect(model.order == [.shown: [Fixtures.itemID(appA)]])
        // A spacer is in a list only because it was added.
        model.addSpacer(LayoutSpacer(id: spacerID), in: .hidden, at: 0)
        model.note([item(OwnItems.itemID(spacerID), isMantel: false)])
        #expect(model.order[.hidden] == [OwnItems.itemID(spacerID)])
        #expect(model.order[.shown] == [Fixtures.itemID(appA)])
    }

    @Test func m2ProfilesStillRead() throws {
        let json = """
        {"profiles":[{"name":"Default","sections":{
          "apps":{"com.example.a":{"section":"hidden","isAuto":true},"com.example.b":{"section":"alwaysHidden","isAuto":false}},
          "systemItems":{"wifi":"hidden"},
          "order":{"shown":["system:battery"],"hidden":["com.example.a::one","system:wifi"],"alwaysHidden":["com.example.b#0"]},
          "newItems":"hidden"}}],"activeProfileName":"Default"}
        """
        let document = try JSONDecoder().decode(ProfilesDocument.self, from: Data(json.utf8))
        let model = document.active
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: true, group: nil))
        #expect(model.apps[appB] == AppPlacement(section: .alwaysHidden, isAuto: false))
        #expect(model.systemItems == ["wifi": .hidden])
        #expect(model.order[.hidden] == [Fixtures.itemID(appA, "one"), .system("wifi")])
        #expect(model.order[.alwaysHidden] == [ItemID(bundleID: appB, key: .index(0))])
        #expect(model.newItems == .hidden)
        // What it never had is nothing: no spacers, groups, group icons or marker.
        #expect(model.spacers.isEmpty)
        #expect(model.groups.isEmpty)
        #expect(model.groupOrder.isEmpty)
        #expect(model.groupItems.isEmpty)
        #expect(model.newItemsIndex == nil)
        // It behaves as it did: new apps go to the end of Hidden.
        var later = model
        later.note([Fixtures.item(Fixtures.itemID(appC))])
        #expect(later.order[.hidden]?.last == Fixtures.itemID(appC))
    }

    @Test func spacersGroupsAndTheMarkerRoundTrip() throws {
        let a = ids(appA, "main")
        let b = ids(appB, "main")
        var model = noted([a[0], b[0]])
        model.addSpacer(LayoutSpacer(id: SpacerID(rawValue: "00000001"), width: 40, label: .text("Work")), in: .shown, at: 1)
        model.addGroup(IconGroup(id: GroupID(rawValue: "00000002"), title: "Chat", look: .image(fileName: "chat.png"), opensOnHover: true,
                                 members: [appB]), in: .hidden, at: 0)
        model.setNewItemsMarker(section: .shown, index: 1)
        model.assignNew(apps: [appA])

        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(SectionModel.self, from: data) == model)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spacers = try #require(object["spacers"] as? [String: [String: Any]])
        #expect(Array(spacers.keys) == ["00000001"])
        #expect(spacers["00000001"]?["width"] as? Int == 40)
        let groups = try #require(object["groups"] as? [String: [String: Any]])
        #expect(groups["00000002"]?["title"] as? String == "Chat")
        #expect(groups["00000002"]?["members"] as? [String] == [appB])
        #expect(object["groupOrder"] as? [String] == ["00000002"])
        let groupItems = try #require(object["groupItems"] as? [String: [String]])
        #expect(groupItems["00000002"] == [b[0].string])
        #expect(object["newItemsIndex"] as? Int == 1)
        let apps = try #require(object["apps"] as? [String: [String: Any]])
        #expect(apps[appB]?["group"] as? String == "00000002")
        #expect(apps[appB]?["section"] as? String == "alwaysHidden")
        #expect(apps[appA]?["group"] == nil, "an app in no group says nothing of one")
        let order = try #require(object["order"] as? [String: [String]])
        #expect(order["shown"] == [a[0].string, "mantel::mantel.spacer.00000001"])
        #expect(order["hidden"] == ["mantel::mantel.group.00000002"])

        // The ones the file doesn't have are the defaults, one at a time.
        let partial = try JSONDecoder().decode(SectionModel.self, from: Data(#"{"newItemsIndex":3,"groupOrder":["00000002"]}"#.utf8))
        #expect(partial.newItemsIndex == 3)
        #expect(partial.groupOrder == [GroupID(rawValue: "00000002")])
        #expect(partial.spacers.isEmpty && partial.groups.isEmpty && partial.groupItems.isEmpty)
    }

    // MARK: The owner `mantel` is no app

    @Test func theOwnerOfOwnItemsIsNoApp() {
        let a = ids(appA, "main")
        var model = noted(a)
        let own = OwnItems.owner
        let spacerItem = OwnItems.itemID(SpacerID(rawValue: "00000001"))
        model.addSpacer(spacer("00000001"), in: .hidden, at: 0)
        model.addGroup(group("00000002"), in: .shown, at: 1)
        let before = model
        let stray = ItemID(bundleID: own, key: .index(0))
        let named = ItemID(bundleID: own, key: .identifier("something"))

        // Nothing that asks for an app, or for an icon of an app, takes the owner for one: not to move it, group it, forget it, or place
        // the apps that were seen. Its icons are the spacers' and the groups', and none of them is moved with it.
        model.move(app: own, to: .shown)
        model.move(app: own, to: .alwaysHidden)
        model.move(item: stray, to: .alwaysHidden)
        model.move(item: named, to: .alwaysHidden)
        model.move(item: spacerItem, to: .alwaysHidden)
        model.insert(stray, in: .alwaysHidden, at: 0)
        model.insert(named, in: .hidden, at: 0)
        model.move(app: own, toGroup: GroupID(rawValue: "00000002"), at: 0)
        model.forget(app: own)
        model.note([Fixtures.item(stray), Fixtures.item(named)])
        #expect(model.assignNew(apps: [own]) == [])
        #expect(model == before)
        #expect(model.apps["mantel"] == nil)
        #expect(model.section(ofOwn: spacerItem) == .hidden)

        // The apps beside it are placed as ever.
        #expect(model.assignNew(apps: [own, appA]) == [appA])
        #expect(model.apps.keys.sorted() == [appA])
    }

    @Test func anIdThatCannotBeAnOwnItemsIsLeftOut() {
        var model = noted(ids(appA, "main"))
        let before = model
        // `SpacerID(rawValue:)` takes anything, but the layout takes only an id the own items' names can carry: not an empty one, and not
        // one of the wide spacer's invisible items' (`always`, `divider`, `divider.2`).
        for raw in ["", "always", "divider", "divider.2", "divider.10"] {
            model.addSpacer(LayoutSpacer(id: SpacerID(rawValue: raw)), in: .shown, at: 0)
            model.addGroup(IconGroup(id: GroupID(rawValue: raw), members: [appA]), in: .hidden, at: 0)
            #expect(model == before, "\"\(raw)\"")
        }
        #expect(model.spacers.isEmpty && model.groups.isEmpty && model.groupOrder.isEmpty)
        // Ids that are fine, even odd ones, are taken, and found by their icon.
        for raw in ["0", "s1", "divider-x", "Always", "00000001"] {
            let id = SpacerID(rawValue: raw)
            model.addSpacer(LayoutSpacer(id: id), in: .shown, at: 0)
            #expect(model.section(ofOwn: OwnItems.itemID(id)) == .shown, "\(raw)")
            model.removeOwnItem(OwnItems.itemID(id))
            #expect(model.spacers[id] == nil, "\(raw)")
        }
        #expect(model == before)
    }

    // MARK: Groups, more

    @Test func removingAGroupsLastMemberLeavesTheGroup() {
        let a = ids(appA, "one", "two")
        let g = GroupID(rawValue: "00000001")
        var model = noted(a)
        model.addGroup(IconGroup(id: g, title: "Chat", members: [appA]), in: .shown, at: 0)
        #expect(model.groupItems[g] == a)

        // The only member goes to a section: the group is still there, with no members and no icons, and its own icon is where it was.
        model.move(app: appA, to: .hidden)
        #expect(model.groups[g]?.members == [])
        #expect(model.groups[g]?.title == "Chat")
        #expect(model.groupOrder == [g])
        #expect(model.groupItems[g] == nil)
        #expect(model.section(ofOwn: OwnItems.itemID(g)) == .shown)
        #expect(model.order == [.shown: [OwnItems.itemID(g)], .hidden: a])
        #expect(model.apps[appA] == AppPlacement(section: .hidden, isAuto: false))

        // It can take members again, and again lose the last by dropping an icon of it, or by forgetting it.
        model.move(app: appA, toGroup: g, at: 0)
        #expect(model.groups[g]?.members == [appA])
        #expect(model.groupItems[g] == a)
        model.insert(a[1], in: .shown, at: 1)
        #expect(model.groups[g]?.members == [])
        #expect(model.groupItems.isEmpty)
        model.move(app: appA, toGroup: g, at: 0)
        model.forget(app: appA)
        #expect(model.groups[g]?.members == [])
        #expect(model.groupItems.isEmpty)
        #expect(model.apps[appA] == nil)
    }

    @Test func markerFollowsItsNeighbourThroughGroups() {
        let p = ids(appA, "main")
        let q = ids(appB, "main")
        let r = ids(appC, "main")
        let s = ids(appD, "main")
        let g = GroupID(rawValue: "00000001")
        let groupIcon = OwnItems.itemID(g)
        var model = noted([p[0], q[0], r[0], s[0]])
        model.setNewItemsMarker(section: .shown, index: 2)   // p q | r s

        // A group's icon put before the marker pushes it along.
        model.addGroup(IconGroup(id: g), in: .shown, at: 0)
        #expect(model.order[.shown] == [groupIcon, p[0], q[0], r[0], s[0]])
        #expect(model.newItemsIndex == 3)
        // An app taken into the group leaves the list before the marker: the marker is before the same icon.
        model.move(app: appA, toGroup: g, at: 0)
        #expect(model.order[.shown] == [groupIcon, q[0], r[0], s[0]])
        #expect(model.newItemsIndex == 2)
        // The icon the marker is before is taken in: it is before the next that stays.
        model.move(app: appC, toGroup: g, at: 1)
        #expect(model.order[.shown] == [groupIcon, q[0], s[0]])
        #expect(model.newItemsIndex == 2, "before s")
        model.move(app: appD, toGroup: g, at: 2)
        #expect(model.order[.shown] == [groupIcon, q[0]])
        #expect(model.newItemsIndex == 2, "nothing is left after it: at the end")
        // Taking the group off the layout takes its icon out from before the marker; its apps go to Always Hidden, not to this list.
        model.removeOwnItem(groupIcon)
        #expect(model.order[.shown] == [q[0]])
        #expect(model.newItemsIndex == 1)
        #expect(model.order[.alwaysHidden] == [p[0], r[0], s[0]])

        // With the marker in Always Hidden's list, the apps a removed group gives back are put at the end of it, and the marker is before
        // the same icon.
        let h = ids("com.example.h", "main")
        var other = noted([p[0], q[0], r[0]])
        other.move(app: "com.example.h", to: .alwaysHidden)
        other.order[.alwaysHidden] = h + [Fixtures.itemID("com.example.i")]
        other.addGroup(IconGroup(id: g, members: [appA, appB]), in: .shown, at: 0)
        other.setNewItemsMarker(section: .alwaysHidden, index: 1)   // h | i
        other.removeOwnItem(groupIcon)
        #expect(other.order[.alwaysHidden] == h + [Fixtures.itemID("com.example.i"), p[0], q[0]])
        #expect(other.newItemsIndex == 1, "before i")
        #expect(other.newItems == .alwaysHidden)

        // The icon the marker is before is the group's: it leaves with it.
        var last = noted([p[0]])
        last.addGroup(IconGroup(id: g), in: .shown, at: 1)
        last.setNewItemsMarker(section: .shown, index: 1)   // p | group
        last.removeOwnItem(groupIcon)
        #expect(last.order[.shown] == [p[0]])
        #expect(last.newItemsIndex == 1, "at the end")
    }
}
