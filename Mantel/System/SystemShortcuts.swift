import Foundation
import MKCore

/// macOS's own keyboard shortcuts, read from System Settings' keyboard preferences.
enum SystemShortcuts {
    /// The shortcuts that are switched on right now. The preferences domain is read, never written, and read afresh on each
    /// call, because the person changes them in System Settings while Mantel runs.
    static func read() -> [SymbolicHotkey] {
        let plist = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return SymbolicHotkeys.parse(plist ?? [:])
    }
}
