import Foundation

/// What `hotkeys.json` holds: the shortcut each action has. An action with no entry has none, which is how every action
/// starts.
///
/// A shortcut is kept as the combo the person recorded. Registering it leaves Fn out (`KeyCombo.withoutFunction`).
///
/// A shortcut that names a modifier this version doesn't know (a file edited by hand, say) is left out when the file is read,
/// and logged, and the rest of the file is read as it is: one bad binding doesn't send the whole file aside. The modifier names
/// are part of the file format (see `ModifierSet`), so a change to them bumps `currentVersion`.
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

    /// A binding as the file has it, before its modifier names are looked up.
    private struct StoredCombo: Decodable {
        let keyCode: UInt16
        let modifiers: [String]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([HotkeyID: StoredCombo].self, forKey: .bindings) ?? [:]
        var bindings: [HotkeyID: KeyCombo] = [:]
        for (id, combo) in stored {
            guard let modifiers = ModifierSet(names: combo.modifiers) else {
                let unknown = ModifierSet.unknownNames(in: combo.modifiers).joined(separator: ", ")
                Log.warning("hotkeys", "the shortcut for \(id.rawValue) names a modifier this version doesn't know (\(unknown)), so it isn't loaded")
                continue
            }
            bindings[id] = KeyCombo(keyCode: combo.keyCode, modifiers: modifiers)
        }
        self.init(bindings: bindings)
    }
}
