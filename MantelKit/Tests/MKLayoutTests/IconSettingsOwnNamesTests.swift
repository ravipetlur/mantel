import Testing

@testable import MKCore
@testable import MKLayout

/// The settings kept under a name of Mantel's own that the version 1 file's migration took out of the layout (`IconSettingsMover.ownNamedRecords`).
@Suite("Settings under Mantel's own names", .timeLimit(.minutes(1)))
struct IconSettingsOwnNamesTests {
    private let app = "com.example.a"
    private let combo = KeyCombo(keyCode: 1, modifiers: [.command, .option])

    private func named(_ bundleID: String, _ name: String) -> ItemID { ItemID(bundleID: bundleID, key: .identifier(name)) }

    @Test func theAppsSettingsUnderMantelsNamesAreFoundWhateverTheyAre() {
        let dot = named(app, OwnItems.hiddenDotName), divider = named(app, OwnItems.dividerName), spacer = named(app, "mantel.spacer.12345678")
        let ofAnother = named("com.example.b", OwnItems.hiddenDotName)
        let real = ItemID(bundleID: app, key: .index(0)), fixture = named(app, "mantel.fixture.one")
        let preferences = IconPreferences(searchNames: [dot: ["Dot"], real: ["Real"]], hotkeyActions: [divider: .show, ofAnother: .show],
                                          recentPicks: ["icon:" + spacer.string, "icon:" + real.string, "icon:" + fixture.string, "other"])
        let bindings = HotkeyBindings(bindings: [.icon(dot): combo, .icon(fixture): combo])

        let found = IconSettingsMover.ownNamedRecords(ofApp: app, preferences: preferences, bindings: bindings)
        #expect(found == [divider, dot, spacer].sorted { $0.string < $1.string }, "this app's, under Mantel's names only, once each")
        #expect(IconSettingsMover.ownNamedRecords(ofApp: "com.example.c", preferences: preferences, bindings: bindings).isEmpty)
    }

    @Test func theirSettingsMoveToTheAppsOneIconWithTheOnesThatWereDropped() {
        // The check of the app's saved icons drops `x.phantom`; the migration had dropped the dot's record earlier, so the check doesn't.
        let dot = named(app, OwnItems.hiddenDotName), phantom = named(app, "x.phantom"), icon = ItemID(bundleID: app, key: .index(0))
        var preferences = IconPreferences(searchNames: [dot: ["Dot"]], hotkeyActions: [dot: .show])
        var bindings = HotkeyBindings(bindings: [.icon(dot): combo])
        let dropped = [phantom] + IconSettingsMover.ownNamedRecords(ofApp: app, preferences: preferences, bindings: bindings)

        let outcome = IconSettingsMover.move(dropped: dropped, current: [icon], preferences: &preferences, bindings: &bindings)

        #expect(outcome.moved == [dot: icon] && outcome.left.isEmpty)
        #expect(bindings.bindings == [.icon(icon): combo])
        #expect(preferences.searchNames == [icon: ["Dot"]] && preferences.hotkeyActions == [icon: .show])
    }
}
