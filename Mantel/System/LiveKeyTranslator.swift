import Carbon.HIToolbox
import MKCore

/// What the keyboard layout in use prints on a key, from `UCKeyTranslate` with the layout of the current input source.
///
/// The Text Input Sources calls are for the main thread, so this is on the main actor, which is where the Hotkeys pane asks. A
/// shortcut is kept as a key code, so the name is looked up each time it is shown and follows the layout the person switches to.
@MainActor
struct LiveKeyTranslator: KeyTranslating {
    func character(for keyCode: UInt16, options: KeyTranslationOptions) -> String? {
        guard let layout = Self.currentLayoutData() else { return nil }

        // `UCKeyTranslate` takes a mask of options. `kUCKeyTranslateNoDeadKeysBit` is the number of the bit, which is 0: passed as
        // the options it asks for nothing, so the mask is `1 << kUCKeyTranslateNoDeadKeysBit`.
        let translateOptions: OptionBits = options.contains(.noDeadKeys) ? OptionBits(1 << kUCKeyTranslateNoDeadKeysBit) : 0
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            // Display mode, so that the key is shown as it is printed.
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  translateOptions, &deadKeyState, characters.count, &length, &characters)
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
