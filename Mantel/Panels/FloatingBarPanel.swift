import AppKit

/// The window the second bar, a group's panel and the command bar are shown in: it floats above the menu bar's own windows on every Space
/// and over full-screen apps, and never makes Mantel the active app.
///
/// - **Non-activating.** Clicking a cell, or making the panel key for the keyboard, leaves the front app where it is, so its menus stay
///   in the bar. Nothing here calls `NSApp.activate`.
/// - **Key only when asked.** `canBecomeKey` is true so that a panel opened by a click or a hotkey can take the arrow keys, but a panel is
///   made key (`makeKey`) only by whoever opens it for the keyboard: one opened by a hover, a scroll or a command never takes what the
///   person is typing.
/// - **Not in screenshots or screen shares** (`sharingType`), and not in the window cycle.
final class FloatingBarPanel: NSPanel {
    /// One above the menu bar's own level, so that the panel is drawn over the bar's windows.
    static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = Self.panelLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
    }
}
