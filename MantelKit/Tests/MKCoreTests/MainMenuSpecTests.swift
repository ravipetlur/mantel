import Testing

@testable import MKCore

@Suite("Main menu", .timeLimit(.minutes(1)))
struct MainMenuSpecTests {
    /// A menu as one line a group: "Title key", the key with its modifiers as glyphs.
    private func lines(_ menu: MainMenuSpec.Menu) -> [String] {
        menu.groups.map { group in
            group.map { item in
                let shortcut = item.key.isEmpty ? "" : " " + glyphs(item.modifiers) + item.key.uppercased()
                return item.title + shortcut
            }.joined(separator: " | ")
        }
    }

    private func glyphs(_ modifiers: ModifierSet) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
    }

    @Test func theMantelMenuIsAboutSettingsHideAndQuit() {
        let menu = MainMenuSpec.menus(for: .full).menus[0]
        #expect(menu.title == "Mantel")
        #expect(lines(menu) == [
            "About Mantel | Settings… ⌘,",
            "Hide Mantel ⌘H | Hide Others ⌥⌘H | Show All",
            "Quit Mantel ⌘Q",
        ])
        #expect(menu.groups.flatMap { $0 }.map(\.action) == [.about, .settings, .hide, .hideOthers, .showAll, .quit])
        #expect(!menu.isWindowsMenu)
    }

    @Test func theEditMenuHasUndoRedoAndTheTextShortcuts() {
        let menu = MainMenuSpec.menus(for: .full).menus[1]
        #expect(menu.title == "Edit")
        #expect(lines(menu) == [
            "Undo ⌘Z | Redo ⇧⌘Z",
            "Cut ⌘X | Copy ⌘C | Paste ⌘V | Select All ⌘A",
        ])
        #expect(menu.groups.flatMap { $0 }.map(\.action) == [.undo, .redo, .cut, .copy, .paste, .selectAll])
    }

    @Test func aWindowGetsAllThreeMenusAndATakeoverAloneGetsTheFirstOnly() {
        #expect(MainMenuSpec.menus(for: .full).menus.map(\.title) == ["Mantel", "Edit", "Window"])
        #expect(MainMenuSpec.menus(for: .appOnly).menus.map(\.title) == ["Mantel"])
        #expect(MainMenuSpec.menus(for: .appOnly).menus.first == MainMenuSpec.menus(for: .full).menus.first, "the same Mantel menu")
        #expect(MainMenuSpec.menus(for: .none).menus.isEmpty)
    }
}
