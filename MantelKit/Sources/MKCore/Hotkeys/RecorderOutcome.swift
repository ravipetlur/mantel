/// What the recorder does with a key pressed while it listens.
///
/// The recorder itself is a SwiftUI control with an event monitor, which is checked by hand; the decision is here so that
/// it can be tested.
public enum RecorderOutcome: Sendable, Equatable {
    /// Esc: stop recording and leave the shortcut as it was.
    case cancel
    /// Delete: stop recording and remove the shortcut.
    case clear
    /// Anything else: this is the shortcut. It may still be refused (`HotkeyClash.noModifier`), which is the pane's call.
    case record(KeyCombo)

    /// The outcome of the key `keyCode` going down with `cocoaFlags` (`NSEvent.ModifierFlags`' raw value) held.
    ///
    /// Esc and Delete (either one) are commands only on their own. With a modifier they are shortcuts like any other (⌘Delete
    /// is a fine shortcut). Fn doesn't count as a modifier here: Forward Delete and the arrows report it without it being
    /// held. The combo that is recorded is what was heard, Fn included; leaving it out is for whoever registers it.
    public static func forKeyDown(keyCode: UInt16, cocoaFlags: UInt) -> RecorderOutcome {
        let modifiers = ModifierSet(cocoaFlags: cocoaFlags)
        if modifiers.subtracting(.function).isEmpty {
            switch keyCode {
            case KeyCode.escape: return .cancel
            case KeyCode.delete, KeyCode.forwardDelete: return .clear
            default: break
            }
        }
        return .record(KeyCombo(keyCode: keyCode, modifiers: modifiers))
    }
}
