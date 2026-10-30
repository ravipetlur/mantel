import Foundation
import MKCore
import MKLayout

/// When Mantel may take the menu bar over to make room for revealed icons (the policy that hides the front app's menus).
public enum MenuBarTakeoverPolicy {
    /// The log line for a takeover that was left alone.
    public static let skippedLogLine = "no menu bar to make room in"
    /// The log line for a takeover that was begun and never got Mantel to the front.
    public static let couldNotActivateLogLine = "couldn't become the front app to make room"

    /// What is done once the takeover has been begun and Mantel has had its time to become the active app.
    public enum AfterBegin: Sendable, Equatable {
        /// Mantel is the front app and the front app's menus are off the bar: the room is looked at again.
        case recheckRoom
        /// Mantel never became the front app (macOS lets an app come forward only when it is willing, and one that wasn't asked by a click
        /// often isn't): the menus are still on the bar, so the takeover is undone without giving the focus anywhere, and what has no room
        /// stays in the « menu, as the second-bar policy leaves it.
        case undo(NoRoomAction)
        /// The takeover was ended while it was being begun (the second bar opened, which gives the menu bar back; the person went to another
        /// app; the reveal was put away; or Mantel is quitting): there is nothing to look at again and nothing to undo.
        case endedMeanwhile
    }

    /// - Parameters:
    ///   - activated: whether Mantel is the active app now; nil when the takeover was ended while it was being begun.
    ///   - overflowAlreadyLogged: whether the log has said, during this run, that the « menu keeps the revealed icons.
    public static func afterBegin(activated: Bool?, overflowAlreadyLogged: Bool) -> AfterBegin {
        guard let activated else { return .endedMeanwhile }
        return activated ? .recheckRoom : .undo(.leaveOverflow(logOnce: !overflowAlreadyLogged))
    }

    /// Whether there is a menu bar to make room in: the bar of the display the front app is on is on screen. A full-screen app hides
    /// its bar, and there are then no menus of the app to clear, so the takeover would change nothing but the Dock.
    ///
    /// - `frontDisplay`: the display the front app is on (`MenuBarGeometry.displayUUID`), when it is known. When it isn't, or no bar
    ///   is for it, any bar being on screen is enough.
    public static func hasBarToClear(frontDisplay: String?, shownBars: Set<String>, bars: [MenuBarGeometry]) -> Bool {
        guard !bars.isEmpty else { return false }
        if let frontDisplay, bars.contains(where: { $0.displayUUID == frontDisplay }) {
            return shownBars.contains(frontDisplay)
        }
        return !shownBars.isEmpty
    }

    /// Whether an app coming to the front is the front app as far as the session goes. Mantel is, while it has taken the menu bar over
    /// (its own menu is on the bar then, and the room it left is what the icons are given). Otherwise Mantel is only a window that has
    /// the focus for a while, and the person goes back to the app they were in: the menus the session knows are that app's, and
    /// reading Mantel's short one would have automatic overflow try icons into room that is gone when they return.
    public static func reportsFrontApp(activated: pid_t, own: pid_t, takeoverActive: Bool) -> Bool {
        activated != own || takeoverActive
    }
}
