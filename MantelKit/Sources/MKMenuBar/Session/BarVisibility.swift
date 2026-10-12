import CoreGraphics
import MKCore

/// Which displays' menu bars are on screen now.
///
/// A bar is hidden when a full-screen app has the display (and the pointer pulls it down for a moment when it is brought back). The
/// bar's own window, at the main menu's level, is what the window server keeps on screen exactly while the bar is shown: when a
/// full-screen app hides the bar the window leaves the list of windows on screen, and when the pointer brings the bar down it comes
/// back. The window server owns it, and it has no bundle ID: it is told by its level, its place and that it has no bundle ID. A window
/// of an app that is as big as the bar and at the main menu's level (a menu bar of the app's own, say) is not the bar.
public enum BarVisibility {
    /// How far the window's edges may be inside the bar's rectangle for it still to cover it: the window and the rectangle MenuBarAgent
    /// reports for the bar are not the same to the point.
    public static let tolerance: CGFloat = 2

    /// The displays (`MenuBarGeometry.displayUUID`) whose bar is on screen: those that have a window at the main menu's level
    /// (`WindowLevels.mainMenu`) among `windows`, which are the windows that are on screen, with no bundle ID for an owner (the window
    /// server's), covering the bar's rectangle (CoreGraphics points) to within `tolerance`.
    public static func shownBars(_ windows: [WindowInfo], bars: [MenuBarGeometry]) -> Set<String> {
        let candidates = windows.filter { $0.layer == WindowLevels.mainMenu && $0.ownerBundleID == nil }
        guard !candidates.isEmpty else { return [] }
        return Set(bars.filter { bar in
            let wanted = bar.rect
            return candidates.contains { $0.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(wanted) }
        }.map(\.displayUUID))
    }
}
