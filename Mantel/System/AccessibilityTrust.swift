import AppKit
import ApplicationServices
import MKCore

/// Asking for Accessibility, which Mantel needs to read the menu bar and click its icons.
enum AccessibilityTrust {
    /// Whether Mantel is trusted now. It never shows anything.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Has macOS show its own Accessibility prompt (it asks once for a build) and opens the Accessibility pane of
    /// Privacy & Security, where the person switches Mantel on.
    static func promptAndOpenSettings() {
        // The key is `kAXTrustedCheckOptionPrompt`, a global variable, which strict concurrency won't let this read.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = SystemSettingsLinks.privacy(.accessibility) {
            NSWorkspace.shared.open(url)
        }
    }
}
