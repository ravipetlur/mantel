import MKCore
import MKLayout
import Testing

@testable import MKSearch

@Suite("Icon search entries", .timeLimit(.minutes(1)))
struct IconSearchEntriesTests {
    private let weather = "com.example.weather"
    private let notes = "com.example.notes"
    private let sync = "com.example.sync"

    private func build(_ items: [MenuBarItem], sections: SectionModel? = nil, preferences: IconPreferences = IconPreferences(),
                       names: [String: String] = [:]) -> [IconSearchEntry] {
        var model = sections ?? SectionModel()
        model.note(items)
        return IconSearchEntries.build(inventory: SearchFixtures.inventory(items), sections: model, preferences: preferences, names: names)
    }

    @Test func oneEntryPerIcon() {
        let first = SearchFixtures.itemID(weather, "temp")
        let second = SearchFixtures.itemID(weather, "wind")
        let other = SearchFixtures.itemID(notes)
        let entries = build([SearchFixtures.item(first), SearchFixtures.item(second), SearchFixtures.item(other),
                             // The same item read twice is one icon.
                             SearchFixtures.item(other)])
        #expect(entries.map(\.item) == [first, second, other])

        // An icon the sections remember and the inventory doesn't have (its app isn't running) is there too, listed where the layout has it.
        var model = SectionModel()
        let gone = SearchFixtures.itemID(sync)
        model.note([SearchFixtures.item(gone)])
        model.move(item: gone, to: .hidden)
        let remembered = IconSearchEntries.build(inventory: SearchFixtures.inventory([SearchFixtures.item(other)]), sections: model,
                                                 preferences: IconPreferences(), names: [:])
        #expect(Set(remembered.map(\.item)) == [gone, other])
        #expect(remembered.first { $0.item == gone }?.section == .hidden)
        #expect(remembered.first { $0.item == other }?.section == .shown)
    }

    @Test func entriesFollowTheLayout() {
        let shown = SearchFixtures.itemID(weather)
        let hiddenOne = SearchFixtures.itemID(notes)
        let hiddenTwo = SearchFixtures.itemID(sync)
        var model = SectionModel()
        model.note([SearchFixtures.item(shown), SearchFixtures.item(hiddenOne), SearchFixtures.item(hiddenTwo)])
        model.insert(hiddenTwo, in: .hidden, at: 0)
        model.insert(hiddenOne, in: .hidden, at: 1)
        // The inventory lists them in another order, which only matters for an icon no list holds.
        let late = SearchFixtures.itemID("com.example.late")
        let inventory = SearchFixtures.inventory([SearchFixtures.item(hiddenOne), SearchFixtures.item(late), SearchFixtures.item(shown),
                                                  SearchFixtures.item(hiddenTwo)])
        let entries = IconSearchEntries.build(inventory: inventory, sections: model, preferences: IconPreferences(), names: [:])
        #expect(entries.map(\.item) == [shown, hiddenTwo, hiddenOne, late])
        #expect(entries.map(\.section) == [.shown, .hidden, .hidden, .shown])
        #expect(entries.map(\.subtitle) == ["Shown", "Hidden", "Hidden", "Shown"])
    }

    @Test func ownItemsExcluded() {
        let app = SearchFixtures.itemID(weather)
        let dot = ItemID(bundleID: "com.example.mantel", key: .identifier(OwnItems.hiddenDotName))
        let spacerID = SpacerID.make()
        let groupID = GroupID.make()
        let drawnSpacer = ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.spacer.\(spacerID.rawValue)"))
        // The invisible items the wide spacer uses are Mantel's, and none of the kinds.
        let wide = ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.spacer.divider"))
        let items = [
            SearchFixtures.item(app),
            SearchFixtures.item(dot, isMantel: true, ownKind: .hiddenDot),
            SearchFixtures.item(drawnSpacer, isMantel: true, ownKind: .spacer),
            SearchFixtures.item(wide, isMantel: true),
        ]

        // Spacers and groups are in the layout's lists under their own identity, and are left out of the entries as well.
        var model = SectionModel()
        model.addSpacer(LayoutSpacer(id: spacerID), in: .shown, at: 0)
        model.addGroup(IconGroup(id: groupID, title: "Tools"), in: .hidden, at: 0)
        #expect(model.order[.shown]?.contains(OwnItems.itemID(spacerID)) == true)
        #expect(model.order[.hidden]?.contains(OwnItems.itemID(groupID)) == true)

        let entries = build(items, sections: model)
        #expect(entries.map(\.item) == [app])
    }

    @Test func namesFallBackInOrder() {
        let named = SearchFixtures.itemID(weather)
        let drawnName = SearchFixtures.itemID(notes)
        let neither = SearchFixtures.itemID(sync)
        let entries = build([SearchFixtures.item(named, appName: "Inventory Weather"), SearchFixtures.item(drawnName, appName: "Inventory Notes"),
                             SearchFixtures.item(neither)],
                            names: [weather: "Weather Station", sync: "  "])
        // The app's own name first, then what the inventory read, then the bundle ID. A name that is only spaces is none.
        #expect(entries.map(\.appName) == ["Weather Station", "Inventory Notes", sync])
        #expect(entries.map(\.title) == ["Weather Station", "Inventory Notes", sync])
    }

    @Test func systemItemsByModuleTitle() {
        let wifi = ItemID.system("wifi")
        let sound = ItemID.system("sound")
        // A module the table doesn't know is named by what the inventory read, else by the module.
        let airdrop = ItemID.system("airdrop")
        let unnamed = ItemID.system("mystery")
        let entries = build([SearchFixtures.item(wifi, appName: "Inventory Wi-Fi"), SearchFixtures.item(sound),
                             SearchFixtures.item(airdrop, appName: "AirDrop"), SearchFixtures.item(unnamed)],
                            // An app's name by bundle ID is never a system item's.
                            names: [ItemID.systemBundleID: "Wrong"])
        #expect(entries.map(\.appName) == ["Wi-Fi", "Sound", "AirDrop", "mystery"])
        #expect(entries.allSatisfy { $0.section == .shown })
    }

    @Test func groupedHaveGroupTitle() {
        let grouped = SearchFixtures.itemID(notes)
        let plain = SearchFixtures.itemID(weather)
        let untitledMember = SearchFixtures.itemID(sync)
        var model = SectionModel()
        model.note([SearchFixtures.item(grouped), SearchFixtures.item(plain), SearchFixtures.item(untitledMember)])
        model.addGroup(IconGroup(title: "Utilities", members: [notes]), in: .shown, at: 0)
        model.addGroup(IconGroup(title: nil, members: [sync]), in: .shown, at: 0)

        let entries = build([SearchFixtures.item(grouped), SearchFixtures.item(plain), SearchFixtures.item(untitledMember)], sections: model)
        let byItem = Dictionary(uniqueKeysWithValues: entries.map { ($0.item, $0) })
        #expect(byItem[grouped]?.groupTitle == "Utilities")
        #expect(byItem[grouped]?.section == nil)
        #expect(byItem[grouped]?.subtitle == "Utilities group")
        // A group with no title still has one: the name Mantel gives it elsewhere.
        #expect(byItem[untitledMember]?.groupTitle == "")
        #expect(byItem[untitledMember]?.section == nil)
        #expect(byItem[untitledMember]?.subtitle == "Icon group")
        // An icon that isn't in a group says nothing of one.
        #expect(byItem[plain]?.groupTitle == nil)
        #expect(byItem[plain]?.section == .shown)
        #expect(entries.count == 3)

        // An app in a group whose icons no list holds yet (the first read after the group was made) is in it just the same.
        var fresh = model
        fresh.groupItems = [:]
        fresh.order = [:]
        let unlisted = IconSearchEntries.build(inventory: SearchFixtures.inventory([SearchFixtures.item(grouped)]), sections: fresh,
                                               preferences: IconPreferences(), names: [:])
        #expect(unlisted.first?.groupTitle == "Utilities")
        #expect(unlisted.first?.section == nil)
    }

    @Test func customNamesAttached() {
        let one = SearchFixtures.itemID(weather)
        let two = SearchFixtures.itemID(notes)
        var preferences = IconPreferences()
        preferences.searchNames[one] = ["forecast", "rain"]
        // A name for an icon that isn't there is not an entry.
        preferences.searchNames[SearchFixtures.itemID("com.example.elsewhere")] = ["ghost"]
        let entries = build([SearchFixtures.item(one, appName: "Weather Station", label: "  14 degrees  "), SearchFixtures.item(two)],
                            preferences: preferences)
        #expect(entries.count == 2)
        #expect(entries[0].customNames == ["forecast", "rain"])
        #expect(entries[0].label == "14 degrees")
        #expect(entries[1].customNames.isEmpty)
        #expect(entries[1].label == nil)
    }
}
