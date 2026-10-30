import Testing

@testable import MKCore

@Suite("Moving the settings of dropped records", .timeLimit(.minutes(1)))
struct IconSettingsMoverTests {
    private let current = ItemID(bundleID: "com.example.a", key: .index(0))
    private let old = ItemID(bundleID: "com.example.a", key: .identifier("x.old"))
    private let combo = KeyCombo(keyCode: 1, modifiers: [.command, .option])

    @Test func theSettingsOfARecordMoveToTheOneIconTheAppHas() {
        var preferences = IconPreferences(searchNames: [old: ["Weather"]], hotkeyActions: [old: .show],
                                          recentPicks: ["icon:" + old.string, "icon:other"])
        var bindings = HotkeyBindings(bindings: [.icon(old): combo])
        let outcome = IconSettingsMover.move(dropped: [old], current: [current], preferences: &preferences, bindings: &bindings)

        #expect(outcome.moved == [old: current] && outcome.left.isEmpty)
        #expect(preferences.searchNames == [current: ["Weather"]])
        #expect(preferences.hotkeyActions == [current: .show])
        #expect(preferences.recentPicks == ["icon:" + current.string, "icon:other"])
        #expect(bindings.bindings == [.icon(current): combo])
    }

    @Test func nothingIsMovedWhenTheAppHasSeveralIconsOrTheIconHasASettingOfThatKind() {
        let another = ItemID(bundleID: "com.example.a", key: .index(1))
        var preferences = IconPreferences(searchNames: [old: ["Weather"]])
        var bindings = HotkeyBindings(bindings: [.icon(old): combo])
        let several = IconSettingsMover.move(dropped: [old], current: [current, another], preferences: &preferences, bindings: &bindings)
        #expect(several.moved.isEmpty && several.left == [old])
        #expect(preferences.searchNames == [old: ["Weather"]] && bindings.bindings == [.icon(old): combo], "never deleted")

        // The icon has its own names: those are kept, and the old ones stay where they are. The shortcut, which it hasn't, moves.
        preferences.searchNames[current] = ["Mine"]
        let one = IconSettingsMover.move(dropped: [old], current: [current], preferences: &preferences, bindings: &bindings)
        #expect(one.moved == [old: current] && one.left == [old])
        #expect(preferences.searchNames == [old: ["Weather"], current: ["Mine"]])
        #expect(bindings.bindings == [.icon(current): combo])
    }

    @Test func aRecordWithNoSettingsLeavesNothing() {
        var preferences = IconPreferences()
        var bindings = HotkeyBindings()
        let outcome = IconSettingsMover.move(dropped: [old], current: [current], preferences: &preferences, bindings: &bindings)
        #expect(outcome == SettingsMoved())
    }
}
