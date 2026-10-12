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

    /// Every action that can be bound, in the order the pane lists them.
    public static let all: [HotkeyAction] = [.openSettings, .showHidden, .showAll, .focusMode]

    /// The title of the action with this id, or nil for an id this version doesn't know.
    public static func title(for id: HotkeyID) -> String? {
        all.first { $0.id == id }?.title
    }
}
