import Carbon.HIToolbox
import MKCore

/// What the keyboard layout in use prints on a key, from `UCKeyTranslate` with the layout of the current input source.
///
/// The Text Input Sources calls are for the main thread, which is where the Hotkeys pane asks. A shortcut is kept as a key
/// code, so the name is looked up each time it is shown and follows the layout the person switches to.
nonisolated struct LiveKeyTranslator: KeyTranslating {
    func character(for keyCode: UInt16) -> String? {
        guard let layout = Self.currentLayoutData() else { return nil }

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            // Display mode with no dead keys: the key as it is printed, without waiting for a second key to combine with.
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length,
                                  &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// The `uchr` data of the current keyboard layout, or of the last ASCII-capable one when the current input source (an
    /// input method, say) has no layout of its own.
    private static func currentLayoutData() -> Data? {
        layoutData(of: TISCopyCurrentKeyboardLayoutInputSource())
            ?? layoutData(of: TISCopyCurrentASCIICapableKeyboardLayoutInputSource())
    }

    /// The layout data of `source`, which this takes over (the copy functions return one that has to be released).
    private static func layoutData(of source: Unmanaged<TISInputSource>?) -> Data? {
        guard let source = source?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        // The data belongs to the source, which goes when this returns, so the bytes are copied.
        return Data(referencing: Unmanaged<NSData>.fromOpaque(property).takeUnretainedValue())
    }
}
