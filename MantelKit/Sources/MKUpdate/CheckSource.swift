import CoreGraphics

/// Where a manual check was asked from, and so where its answer appears. A background check has no source: it says
/// nothing unless it finds an update.
public enum CheckSource: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The dots' menu's "Check for Updates…": the answer is a popover under the dot whose menu it came from.
    case dotsMenu
    /// Settings › About's Check Now: the answer is a line under the button.
    case settings

    /// What the log calls it.
    public var logName: String {
        switch self {
        case .dotsMenu: "dots menu"
        case .settings: "settings"
        }
    }

    /// The source whose surface the answer goes to. A check from the dots' menu answers under the dot; when the dot can't be
    /// pointed at (off the bar, in the menu bar's overflow, or the menu came from the shortcut) it answers in Settings › About
    /// instead, which opens for it. Never a floating message with nothing to hold it.
    public func answering(anchorIsUsable: Bool) -> CheckSource {
        switch self {
        case .dotsMenu: anchorIsUsable ? .dotsMenu : .settings
        case .settings: .settings
        }
    }
}

/// Whether a dot is somewhere a popover can hang from.
public enum DotAnchor {
    /// True when the item is on the bar and its button's window has its middle on a screen. The menu bar's overflow (a full
    /// menu bar, or the notch) leaves a status item's window off every screen, and a dot that is off the bar has none to point
    /// at. All frames are in screen coordinates.
    public static func isUsable(itemIsVisible: Bool, buttonFrame: CGRect?, screenFrames: [CGRect]) -> Bool {
        guard itemIsVisible, let buttonFrame, !buttonFrame.isNull, !buttonFrame.isEmpty else { return false }
        let middle = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return screenFrames.contains { $0.contains(middle) }
    }
}
