import AppKit
import Foundation
import Testing

@testable import MKCommands

@Suite("Settings pages", .timeLimit(.minutes(1)))
struct SettingsPageTests {
    @Test func sidebarOrder() {
        #expect(SettingsPage.allCases == [.general, .layout, .secondBar, .hotkeys, .cosmetics, .permissions, .advanced, .diagnostics, .about])
        #expect(SettingsPage.allCases.map(\.title)
            == ["General", "Layout", "Second bar", "Hotkeys", "Cosmetics", "Permissions", "Advanced", "Diagnostics", "About"])
    }

    @Test func everyPageHasTitleAndSymbol() {
        let symbols: [SettingsPage: String] = [
            .general: "gearshape", .layout: "rectangle.split.3x1", .secondBar: "menubar.dock.rectangle", .hotkeys: "keyboard",
            .cosmetics: "paintpalette", .permissions: "lock.shield", .advanced: "slider.horizontal.3", .diagnostics: "stethoscope",
            .about: "info.circle",
        ]
        #expect(symbols.count == SettingsPage.allCases.count)
        for page in SettingsPage.allCases {
            #expect(!page.title.isEmpty, "\(page.rawValue) has a title")
            #expect(page.symbol == symbols[page], "\(page.rawValue) has its symbol")
            #expect(NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil) != nil, "\(page.symbol) is a symbol")
        }
        // No two pages share a title or a symbol, which would make the sidebar ambiguous.
        #expect(Set(SettingsPage.allCases.map(\.title)).count == SettingsPage.allCases.count)
        #expect(Set(SettingsPage.allCases.map(\.symbol)).count == SettingsPage.allCases.count)
    }

    @Test func newPagesRoundTrip() throws {
        for (page, word) in [(SettingsPage.secondBar, "second-bar"), (.cosmetics, "cosmetics")] {
            #expect(page.rawValue == word)
            let command = MantelCommand.openSettings(page)
            let text = "{\"command\":\"openSettings\",\"page\":\"\(word)\"}"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(String(decoding: try encoder.encode(command), as: UTF8.self) == text)
            #expect(try JSONDecoder().decode(MantelCommand.self, from: Data(text.utf8)) == command)
            // The page is also what the settings file keeps as the pane Settings was last on.
            #expect(SettingsPage(rawValue: word) == page)
        }
        // The page's name as a word on its own, as `mantel settings` is given it.
        #expect(try CLIParser.parse(["settings", "second-bar"]).get().command == .openSettings(.secondBar))
        #expect(try CLIParser.parse(["settings", "cosmetics"]).get().command == .openSettings(.cosmetics))
    }

    @Test func secondBarRawValueIsSecondDashBar() {
        #expect(SettingsPage.secondBar.rawValue == "second-bar")
        #expect(SettingsPage(rawValue: "second-bar") == .secondBar)
        // The Swift name is not a spelling of the page.
        #expect(SettingsPage(rawValue: "secondBar") == nil)
        #expect(SettingsPage(rawValue: "second bar") == nil)
    }
}
