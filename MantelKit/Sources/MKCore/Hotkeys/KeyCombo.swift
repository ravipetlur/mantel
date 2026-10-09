/// A key and the modifiers held with it: one shortcut.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// The virtual key code (`kVK_*`), which is the key's place on the keyboard and not what the layout prints on it.
    public let keyCode: UInt16
    public let modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The combo as Carbon registers it: without Fn, which Carbon can't represent. Fn is the one modifier the keyboard
    /// reports on its own (an arrow key says it), so the combo that is registered, shown and compared with others is this one.
    public var withoutFunction: KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers.subtracting(.function))
    }

    /// Whether the key is one of F1 to F20.
    public var isFunctionKey: Bool {
        KeyCode.functionKeyNumbers[keyCode] != nil
    }

    /// Whether the combo has too little to be registered: registering a letter on its own, or with ⇧ only, would take the
    /// key from every app it is typed in. A shortcut needs ⌘, ⌃ or ⌥, unless its key is F1 to F20, which no one types.
    public var lacksModifier: Bool {
        guard !isFunctionKey else { return false }
        return modifiers.isDisjoint(with: [.command, .control, .option])
    }
}
