import MKCore

extension IconSettingsMover {
    /// The icons of an app that hold a setting (a shortcut, the names it is found by, what its shortcut does, a recent pick) under a name that
    /// `SectionModel.namesAnOwnItem` refuses: one of Mantel's own names, which no other app has. The version 1 file's migration took their
    /// records out of the layout, so no check of the app's saved icons lists them as dropped, and their settings are handed to the mover with
    /// what that check dropped. In the order of their IDs' text.
    public static func ownNamedRecords(ofApp bundleID: String, preferences: IconPreferences, bindings: HotkeyBindings) -> [ItemID] {
        var items: Set<ItemID> = Set(bindings.bindings.keys.compactMap(\.iconItem))
        items.formUnion(preferences.searchNames.keys)
        items.formUnion(preferences.hotkeyActions.keys)
        for pick in preferences.recentPicks where pick.hasPrefix(pickPrefix) {
            if let item = ItemID(string: String(pick.dropFirst(pickPrefix.count))) { items.insert(item) }
        }
        return items.filter { $0.bundleID == bundleID && SectionModel.namesAnOwnItem($0) }.sorted { $0.string < $1.string }
    }
}
