import Foundation

/// What a hotkey is called wherever one is named to the person: a warning that another action has the same shortcut, a row of Settings.
public enum HotkeyTitles {
    /// An action's title, or for an icon's hotkey "<app> (icon)" with the name `iconName` gives the icon. Nil for an ID this version doesn't
    /// know, and for an icon it has no name for.
    public static func title(for id: HotkeyID, iconName: (ItemID) -> String?) -> String? {
        if let title = HotkeyAction.title(for: id) { return title }
        guard let item = id.iconItem, let name = iconName(item) else { return nil }
        return "\(name) (icon)"
    }
}
