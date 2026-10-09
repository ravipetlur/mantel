/// Virtual key codes (`kVK_*` in HIToolbox's Events.h): the number a key has whatever the keyboard layout. They are fixed
/// by the hardware's key positions, which is why a shortcut is kept as a key code and its name is looked up each time.
///
/// Only the keys the package itself needs to know are here; every other key is a number the keyboard reported.
public enum KeyCode {
    public static let a: UInt16 = 0
    public static let j: UInt16 = 38
    public static let k: UInt16 = 40

    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    /// The key that is called Delete on a Mac keyboard and deletes backwards.
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126

    public static let f1: UInt16 = 122
    public static let f2: UInt16 = 120
    public static let f3: UInt16 = 99
    public static let f4: UInt16 = 118
    public static let f5: UInt16 = 96
    public static let f6: UInt16 = 97
    public static let f7: UInt16 = 98
    public static let f8: UInt16 = 100
    public static let f9: UInt16 = 101
    public static let f10: UInt16 = 109
    public static let f11: UInt16 = 103
    public static let f12: UInt16 = 111
    public static let f13: UInt16 = 105
    public static let f14: UInt16 = 107
    public static let f15: UInt16 = 113
    public static let f16: UInt16 = 106
    public static let f17: UInt16 = 64
    public static let f18: UInt16 = 79
    public static let f19: UInt16 = 80
    public static let f20: UInt16 = 90

    /// F1 to F20 in order: the index plus one is the number on the key.
    static let functionKeys: [UInt16] = [
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20,
    ]

    /// The key code of each of F1 to F20, to the number on it.
    static let functionKeyNumbers: [UInt16: Int] = Dictionary(
        uniqueKeysWithValues: functionKeys.enumerated().map { ($0.element, $0.offset + 1) }
    )

    /// What the keys that no layout prints are called.
    static let specialNames: [UInt16: String] = [
        returnKey: "Return", tab: "Tab", space: "Space", delete: "Delete", escape: "Esc", forwardDelete: "Forward Delete",
        home: "Home", end: "End", pageUp: "Page Up", pageDown: "Page Down",
        leftArrow: "←", rightArrow: "→", downArrow: "↓", upArrow: "↑",
    ]
}
