import Foundation

/// One of macOS's own keyboard shortcuts, as System Settings › Keyboard › Keyboard Shortcuts keeps it.
public struct SymbolicHotkey: Sendable, Equatable {
    /// The number macOS gives the shortcut (64 is Spotlight's).
    public let id: Int
    public let combo: KeyCombo
    /// What the shortcut does, for the ids in `SymbolicHotkeys.defaults`; nil for the rest.
    public let name: String?

    public init(id: Int, combo: KeyCombo, name: String?) {
        self.id = id
        self.combo = combo
        self.name = name
    }
}

/// Reads the `AppleSymbolicHotKeys` dictionary of the `com.apple.symbolichotkeys` preferences domain, which holds the
/// system's keyboard shortcuts. The app reads that dictionary (read-only) and hands it here, so that this stays a pure
/// function that tests feed their own dictionaries.
///
/// An entry looks like this, keyed by the shortcut's number:
///
///     "64": { enabled: true, value: { type: "standard", parameters: [32, 49, 1048576] } }
///
/// where the parameters are the ASCII code of the key (65535 when it has none), its key code, and its modifiers as
/// `NSEvent.ModifierFlags` raw values.
///
/// The dictionary holds only what has been changed or switched on and off: a shortcut the person never touched is absent
/// altogether (⌘Space), or is there as `{ enabled: true }` with no `value` (⌃← on a Mac running macOS 27). Those are as macOS ships them,
/// which is what `defaults` has.
public enum SymbolicHotkeys {
    /// The shortcuts that are switched on and have a key, in order of their number:
    /// - An entry with a `value` is that shortcut. It wins over `defaults`, so a shortcut the person moved is where they put it.
    /// - An entry that is enabled and has no `value` is the default of its id, if `defaults` has one.
    /// - An id that isn't in the dictionary at all is its default, switched on, if `defaults` has one.
    /// - A disabled entry is left out whether or not it keeps a `value` (a shortcut that is switched off keeps its key).
    /// - Left out too: an entry whose `value` isn't a standard shortcut or hasn't the three parameters, and one whose key code
    ///   is 65535, which is how macOS keeps a shortcut that has been cleared. Neither falls back to the default.
    public static func parse(_ plist: [String: Any]) -> [SymbolicHotkey] {
        parse(plist, defaults: defaults)
    }

    /// `parse` with the defaults it fills in given (tests give none, to see what a dictionary says on its own). The names
    /// are always those of `SymbolicHotkeys.defaults`.
    static func parse(_ plist: [String: Any], defaults: [SymbolicHotkey]) -> [SymbolicHotkey] {
        let defaultsByID = Dictionary(defaults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [SymbolicHotkey] = []
        var idsInPlist: Set<Int> = []

        for (key, entry) in plist {
            guard let id = Int(key) else { continue }
            idsInPlist.insert(id)
            if let shortcut = shortcut(id: id, entry: entry, default: defaultsByID[id]) {
                found.append(shortcut)
            }
        }
        // What the dictionary doesn't mention is as shipped.
        found += defaults.filter { !idsInPlist.contains($0.id) }
        return found.sorted { $0.id < $1.id }
    }

    /// The shortcut an entry stands for, or nil if it stands for none.
    private static func shortcut(id: Int, entry: Any, default fallback: SymbolicHotkey?) -> SymbolicHotkey? {
        guard let entry = entry as? [String: Any], flag(entry["enabled"]) == true else { return nil }
        // Enabled, and nothing else: untouched.
        guard let value = entry["value"] else { return fallback }
        guard let value = value as? [String: Any],
              (value["type"] as? String).map({ $0 == "standard" }) ?? true,
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let code = integer(parameters[1]), let cocoa = integer(parameters[2]),
              code != noKey, let keyCode = UInt16(exactly: code), cocoa >= 0
        else { return nil }
        return SymbolicHotkey(id: id,
                              combo: KeyCombo(keyCode: keyCode, modifiers: ModifierSet(cocoaFlags: UInt(cocoa))),
                              name: names[id])
    }

    /// The names of the ids in `defaults`.
    private static let names: [Int: String] = Dictionary(
        defaults.compactMap { shortcut in shortcut.name.map { (shortcut.id, $0) } }, uniquingKeysWith: { first, _ in first }
    )

    /// What macOS stored for a key that isn't there.
    private static let noKey = 65535

    /// A value that is a Boolean however the property list was read (a `Bool`, or the `NSNumber` that the defaults database
    /// hands back); nil if it isn't one.
    private static func flag(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        return (value as? NSNumber)?.boolValue
    }

    /// An integer however it was read: an `Int` in a test's dictionary, an `NSNumber` out of the defaults database.
    private static func integer(_ value: Any) -> Int? {
        if let integer = value as? Int { return integer }
        return (value as? NSNumber)?.intValue
    }

    // MARK: Defaults

    /// The shortcuts macOS ships that are most likely to be in the way, with the names the Hotkeys pane shows. They are the
    /// only names there are: any other id is "a system shortcut".
    ///
    /// Ids 28 to 31, 60, 61, 64 and 184 were checked against the values a real Mac running macOS 27 keeps in its plist.
    public static let defaults: [SymbolicHotkey] = [
        SymbolicHotkey(id: 27, combo: KeyCombo(keyCode: 50, modifiers: .command), name: "Move focus to next window"),
        SymbolicHotkey(id: 28, combo: KeyCombo(keyCode: 20, modifiers: [.shift, .command]),
                       name: "Save picture of screen as a file"),
        SymbolicHotkey(id: 29, combo: KeyCombo(keyCode: 20, modifiers: [.control, .shift, .command]),
                       name: "Copy picture of screen to the clipboard"),
        SymbolicHotkey(id: 30, combo: KeyCombo(keyCode: 21, modifiers: [.shift, .command]),
                       name: "Save picture of selected area as a file"),
        SymbolicHotkey(id: 31, combo: KeyCombo(keyCode: 21, modifiers: [.control, .shift, .command]),
                       name: "Copy picture of selected area to the clipboard"),
        SymbolicHotkey(id: 32, combo: KeyCombo(keyCode: KeyCode.upArrow, modifiers: .control), name: "Mission Control"),
        SymbolicHotkey(id: 33, combo: KeyCombo(keyCode: KeyCode.downArrow, modifiers: .control), name: "Application windows"),
        SymbolicHotkey(id: 36, combo: KeyCombo(keyCode: 103, modifiers: []), name: "Show Desktop"),
        SymbolicHotkey(id: 60, combo: KeyCombo(keyCode: KeyCode.space, modifiers: .control),
                       name: "Select the previous input source"),
        SymbolicHotkey(id: 61, combo: KeyCombo(keyCode: KeyCode.space, modifiers: [.control, .option]),
                       name: "Select next source in Input menu"),
        SymbolicHotkey(id: 64, combo: KeyCombo(keyCode: KeyCode.space, modifiers: .command), name: "Show Spotlight search"),
        SymbolicHotkey(id: 65, combo: KeyCombo(keyCode: KeyCode.space, modifiers: [.option, .command]),
                       name: "Show Finder search window"),
        SymbolicHotkey(id: 79, combo: KeyCombo(keyCode: KeyCode.leftArrow, modifiers: .control), name: "Move left a space"),
        SymbolicHotkey(id: 81, combo: KeyCombo(keyCode: KeyCode.rightArrow, modifiers: .control), name: "Move right a space"),
        SymbolicHotkey(id: 184, combo: KeyCombo(keyCode: 23, modifiers: [.shift, .command]),
                       name: "Screenshot and recording options"),
    ]
}
