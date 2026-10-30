import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// What a panel does when a cell is activated (a click, Return or VoiceOver's press): one click at a time goes to the one click driver.
///
/// - **One at a time.** A second press while a click from this panel is still being sent is dropped: a double-click, a click and Return
///   or a held Return would otherwise take the first click's reveal down and make it again, and the first would answer that it couldn't
///   reach the icon.
/// - **The order is the driver's:** the icon is brought to the bar, the panel closes (`beforeClick`, with a reason that doesn't collapse
///   the reveal), the click is sent. Then, when the second bar did close for it, the reveal that showed the cell collapses (not a newer
///   one the person asked for while the click was made, `RevealApplyPolicy.collapsesAfterIconClick`); the icon's own reveal stays while
///   its click holds it. A group panel's click collapses nothing: the reveal it was opened over (or Focus Mode) is the person's, and the
///   clicked icon may be in it. A failure before `beforeClick` (the app isn't running, a refused right click) leaves the panel open under
///   the toast.
@MainActor
final class PanelCellClicks {
    private let environment: PanelEnvironment
    private let origin: ClickOrigin
    private var isSending = false
    private var closedForTheClick = false

    init(environment: PanelEnvironment, origin: ClickOrigin) {
        self.environment = environment
        self.origin = origin
    }

    /// Clicks the entry's icon this way, on this display. `closePanel` closes the panel the click was made in.
    func activate(_ entry: SecondBarEntry, kind: ClickKind, display: String?, closePanel: @escaping @MainActor () -> Void) {
        guard !isSending else { return }
        isSending = true
        closedForTheClick = false
        // The reveal that showed the cell: the collapse after the click is only for that one.
        let stamp = environment.revealStamp()
        Task { [self, environment, origin] in
            await environment.clicker.click(entry.id, kind: kind, title: entry.title, display: display, origin: origin) {
                await self.panelClosesForTheClick(closePanel)
            }
            let closed = closedForTheClick
            isSending = false
            if closed, origin == .secondBar { environment.iconClickSent(stamp) }
        }
    }

    private func panelClosesForTheClick(_ closePanel: @MainActor () -> Void) {
        closedForTheClick = true
        closePanel()
    }
}
