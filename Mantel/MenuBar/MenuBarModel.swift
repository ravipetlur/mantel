import MKLayout
import MKMenuBar
import Observation

/// What the menu bar is like, as the session last said, and what the reveal shows: a copy kept on the main actor for what draws it
/// (the dots now, and the Settings panes). The session and the reveal are where this comes from; nothing here decides anything.
@MainActor
@Observable
final class MenuBarModel {
    /// The last state the session published; nil until it has read the menu bar and applied its first plan.
    private(set) var state: MenuBarState?
    /// What the reveal shows now. The reveal machine is the one that says; this is its state as of the last change it announced.
    private(set) var revealState: RevealState = .collapsed

    /// Called after every change, for whatever has to follow it (the dots are drawn again). Set once, by whoever owns the model.
    @ObservationIgnored var changed: () -> Void = {}

    func apply(_ state: MenuBarState) {
        guard state != self.state else { return }
        self.state = state
        changed()
    }

    func apply(reveal: RevealState) {
        guard reveal != revealState else { return }
        revealState = reveal
        changed()
    }
}
