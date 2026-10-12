import Foundation
import Testing

@testable import MKCore

@Suite("Hotkey actions", .timeLimit(.minutes(1)))
struct HotkeyActionTests {
    @Test func newActionsListedUnassigned() throws {
        #expect(HotkeyAction.all.map(\.id) == [.openSettings, .showHidden, .showAll, .focusMode])
        #expect(HotkeyAction.all.map(\.title)
            == ["Open Mantel settings", "Show hidden icons", "Show all icons", "Turn Focus Mode on or off"])
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
}
