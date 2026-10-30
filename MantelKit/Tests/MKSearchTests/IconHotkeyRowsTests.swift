import Foundation
import MKCore
import MKLayout
import Testing

@testable import MKSearch

@Suite("Icon hotkey rows", .timeLimit(.minutes(1)))
struct IconHotkeyRowsTests {
    private let one = ItemID(bundleID: "com.example.one", key: .identifier("one"))
    private let two = ItemID(bundleID: "com.example.two", key: .identifier("two"))
    private let three = ItemID(bundleID: "com.example.three", key: .identifier("three"))
    private let gone = ItemID(bundleID: "com.example.gone", key: .identifier("gone"))
    private let combo = KeyCombo(keyCode: 40, modifiers: [.command, .option])

    private var entries: [IconSearchEntry] {
        [IconSearchEntry(item: one, appName: "One", section: .shown), IconSearchEntry(item: two, appName: "Two", section: .hidden),
         IconSearchEntry(item: three, appName: "Three", section: .alwaysHidden)]
    }

    @Test func rowsFollowTheOrderOfTheIcons() {
        let bindings = [HotkeyID.icon(three): combo, .icon(one): combo, .openSettings: combo]
        let rows = IconHotkeyRows.rows(bindings: bindings, preferences: IconPreferences(hotkeyActions: [one: .show, three: .click(.right)]),
                                       entries: entries, pending: [:], fallbackName: { $0.bundleID })
        #expect(rows.map(\.name) == ["One", "Three"])
        #expect(rows.map(\.action) == [.show, .click(.right)])
        #expect(rows.allSatisfy { $0.hasBinding && $0.hasStoredAction })
    }

    @Test func iconsOfOneAppAreToldApart() {
        let first = ItemID(bundleID: "com.example.weather", key: .identifier("temperature"))
        let second = ItemID(bundleID: "com.example.weather", key: .identifier("radar"))
        let third = ItemID(bundleID: "com.example.weather", key: .identifier("alerts"))
        let weather = [IconSearchEntry(item: first, appName: "Weather", section: .shown), IconSearchEntry(item: second, appName: "Weather", section: .hidden),
                       IconSearchEntry(item: third, appName: "Weather", section: .hidden), IconSearchEntry(item: one, appName: "One", section: .shown)]
        let titles = IconHotkeyRows.displayNames(for: weather)
        #expect(titles[first] == "Weather (Shown)")
        #expect(titles[second] == "Weather (Hidden)")
        #expect(titles[third] == "Weather (Hidden) 2")
        #expect(titles[one] == "One", "an icon whose name is its own is called that")

        let bindings = [HotkeyID.icon(first): combo, .icon(second): combo]
        let rows = IconHotkeyRows.rows(bindings: bindings, preferences: IconPreferences(hotkeyActions: [first: .show, second: .show]),
                                       entries: weather, pending: [:], fallbackName: { $0.bundleID })
        #expect(rows.map(\.name) == ["Weather (Shown)", "Weather (Hidden)"])
        // The icons "Add an icon…" offers are called the same, and so are the ones a clash names.
        let addable = IconHotkeyRows.addable(entries: weather, rows: rows)
        let names = IconHotkeyRows.names(rows: rows, addable: addable, titles: titles)
        #expect(names[third] == "Weather (Hidden) 2")
        #expect(names[first] == "Weather (Shown)")
    }

    @Test func aBindingWithNoActionIsShownAsShowAndSaysSo() {
        let rows = IconHotkeyRows.rows(bindings: [.icon(one): combo], preferences: IconPreferences(), entries: entries, pending: [:],
                                       fallbackName: { $0.bundleID })
        #expect(rows.map(\.action) == [.show])
        #expect(rows.map(\.hasStoredAction) == [false])
    }

    @Test func anAddedIconHasARowBeforeItHasAShortcut() {
        let rows = IconHotkeyRows.rows(bindings: [.icon(one): combo], preferences: IconPreferences(hotkeyActions: [one: .show]),
                                       entries: entries, pending: [two: .click(.left)], fallbackName: { $0.bundleID })
        #expect(rows.map(\.name) == ["One", "Two"])
        #expect(rows.map(\.hasBinding) == [true, false])
        #expect(rows[1].action == .click(.left))
        // Once it has a shortcut and an action, what is stored is what shows.
        let after = IconHotkeyRows.rows(bindings: [.icon(one): combo, .icon(two): combo],
                                        preferences: IconPreferences(hotkeyActions: [one: .show, two: .click(.right)]), entries: entries,
                                        pending: [two: .click(.left)], fallbackName: { $0.bundleID })
        #expect(after.map(\.action) == [.show, .click(.right)])
        #expect(after.count == 2)
    }

    @Test func anIconThatIsGoneStillHasItsRow() {
        let rows = IconHotkeyRows.rows(bindings: [.icon(gone): combo, .icon(two): combo], preferences: IconPreferences(), entries: entries,
                                       pending: [:], fallbackName: { "name of \($0.bundleID)" })
        #expect(rows.map(\.name) == ["Two", "name of com.example.gone"])
    }

    @Test func addingOffersTheIconsWithoutARowInOrder() {
        let rows = IconHotkeyRows.rows(bindings: [.icon(two): combo], preferences: IconPreferences(), entries: entries, pending: [:],
                                       fallbackName: { $0.bundleID })
        #expect(IconHotkeyRows.addable(entries: entries, rows: rows).map(\.title) == ["One", "Three"])
        // An icon that is listed twice is offered once.
        #expect(IconHotkeyRows.addable(entries: entries + [entries[0]], rows: []).map(\.title) == ["One", "Two", "Three"])
    }

    @Test func withoutAShortcutWhatWasPickedLastShows() {
        // An action left behind with no shortcut: the picker shows the newer pick, so it never snaps back to the old one.
        let stale = IconPreferences(hotkeyActions: [one: .click(.left)])
        let rows = IconHotkeyRows.rows(bindings: [:], preferences: stale, entries: entries, pending: [one: .click(.right)],
                                       fallbackName: { $0.bundleID })
        #expect(rows.map(\.action) == [.click(.right)])
        #expect(rows.map(\.hasBinding) == [false])
        // A row added again shows `.show`, which is what it was given.
        let none = IconHotkeyRows.rows(bindings: [:], preferences: stale, entries: entries, pending: [one: .show], fallbackName: { $0.bundleID })
        #expect(none.map(\.action) == [.show])
    }

    @Test func withAShortcutWhatIsStoredShows() {
        let stored = IconPreferences(hotkeyActions: [one: .click(.left)])
        let rows = IconHotkeyRows.rows(bindings: [.icon(one): combo], preferences: stored, entries: entries, pending: [one: .click(.right)],
                                       fallbackName: { $0.bundleID })
        #expect(rows.map(\.action) == [.click(.left)])
    }

    @Test func everyRowAndEveryAddableIconHasANameForAWarning() {
        let bindings = [HotkeyID.icon(one): combo, .icon(gone): combo]
        let rows = IconHotkeyRows.rows(bindings: bindings, preferences: IconPreferences(), entries: entries, pending: [:],
                                       fallbackName: { "name of \($0.bundleID)" })
        let addable = IconHotkeyRows.addable(entries: entries, rows: rows)
        let names = IconHotkeyRows.names(rows: rows, addable: addable)
        // Every icon with a shortcut is named, the one that is gone included; so is every icon that can be added.
        for item in bindings.keys.compactMap(\.iconItem) { #expect(names[item] != nil) }
        #expect(names[one] == "One")
        #expect(names[gone] == "name of com.example.gone")
        #expect(names[two] == "Two")
        #expect(names[three] == "Three")
        #expect(names.count == 4)
    }
}
