/// A reason a shortcut may not work as the person expects.
public enum HotkeyClash: Sendable, Equatable {
    /// Another Mantel action has the same shortcut.
    case mantel(HotkeyID)
    /// macOS has switched this shortcut on for itself, and gets it first.
    case system(SymbolicHotkey)
    /// Only ⌥ (or ⌥⇧) is held with the key. macOS may refuse such a shortcut, because it types characters.
    case optionOnly
    /// There is no ⌘, ⌃ or ⌥ (and the key isn't F1 to F20): registered, it would take what is typed.
    case noModifier

    /// Whether the shortcut must not be saved. A missing modifier does that; the other clashes are shown as a warning, next
    /// to a shortcut that is saved and registered.
    public var preventsSaving: Bool {
        self == .noModifier
    }

    /// The warning the Hotkeys pane shows under the field. `actionTitle` names a Mantel action by its id (nil for an id it
    /// doesn't know, which is then shown by the id).
    public func message(actionTitle: (HotkeyID) -> String?) -> String {
        switch self {
        case .mantel(let id): "Already used by Mantel: \(actionTitle(id) ?? id.rawValue)"
        case .system(let shortcut): "Used by macOS: \(shortcut.name ?? "a system shortcut")"
        case .optionOnly: "macOS may block shortcuts that use only ⌥"
        case .noModifier: "Add ⌘, ⌃ or ⌥"
        }
    }
}

/// Finds what stands in the way of a shortcut, before it is saved and after.
public enum ClashDetector {
    /// What stands in the way of giving `id` the shortcut `combo`.
    ///
    /// - `mantel` is every Mantel binding as it is now, including `id`'s own, which isn't a clash with itself.
    /// - `system` is the enabled shortcuts macOS has (`SymbolicHotkeys.parse`).
    ///
    /// Fn is left out on both sides of every comparison, because a shortcut is registered without it. A combo with no
    /// modifier (`lacksModifier`) is only that: it isn't going to be saved, so nothing else about it matters. Otherwise the
    /// answer lists, in this order, the other Mantel actions with the combo (by id), the system shortcuts with it (by
    /// number), and `.optionOnly` if ⌥ or ⌥⇧ is all that is held.
    public static func clashes(for combo: KeyCombo, assigning id: HotkeyID,
                               mantel: [HotkeyID: KeyCombo], system: [SymbolicHotkey]) -> [HotkeyClash] {
        let registered = combo.withoutFunction
        if registered.lacksModifier {
            return [.noModifier]
        }

        var found: [HotkeyClash] = []
        for (other, otherCombo) in mantel.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where other != id && otherCombo.withoutFunction == registered {
            found.append(.mantel(other))
        }
        for shortcut in system.sorted(by: { $0.id < $1.id }) where shortcut.combo.withoutFunction == registered {
            found.append(.system(shortcut))
        }
        if registered.modifiers == .option || registered.modifiers == [.option, .shift] {
            found.append(.optionOnly)
        }
        return found
    }
}
