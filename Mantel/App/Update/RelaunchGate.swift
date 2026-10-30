import AppKit
import MKUpdate

/// Holds the relaunch off while something is in its way (`RelaunchWait` says what): an alert, a sheet or an open panel that is up, and a change
/// of the menu bar's order that is being written. The relaunch quits Mantel, and a quit ends an alert with the answer a quit gives.
@MainActor
final class RelaunchGate {
    /// Told when the relaunch starts waiting for an open dialog and when it stops, so that the update window can say so.
    var dialogWaitChanged: (Bool) -> Void = { _ in }
    /// Whether the order of the menu bar is being written or settling, from the menu bar controller; none before it is made.
    var layoutWriteIsUnderWay: () async -> Bool = { false }

    private static let pause: Duration = .milliseconds(500)

    /// An app-modal alert (`NSApp.modalWindow`), a sheet on any window (Settings' alerts and its relaunch sheet) or an open panel
    /// that is showing (the file-grant panel, which isn't modal).
    private static var aDialogIsOpen: Bool {
        NSApp.modalWindow != nil
            || NSApp.windows.contains { $0.attachedSheet != nil || ($0 is NSOpenPanel && $0.isVisible) }
    }

    /// Returns once nothing is in the relaunch's way. A cancelled wait returns at once, so that what is stopping the work (the
    /// app is quitting) isn't held up by it.
    func waitUntilQuiet() async {
        var layoutWaited: TimeInterval = 0
        var saidWaiting = false
        defer { if saidWaiting { dialogWaitChanged(false) } }
        while true {
            let dialog = Self.aDialogIsOpen
            let layout = await layoutWriteIsUnderWay()
            guard RelaunchWait.mustWait(dialogIsOpen: dialog, layoutWriteIsUnderWay: layout, layoutWaited: layoutWaited) else { return }
            if dialog, !saidWaiting {
                saidWaiting = true
                dialogWaitChanged(true)
            } else if !dialog, saidWaiting {
                saidWaiting = false
                dialogWaitChanged(false)
            }
            do {
                try await Task.sleep(for: Self.pause)
            } catch {
                return
            }
            if layout { layoutWaited += 0.5 }
        }
    }
}
