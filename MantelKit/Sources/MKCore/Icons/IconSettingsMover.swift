import Foundation

/// What was done with the settings of the icons whose records a check took out (`IconSettingsMover`).
public struct SettingsMoved: Sendable, Equatable {
    /// The icons whose settings were given to the app's one icon now: from the record that was taken out to that icon.
    public var moved: [ItemID: ItemID]
    /// The records that were taken out and that hold a setting that wasn't moved: it stays under the old ID.
    public var left: [ItemID]

    public init(moved: [ItemID: ItemID] = [:], left: [ItemID] = []) {
        self.moved = moved
        self.left = left
    }
}

/// What becomes of the settings of an icon whose record was taken out: its shortcut (`hotkeys.json`), and what `icons.json` holds of it (the
/// names it is found by, what its shortcut does, the command bar's recent picks of it).
///
/// A record is taken out when it isn't one of the icons its app lists. When the app has exactly one icon, the settings are most likely that
/// icon's (an icon that was saved under a name it never had), and are given to it, one kind at a time, unless it has a setting of that kind
/// already. Otherwise, or if it has, the setting stays where it is: nothing is ever deleted.
public enum IconSettingsMover {
    /// The command bar's recent picks name an icon `icon:` and its ID text (`SearchCandidate`).
    public static let pickPrefix = "icon:"

    /// Moves the settings of `dropped` to the one icon of `current`, where that is to be done; the rest of the two documents is left as it is.
    /// `current` is the icons the app lists, all of them.
    public static func move(dropped: [ItemID], current: [ItemID], preferences: inout IconPreferences,
                            bindings: inout HotkeyBindings) -> SettingsMoved {
        let target = current.count == 1 ? current[0] : nil
        var outcome = SettingsMoved()
        for old in dropped where old != target {
            var stays = false
            // Each kind: held by the old record, wanted by the icon, and moved when the icon has none.
            let oldKey = HotkeyID.icon(old)
            if let combo = bindings.bindings[oldKey] {
                if let target, bindings.bindings[HotkeyID.icon(target)] == nil {
                    bindings.bindings[HotkeyID.icon(target)] = combo
                    bindings.bindings[oldKey] = nil
                    outcome.moved[old] = target
                } else {
                    stays = true
                }
            }
            if let names = preferences.searchNames[old] {
                if let target, preferences.searchNames[target] == nil {
                    preferences.searchNames[target] = names
                    preferences.searchNames[old] = nil
                    outcome.moved[old] = target
                } else {
                    stays = true
                }
            }
            if let action = preferences.hotkeyActions[old] {
                if let target, preferences.hotkeyActions[target] == nil {
                    preferences.hotkeyActions[target] = action
                    preferences.hotkeyActions[old] = nil
                    outcome.moved[old] = target
                } else {
                    stays = true
                }
            }
            if let place = preferences.recentPicks.firstIndex(of: pickPrefix + old.string) {
                if let target, !preferences.recentPicks.contains(pickPrefix + target.string) {
                    preferences.recentPicks[place] = pickPrefix + target.string
                    outcome.moved[old] = target
                } else {
                    stays = true
                }
            }
            if stays { outcome.left.append(old) }
        }
        return outcome
    }

    /// Whether `item` has any setting in the two documents: what decides whether a record that is taken out leaves something behind.
    public static func holdsSettings(_ item: ItemID, preferences: IconPreferences, bindings: HotkeyBindings) -> Bool {
        bindings.bindings[HotkeyID.icon(item)] != nil || preferences.searchNames[item] != nil
            || preferences.hotkeyActions[item] != nil || preferences.recentPicks.contains(pickPrefix + item.string)
    }
}
