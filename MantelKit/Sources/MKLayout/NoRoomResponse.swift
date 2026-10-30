import CoreGraphics
import MKCore

/// What a look at the bar after a reveal found: the revealed apps whose icons are piled in the « overflow or hidden by the notch.
public struct RoomCheck: Sendable, Equatable {
    /// The apps among those revealed that have no room on the bar.
    public var overflowedRevealedApps: Set<String>
    /// How much more room the revealed icons need, in points.
    public var neededWidth: CGFloat
    /// How many times room has been made for this reveal already: 0 for the first look.
    public var round: Int

    public init(overflowedRevealedApps: Set<String>, neededWidth: CGFloat, round: Int) {
        self.overflowedRevealedApps = overflowedRevealedApps
        self.neededWidth = neededWidth
        self.round = round
    }
}

/// What to do about revealed icons that don't fit.
public enum NoRoomAction: Sendable, Equatable {
    /// They fit, or there is nothing to do.
    case none
    /// Leave them in the « menu, and log it (`NoRoomResponse.overflowLogLine`) if `logOnce` says nobody has yet. What is left to do once
    /// the menu bar was taken over and the icons still don't fit.
    case leaveOverflow(logOnce: Bool)
    /// Show the revealed icons in the second bar instead, and put the menu bar back to what the sections say. Said of a reveal that was
    /// shown inline and didn't fit: the prediction that it would (`RoomPrediction`) was wrong, and this corrects it.
    case openSecondBar
    /// Conceal Shown apps, right-most first, to make room; this is the round that is about to be tried.
    case swap(round: Int)
    /// Stop trying. The text is for the log, it is never shown.
    case giveUp(String)
    /// Make Mantel the active app with a menu of its own, which clears the bar of the front app's menus.
    case takeOverMenuBar
}

/// Chooses what to do when revealed icons don't fit on the bar, by the person's no-room policy.
public enum NoRoomResponse {
    /// The log line for revealed icons that are left in the « menu: what is said when the menu bar was taken over and they still don't fit.
    public static let overflowLogLine = "no room for the revealed icons; macOS's « menu keeps them"
    /// The log line for a swap that has tried as often as it may.
    public static let giveUpText = "Couldn't make room for every hidden icon."

    /// - Parameters:
    ///   - alreadyLogged: whether the line about leaving icons in the « menu has been logged during this run.
    ///   - menuBarTakenOver: whether Mantel already has the menu bar for itself.
    public static func decide(policy: NoRoomPolicy, check: RoomCheck, alreadyLogged: Bool, menuBarTakenOver: Bool) -> NoRoomAction {
        guard !check.overflowedRevealedApps.isEmpty else { return .none }
        switch policy {
        case .secondBar:
            return .openSecondBar
        case .swap:
            return check.round < SwapCalculator.maximumRounds ? .swap(round: check.round) : .giveUp(giveUpText)
        case .hideAppMenus:
            return menuBarTakenOver ? .leaveOverflow(logOnce: !alreadyLogged) : .takeOverMenuBar
        }
    }
}
