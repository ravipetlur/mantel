import AppKit
import MKCore
import MKMenuBar

/// The alert for Mantel's own missing grant: a click needs it, and the person has to give it. Never two at once: one that is asked for
/// while another is up is dropped.
@MainActor
enum GrantAlert {
    private static var isShowing = false

    static func show(_ content: AlertContent) {
        guard !isShowing else { return }
        isShowing = true
        // Not in the click's own task: the answer of the click doesn't wait for the person. The alert's loop runs from the run loop, not in
        // this task (`ModalLoop`).
        Task {
            defer { isShowing = false }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = content.title
            alert.informativeText = content.text
            alert.addButton(withTitle: content.defaultButton)
            alert.addButton(withTitle: content.cancelButton)
            if await ModalLoop.run(alert) == .alertFirstButtonReturn, let url = SystemSettingsLinks.privacy(.accessibility) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
