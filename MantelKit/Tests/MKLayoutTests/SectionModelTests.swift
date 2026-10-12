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

        // Icons are listed in the order they are noted, each under its own section; noting one again changes nothing.
        model.note([Fixtures.item(a1), Fixtures.item(b1), Fixtures.item(wifi), Fixtures.item(a2)])
        #expect(model.order == [.shown: [a1, b1, wifi, a2]])
        model.note([Fixtures.item(b1), Fixtures.item(a1)])
        #expect(model.order == [.shown: [a1, b1, wifi, a2]])

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
}
