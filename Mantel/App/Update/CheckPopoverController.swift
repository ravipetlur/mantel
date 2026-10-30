import AppKit
import MKUpdate
import SwiftUI

/// The popover that answers a manual check asked from the dots' menu: it hangs just below the dot whose menu it came from and says
/// "Checking for updates…", then what the check found (`CheckAnswer`). It is `.transient`, so a click elsewhere closes it,
/// and an "up to date" closes by itself after a few seconds; a failure stays until OK or a click elsewhere. An update found
/// closes it, and the update window opens.
///
/// Mantel isn't made the active app for it (that would take the keys from the app in front; the update window does it
/// when it opens, as the person asked for it). A transient popover of an inactive app isn't reliably told of a click in
/// another app, so a mouse monitor is, for exactly that.
final class CheckPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = CheckPopoverModel()
    /// Closes an "up to date" popover after its lifetime; replaced by every new answer.
    private var autoClose: Task<Void, Never>?
    /// Sees a click in another app's window, which a transient popover of an inactive app may not.
    private var clickMonitor: Any?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let content = NSHostingController(rootView: CheckPopoverView(model: model, close: { [weak self] in self?.close() }))
        // The popover takes its size from the view: one width, and a height for what it says.
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
    }

    var isShown: Bool { popover.isShown }

    /// Opens the popover under `anchor` (the dot's button), saying "Checking for updates…" at once. Already open,
    /// it starts over with the new check.
    func show(below anchor: NSView) {
        cancelAutoClose()
        model.answer = CheckAnswer(.checking, source: .dotsMenu)
        guard !popover.isShown else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Only a popover that is up has clicks to watch for, and never two monitors at once.
        removeClickMonitor()
        guard popover.isShown else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    /// The check's progress and end, while the popover is up (after a click elsewhere took it down, the answer isn't
    /// wanted any more). An answer with nothing to show (an update found) closes it; "up to date" closes it after its
    /// lifetime.
    func present(_ answer: CheckAnswer) {
        guard popover.isShown else { return }
        cancelAutoClose()
        guard answer.isShown else {
            close()
            return
        }
        model.answer = answer
        if let delay = answer.autoCloseDelay {
            autoClose = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.close()
            }
        }
    }

    /// Takes down a "Checking for updates…" that no answer came to (a result that arrived when no check was running).
    func closeIfPending() {
        if popover.isShown, model.answer.isPending { close() }
    }

    func close() {
        cancelAutoClose()
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        cancelAutoClose()
        removeClickMonitor()
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func cancelAutoClose() {
        autoClose?.cancel()
        autoClose = nil
    }
}
