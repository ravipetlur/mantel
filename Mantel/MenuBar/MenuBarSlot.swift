import Observation

/// Where the menu bar controller is kept once it exists, so that what draws from it (Settings' panes) is told when it arrives. The
/// coordinator makes the controller at a step of the launch, and Settings can be open before that: a pane that read it as nil must
/// draw again when there is one.
@MainActor
@Observable
final class MenuBarSlot {
    private(set) var controller: MenuBarController?

    func set(_ controller: MenuBarController?) {
        self.controller = controller
    }
}
