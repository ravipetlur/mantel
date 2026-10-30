import Testing

@testable import MKCore

@Suite("Hotkey registration plan", .timeLimit(.minutes(2)))
struct HotkeyRegistrationPlanTests {
    private let combo = KeyCombo(keyCode: KeyCode.k, modifiers: [.control, .option, .command])
    private let other = KeyCombo(keyCode: KeyCode.k + 1, modifiers: [.control, .option, .command])
    private let notes = ItemID(bundleID: "com.example.notes", key: .identifier("main"))
    private let music = ItemID(bundleID: "com.example.music", key: .index(1))

    private func ids(_ planned: [(HotkeyID, KeyCombo)]) -> [String] {
        planned.map(\.0.rawValue)
    }

    @Test func iconBindingsWithActionRegister() {
        let preferences = IconPreferences(hotkeyActions: [notes: .show, music: .click(.right)])
        let all: [HotkeyID: KeyCombo] = [.icon(notes): combo, .icon(music): other]
        let planned = HotkeyRegistrationPlan.bindings(all, actions: HotkeyAction.all, preferences: preferences)
        #expect(ids(planned) == [HotkeyID.icon(music).rawValue, HotkeyID.icon(notes).rawValue].sorted())
        #expect(planned.first { $0.0 == .icon(notes) }?.1 == combo)
        #expect(planned.first { $0.0 == .icon(music) }?.1 == other)
        #expect(HotkeyRegistrationPlan.iconBindingsWithoutAction(all, preferences: preferences).isEmpty)
    }

    @Test func iconBindingWithoutActionSkipped() {
        let preferences = IconPreferences(hotkeyActions: [notes: .show])
        let unreadable = HotkeyID(rawValue: "icon:")
        let all: [HotkeyID: KeyCombo] = [.icon(notes): combo, .icon(music): other, unreadable: combo]
        let planned = HotkeyRegistrationPlan.bindings(all, actions: HotkeyAction.all, preferences: preferences)
        #expect(ids(planned) == [HotkeyID.icon(notes).rawValue])
        // What isn't registered is named by its ID, for the log.
        #expect(HotkeyRegistrationPlan.iconBindingsWithoutAction(all, preferences: preferences).map(\.rawValue)
                == [unreadable.rawValue, HotkeyID.icon(music).rawValue].sorted())
    }

    @Test func theShortcutShownForAnAppIsThatOfTheFirstIconThatHasOne() {
        let preferences = IconPreferences(hotkeyActions: [notes: .show, music: .click(.left)])
        // The app's second icon has the binding; the first has none.
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes, music], bindings: [.icon(music): other], preferences: preferences) == other)
        // Both do: the first of them, in the order given.
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes, music], bindings: [.icon(notes): combo, .icon(music): other],
                                                preferences: preferences) == combo)
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [music, notes], bindings: [.icon(notes): combo, .icon(music): other],
                                                preferences: preferences) == other)
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes, music], bindings: [:], preferences: preferences) == nil)
    }

    @Test func aBindingWithNoActionIsNotShownAsAShortcut() {
        // Nothing is registered for it, so the line must not say it does something.
        let preferences = IconPreferences(hotkeyActions: [music: .show])
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes], bindings: [.icon(notes): combo], preferences: preferences) == nil)
        // An icon with no action is passed over for one that has both.
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes, music], bindings: [.icon(notes): combo, .icon(music): other],
                                                preferences: preferences) == other)
    }

    @Test func aBindingMacOSRefusedIsNotShownAsAShortcut() {
        let preferences = IconPreferences(hotkeyActions: [notes: .show, music: .show])
        let all: [HotkeyID: KeyCombo] = [.icon(notes): combo, .icon(music): other]
        // The first icon's shortcut is taken by another app: the line passes it over for the second icon's, and says none if there is none.
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes, music], bindings: all, preferences: preferences, failed: [.icon(notes)]) == other)
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes], bindings: all, preferences: preferences, failed: [.icon(notes)]) == nil)
        #expect(HotkeyRegistrationPlan.shortcut(ofItems: [notes], bindings: all, preferences: preferences, failed: [.icon(music)]) == combo)
    }

    @Test func m2ActionsUnchanged() {
        // The actions the app had before icons had hotkeys register as they did: those with a shortcut, in the order of the list, and an
        // id this version doesn't know is left alone.
        let all: [HotkeyID: KeyCombo] = [.showAll: other, .openSettings: combo, .focusMode: combo, HotkeyID(rawValue: "from-a-newer-mantel"): combo]
        let withNone = HotkeyRegistrationPlan.bindings(all, actions: HotkeyAction.all, preferences: IconPreferences())
        let expected = HotkeyAction.all.map(\.id).filter { all[$0] != nil }
        #expect(withNone.map(\.0) == expected)
        #expect(withNone.map(\.0) == [.openSettings, .showAll, .focusMode])
        for planned in withNone { #expect(planned.1 == all[planned.0]) }
        // Icons with actions change nothing about them.
        let withIcons = HotkeyRegistrationPlan.bindings(all.merging([.icon(notes): other]) { $1 }, actions: HotkeyAction.all,
                                                        preferences: IconPreferences(hotkeyActions: [notes: .show]))
        #expect(Array(withIcons.map(\.0).prefix(3)) == expected)
        #expect(withIcons.count == 4)
        #expect(HotkeyRegistrationPlan.bindings([:], actions: HotkeyAction.all, preferences: IconPreferences()).isEmpty)
    }
}
