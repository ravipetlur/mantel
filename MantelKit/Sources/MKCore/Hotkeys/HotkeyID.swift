/// Which action a hotkey belongs to: `open-settings`. It is the key in `hotkeys.json`, so an id is never renamed, and an
/// id a newer Mantel wrote that this one doesn't know is kept in the file and left unregistered.
public struct HotkeyID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Opens Mantel's Settings.
    public static let openSettings = HotkeyID(rawValue: "open-settings")
    /// Reveals the Hidden icons.
    public static let showHidden = HotkeyID(rawValue: "show-hidden")
    /// Reveals the Hidden and the Always Hidden icons.
    public static let showAll = HotkeyID(rawValue: "show-all")
    /// Turns Focus Mode on or off.
    public static let focusMode = HotkeyID(rawValue: "focus-mode")
    /// Shows the second bar.
    public static let secondBar = HotkeyID(rawValue: "second-bar")
    /// Opens Mantel's menu.
    public static let mantelMenu = HotkeyID(rawValue: "mantel-menu")
    /// Opens the command bar.
    public static let commandBar = HotkeyID(rawValue: "command-bar")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A dictionary keyed by `HotkeyID` is written as a JSON object (`{"open-settings": …}`), not as the flat list of keys and
/// values that the encoder makes of a dictionary whose keys it doesn't know to be strings.
extension HotkeyID: CodingKeyRepresentable {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey { Key(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

/// An action a hotkey can be bound to, with the name the Hotkeys pane gives it.
public struct HotkeyAction: Sendable, Equatable, Identifiable {
    public let id: HotkeyID
    public let title: String

    public init(id: HotkeyID, title: String) {
        self.id = id
        self.title = title
    }

    public static let openSettings = HotkeyAction(id: .openSettings, title: "Open Mantel settings")
    public static let showHidden = HotkeyAction(id: .showHidden, title: "Show hidden icons")
    public static let showAll = HotkeyAction(id: .showAll, title: "Show all icons")
    public static let focusMode = HotkeyAction(id: .focusMode, title: "Turn Focus Mode on or off")
    public static let secondBar = HotkeyAction(id: .secondBar, title: "Show the second bar")
    public static let mantelMenu = HotkeyAction(id: .mantelMenu, title: "Open Mantel's menu")
    public static let commandBar = HotkeyAction(id: .commandBar, title: "Open the command bar")

    /// Every action that can be bound, in the order the pane lists them.
    public static let all: [HotkeyAction] = [.openSettings, .showHidden, .showAll, .secondBar, .focusMode, .mantelMenu, .commandBar]

    /// The title of the action with this id, or nil for an id this version doesn't know.
    public static func title(for id: HotkeyID) -> String? {
        all.first { $0.id == id }?.title
    }
}

extension HotkeyID {
    private static let iconPrefix = "icon:"

    /// The hotkey of one icon in the menu bar: `icon:` and the icon's `ItemID` text. It is the key in `hotkeys.json` like any other, so
    /// the hotkey center, the clash check and the recorder treat it as they treat the rest.
    public static func icon(_ item: ItemID) -> HotkeyID {
        HotkeyID(rawValue: iconPrefix + item.string)
    }

    /// The icon this hotkey belongs to: nil for any other hotkey, and for one that says `icon:` and then something that isn't an icon's
    /// identity.
    public var iconItem: ItemID? {
        guard rawValue.hasPrefix(Self.iconPrefix) else { return nil }
        return ItemID(string: String(rawValue.dropFirst(Self.iconPrefix.count)))
    }
}
