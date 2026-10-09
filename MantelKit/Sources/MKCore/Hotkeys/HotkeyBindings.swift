import Foundation

/// What `hotkeys.json` holds: the shortcut each action has. An action with no entry has none, which is how every action
/// starts.
///
/// A shortcut is kept as the combo the person recorded. Registering it leaves Fn out (`KeyCombo.withoutFunction`).
public struct HotkeyBindings: SettingsDocument {
    public static let fileName = "hotkeys.json"
    public static let currentVersion = 1

    public var bindings: [HotkeyID: KeyCombo]

    public init() {
        self.init(bindings: [:])
    }

    public init(bindings: [HotkeyID: KeyCombo]) {
        self.bindings = bindings
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    private enum CodingKeys: String, CodingKey {
        case bindings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bindings: try container.decodeIfPresent([HotkeyID: KeyCombo].self, forKey: .bindings) ?? [:])
    }
}
