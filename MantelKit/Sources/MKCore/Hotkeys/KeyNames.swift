/// What `UCKeyTranslate` is asked to do besides translating the key.
public struct KeyTranslationOptions: OptionSet, Sendable {
    /// The value `UCKeyTranslate`'s options take.
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// No dead keys: the key as it is printed, without waiting for a second key to combine with. This is
    /// `kUCKeyTranslateNoDeadKeysMask`, which is `1 << kUCKeyTranslateNoDeadKeysBit`: the options take the mask, and not the
    /// number of the bit (0), which asks for nothing.
    public static let noDeadKeys = KeyTranslationOptions(rawValue: 1 << 0)
}

/// What the current keyboard layout prints on a key. The app asks `UCKeyTranslate`; tests give their own.
///
/// The Text Input Sources calls behind it are for the main thread, so the conformers are too.
@MainActor
public protocol KeyTranslating: Sendable {
    /// The character the key types on its own (no modifiers) in the layout in use, or nil if it types none. `options` says
    /// how to translate; `KeyNames` always asks for `.noDeadKeys`.
    func character(for keyCode: UInt16, options: KeyTranslationOptions) -> String?
}

/// How a shortcut reads: `⌃⌥⌘K`, `⌘F5`, `⌥Space`.
public enum KeyNames {
    /// The modifier glyphs in the order macOS draws them (⌃⌥⇧⌘), then the key. Fn isn't shown, because it isn't registered
    /// (Carbon can't represent it), and an arrow key's own Fn would only be noise.
    ///
    /// The keys no layout prints (F1 to F20, Space, Return, the arrows and the like) are named from a table. Any other key
    /// is the character `translator` gives, in capitals; one the layout has no character for shows as `Key <code>`.
    @MainActor
    public static func display(_ combo: KeyCombo, translator: any KeyTranslating) -> String {
        glyphs(for: combo.modifiers) + keyName(for: combo.keyCode, translator: translator)
    }

    /// The glyphs of the modifiers alone (`⌃⌘`), for showing what is held while a shortcut is being recorded.
    public static func glyphs(for modifiers: ModifierSet) -> String {
        modifiers.glyphs
    }

    @MainActor
    static func keyName(for keyCode: UInt16, translator: any KeyTranslating) -> String {
        if let number = KeyCode.functionKeyNumbers[keyCode] {
            return "F\(number)"
        }
        if let name = KeyCode.specialNames[keyCode] {
            return name
        }
        guard let typed = translator.character(for: keyCode, options: .noDeadKeys), isPrintable(typed) else {
            return "Key \(keyCode)"
        }
        // "ß" in capitals is "SS", which isn't the key's name: only a capital that is still one character is used.
        let capital = typed.uppercased()
        return capital.count == typed.count ? capital : typed
    }

    /// Whether `text` is something to show: not empty, and no control character (what a layout says for Return or Esc).
    private static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { !$0.properties.generalCategory.isControl }
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool {
        self == .control
    }
}
