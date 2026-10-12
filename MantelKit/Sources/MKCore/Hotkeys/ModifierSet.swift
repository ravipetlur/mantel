/// The modifier keys of a shortcut, in a form that doesn't belong to AppKit or to Carbon, with the translation to each.
///
/// - **Cocoa** (`NSEvent.ModifierFlags`, what the recorder hears): ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20, Fn 1<<23. The flags
///   are told apart from the others in the same word (Caps Lock, the numeric pad, Help, and the low device-dependent bits),
///   none of which is a modifier of a shortcut.
/// - **Carbon** (what `RegisterEventHotKey` takes): `cmdKey` 256, `shiftKey` 512, `optionKey` 2048, `controlKey` 4096.
///   Carbon has no Fn, so `.function` is dropped on the way there; whoever registers a combo registers it without Fn.
///
/// It is written to the settings files as the names of its members (`["control","command"]`), in the order the glyphs are
/// drawn, so that a file doesn't depend on how the bits are laid out here.
///
/// **The list of names is part of the file format** (`hotkeys.json`): `control`, `option`, `shift`, `command` and `function`.
/// Adding a name, or renaming or removing one, changes what a file may say, so it bumps `HotkeyBindings.currentVersion`.
public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)
    /// The Fn (globe) key. Arrow keys, Home, End, Page Up and Down and Forward Delete report it without it being held.
    public static let function = ModifierSet(rawValue: 1 << 4)

    /// Each modifier with what each world calls it, in the order the glyphs are drawn (⌃⌥⇧⌘).
    private struct Entry {
        let modifier: ModifierSet
        let name: String
        let glyph: String
        let cocoa: UInt
        /// Nil for Fn.
        let carbon: UInt32?
    }

    private static let entries: [Entry] = [
        Entry(modifier: .control, name: "control", glyph: "⌃", cocoa: 1 << 18, carbon: 4096),
        Entry(modifier: .option, name: "option", glyph: "⌥", cocoa: 1 << 19, carbon: 2048),
        Entry(modifier: .shift, name: "shift", glyph: "⇧", cocoa: 1 << 17, carbon: 512),
        Entry(modifier: .command, name: "command", glyph: "⌘", cocoa: 1 << 20, carbon: 256),
        Entry(modifier: .function, name: "function", glyph: "fn", cocoa: 1 << 23, carbon: nil),
    ]

    // MARK: Cocoa

    /// The modifiers in `NSEvent.ModifierFlags`' raw value; the bits that aren't one of the five are ignored.
    public init(cocoaFlags: UInt) {
        self = Self.entries.reduce(into: []) { set, entry in
            if cocoaFlags & entry.cocoa != 0 { set.insert(entry.modifier) }
        }
    }

    /// As `NSEvent.ModifierFlags`' raw value, Fn included.
    public var cocoaFlags: UInt {
        Self.entries.reduce(0) { flags, entry in contains(entry.modifier) ? flags | entry.cocoa : flags }
    }

    // MARK: Carbon

    /// The modifiers in a Carbon modifier mask; the bits that aren't one of the four (Caps Lock, for one) are ignored.
    public init(carbonFlags: UInt32) {
        self = Self.entries.reduce(into: []) { set, entry in
            if let carbon = entry.carbon, carbonFlags & carbon != 0 { set.insert(entry.modifier) }
        }
    }

    /// As a Carbon modifier mask. Fn has no flag there and is left out.
    public var carbonFlags: UInt32 {
        Self.entries.reduce(0) { flags, entry in
            guard let carbon = entry.carbon, contains(entry.modifier) else { return flags }
            return flags | carbon
        }
    }

    // MARK: Glyphs

    /// ⌃⌥⇧⌘ for the modifiers in the set, in that order. Fn isn't shown: it isn't part of what is registered.
    var glyphs: String {
        Self.entries.filter { $0.carbon != nil && contains($0.modifier) }.map(\.glyph).joined()
    }

    // MARK: Names

    /// The set the names stand for, or nil when any of them isn't one of the names this version knows.
    public init?(names: [String]) {
        var set: ModifierSet = []
        for name in names {
            guard let entry = Self.entries.first(where: { $0.name == name }) else { return nil }
            set.insert(entry.modifier)
        }
        self = set
    }

    /// The names in `names` that this version doesn't know, in the order they came.
    public static func unknownNames(in names: [String]) -> [String] {
        names.filter { name in !entries.contains { $0.name == name } }
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var set: ModifierSet = []
        while !container.isAtEnd {
            let name = try container.decode(String.self)
            guard let entry = Self.entries.first(where: { $0.name == name }) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown modifier \"\(name)\"")
            }
            set.insert(entry.modifier)
        }
        self = set
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for entry in Self.entries where contains(entry.modifier) {
            try container.encode(entry.name)
        }
    }
}
