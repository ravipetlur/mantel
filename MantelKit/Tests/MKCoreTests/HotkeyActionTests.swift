import Foundation
import Testing

@testable import MKCore

@Suite("Hotkey actions", .timeLimit(.minutes(1)))
struct HotkeyActionTests {
    @Test func newActionsListedUnassigned() throws {
        #expect(HotkeyAction.all.map(\.id) == [.openSettings, .showHidden, .showAll, .secondBar, .focusMode, .mantelMenu, .commandBar])
        #expect(HotkeyAction.all.map(\.title)
            == ["Open Mantel settings", "Show hidden icons", "Show all icons", "Show the second bar", "Turn Focus Mode on or off",
                "Open Mantel's menu", "Open the command bar"])
        #expect(HotkeyID.showHidden.rawValue == "show-hidden")
        #expect(HotkeyID.showAll.rawValue == "show-all")
        #expect(HotkeyID.focusMode.rawValue == "focus-mode")
        #expect(HotkeyAction.title(for: .showHidden) == "Show hidden icons")
        #expect(HotkeyAction.title(for: .showAll) == "Show all icons")
        #expect(HotkeyAction.title(for: .focusMode) == "Turn Focus Mode on or off")

        // Every action starts without a shortcut, and a file that holds only the first one leaves the new ones unassigned.
        for action in HotkeyAction.all {
            #expect(HotkeyBindings().bindings[action.id] == nil)
        }
        let old = try JSONDecoder().decode(HotkeyBindings.self, from: Data(
            #"{"bindings":{"open-settings":{"keyCode":40,"modifiers":["command","option"]}}}"#.utf8))
        #expect(old.bindings[.openSettings] != nil)
        for id in [HotkeyID.showHidden, .showAll, .focusMode] {
            #expect(old.bindings[id] == nil)
        }
    }

    @Test func newIDsKeepTheirRawValues() throws {
        #expect(HotkeyID.secondBar.rawValue == "second-bar")
        #expect(HotkeyID.mantelMenu.rawValue == "mantel-menu")

        // Each is written as a plain string key in a JSON object and read back as the same id.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode([HotkeyID.secondBar: 1, .mantelMenu: 2])
        #expect(String(decoding: data, as: UTF8.self) == #"{"mantel-menu":2,"second-bar":1}"#)
        let decoded = try JSONDecoder().decode([HotkeyID: Int].self, from: data)
        #expect(decoded == [.secondBar: 1, .mantelMenu: 2])
    }

    @Test func secondBarIsBindable() {
        #expect(HotkeyAction.secondBar.title == "Show the second bar")

        // It has a row in the pane, once, and a title to be found by.
        #expect(HotkeyAction.all.filter { $0.id == .secondBar }.count == 1)
        #expect(HotkeyAction.title(for: .secondBar) == "Show the second bar")
        #expect(HotkeyBindings().bindings[.secondBar] == nil)
    }

    @Test func mantelMenuListedUnassigned() throws {
        #expect(HotkeyAction.mantelMenu.id == .mantelMenu)
        #expect(HotkeyAction.mantelMenu.title == "Open Mantel's menu")

        // It has a row in the pane, after the actions that were there before it, and a title to be found by.
        #expect(HotkeyAction.all.map(\.id).contains(.mantelMenu))
        #expect(HotkeyAction.all.prefix(6).last?.id == .mantelMenu)
        #expect(HotkeyAction.all.filter { $0.id == .mantelMenu }.count == 1)
        #expect(HotkeyAction.title(for: .mantelMenu) == "Open Mantel's menu")

        // It starts without a shortcut, and a file written before it existed leaves it without one.
        #expect(HotkeyBindings().bindings[.mantelMenu] == nil)
        let old = try JSONDecoder().decode(HotkeyBindings.self, from: Data(
            #"{"bindings":{"open-settings":{"keyCode":40,"modifiers":["command","option"]}}}"#.utf8))
        #expect(old.bindings[.openSettings] != nil)
        #expect(old.bindings[.mantelMenu] == nil)

        // A shortcut given to it is written under its id and read back.
        var bindings = HotkeyBindings()
        bindings.bindings[.mantelMenu] = KeyCombo(keyCode: 46, modifiers: [.command, .option])
        let data = try JSONEncoder().encode(bindings)
        #expect(String(decoding: data, as: UTF8.self).contains("\"mantel-menu\""))
        let back = try JSONDecoder().decode(HotkeyBindings.self, from: data)
        #expect(back.bindings[.mantelMenu] == bindings.bindings[.mantelMenu])
    }

    @Test func commandBarListedUnassigned() throws {
        #expect(HotkeyID.commandBar.rawValue == "command-bar")
        #expect(HotkeyAction.commandBar.id == .commandBar)
        #expect(HotkeyAction.commandBar.title == "Open the command bar")

        // It has a row in the pane, once, after the actions that were there before it, and a title to be found by.
        #expect(HotkeyAction.all.last?.id == .commandBar)
        #expect(HotkeyAction.all.filter { $0.id == .commandBar }.count == 1)
        #expect(HotkeyAction.title(for: .commandBar) == "Open the command bar")

        // It starts without a shortcut, and a file written before it existed leaves it without one.
        #expect(HotkeyBindings().bindings[.commandBar] == nil)
        let old = try JSONDecoder().decode(HotkeyBindings.self, from: Data(
            #"{"bindings":{"open-settings":{"keyCode":40,"modifiers":["command","option"]}}}"#.utf8))
        #expect(old.bindings[.openSettings] != nil)
        #expect(old.bindings[.commandBar] == nil)

        // A shortcut given to it is written under its id and read back.
        var bindings = HotkeyBindings()
        bindings.bindings[.commandBar] = KeyCombo(keyCode: 49, modifiers: [.command, .option])
        let data = try JSONEncoder().encode(bindings)
        #expect(String(decoding: data, as: UTF8.self).contains("\"command-bar\""))
        let back = try JSONDecoder().decode(HotkeyBindings.self, from: data)
        #expect(back.bindings[.commandBar] == bindings.bindings[.commandBar])
    }
}
