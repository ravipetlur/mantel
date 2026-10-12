import CoreGraphics
import Foundation
import MKCore

/// Whether Notification Center, which the clock opens, is open: told from the window list. While it is open it has a window that
/// covers a whole display, one level above the main menu's; while it is closed it has none, and its widgets and banners are windows of
/// other sizes or at other levels.
public enum OpenedSystemUI {
    /// The app whose panel counts: Notification Center. (Control Center's clicks work while an allowlist is live, so its pop-ups are
    /// not asked about.)
    public static let owners: Set<String> = ["com.apple.notificationcenterui"]

    /// The lowest level the panel's window is at: it is at 21 on macOS 27, which is above every ordinary window, and what is below it is
    /// a widget.
    public static let lowestLayer = 20

    /// The share of a display a window has to cover to be the panel, and not a banner or a widget.
    public static let coverage = 0.9

    /// True when one of `windows` (the ones on screen) belongs to one of the `owners`, is at `lowestLayer` or above, can be seen
    /// (`alpha` above zero), and covers at least `coverage` of the frame of one of `displays` (CoreGraphics points, as the window
    /// list gives bounds).
    public static func isOpen(_ windows: [WindowInfo], displays: [CGRect]) -> Bool {
        windows.contains { window in
            guard let owner = window.ownerBundleID, owners.contains(owner), window.layer >= lowestLayer, window.alpha > 0 else { return false }
            return displays.contains { covers(window.bounds, $0) }
        }
    }

    /// `isOpen(_:displays:)` for the displays of `layout`, whose frames are AppKit's (the origin at the main display's bottom-left
    /// corner, y up) and are turned into CoreGraphics points here, which is what the window list's bounds are in.
    public static func isOpen(_ windows: [WindowInfo], layout: DisplayLayout) -> Bool {
        isOpen(windows, displays: layout.displays.map { layout.cgRect(fromAppKit: $0.frame) })
    }

    /// Whether `bounds` covers at least `coverage` of `display`. A display with no area is never covered.
    private static func covers(_ bounds: CGRect, _ display: CGRect) -> Bool {
        let area = display.width * display.height
        guard area > 0 else { return false }
        let overlap = bounds.intersection(display)
        guard !overlap.isNull else { return false }
        return overlap.width * overlap.height >= coverage * area
    }
}
