import CoreGraphics
import Foundation

/// What the list of windows on screen says about the menu an icon opens.
///
/// An icon's menu is a window of its app's, drawn above the menu bar. Which level it is at isn't assumed here: the caller says the lowest
/// level that counts, from what it has measured, so that a window the app keeps in the bar's own level (a tooltip, a badge) isn't taken
/// for a menu.
public enum MenuWindows {
    /// The windows of `pid` that are on screen and can be seen (`alpha` above zero) at `minimumLayer` or higher, that `after` has and
    /// `before` hadn't (by window number): what opened between two looks. In the order `after` lists them.
    public static func opened(by pid: pid_t, before: [WindowInfo], after: [WindowInfo], minimumLayer: Int) -> [WindowInfo] {
        let known = Set(before.map(\.number))
        return after.filter { isMenuCandidate($0, of: pid, minimumLayer: minimumLayer) && !known.contains($0.number) }
    }

    /// Whether `pid` has a window on screen that can be seen at `minimumLayer` or higher.
    public static func isOpen(by pid: pid_t, in windows: [WindowInfo], minimumLayer: Int) -> Bool {
        windows.contains { isMenuCandidate($0, of: pid, minimumLayer: minimumLayer) }
    }

    private static func isMenuCandidate(_ window: WindowInfo, of pid: pid_t, minimumLayer: Int) -> Bool {
        window.ownerPID == pid && window.alpha > 0 && window.layer >= minimumLayer
    }
}
