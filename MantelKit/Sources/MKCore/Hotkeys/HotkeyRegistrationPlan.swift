import Foundation

/// Which of the saved shortcuts are registered with macOS.
public enum HotkeyRegistrationPlan {
    /// The bindings to register: the known actions' (in the order of `actions`), then the icons' that have an action in `preferences`
    /// (in the order of their IDs, so the same file registers the same way each time). A binding for anything else is left in the file and
    /// not registered.
    public static func bindings(_ all: [HotkeyID: KeyCombo], actions: [HotkeyAction],
                                preferences: IconPreferences) -> [(HotkeyID, KeyCombo)] {
        var planned: [(HotkeyID, KeyCombo)] = []
        for action in actions {
            if let combo = all[action.id] { planned.append((action.id, combo)) }
        }
        let icons = all.keys.filter { id in id.iconItem.map { preferences.hotkeyActions[$0] != nil } ?? false }
        for id in icons.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let combo = all[id] { planned.append((id, combo)) }
        }
        return planned
    }

    /// The shortcut an app's icons show in Settings › Layout: that of the first of them (in the order given) that has a binding which is
    /// registered, so one with no action isn't shown as if it did something, nor one that macOS refused (`failed`). Nil when none has.
    public static func shortcut(ofItems items: [ItemID], bindings all: [HotkeyID: KeyCombo], preferences: IconPreferences,
                                failed: Set<HotkeyID> = []) -> KeyCombo? {
        for item in items where preferences.hotkeyActions[item] != nil && !failed.contains(.icon(item)) {
            if let combo = all[.icon(item)] { return combo }
        }
        return nil
    }

    /// The icon bindings that have no action to do (the icon's entry in `preferences` is gone, or its ID can't be read): they aren't
    /// registered, and the log names them by ID.
    public static func iconBindingsWithoutAction(_ all: [HotkeyID: KeyCombo], preferences: IconPreferences) -> [HotkeyID] {
        all.keys.filter { id in
            guard id.rawValue.hasPrefix("icon:") else { return false }
            return id.iconItem.map { preferences.hotkeyActions[$0] == nil } ?? true
        }.sorted { $0.rawValue < $1.rawValue }
    }
}
