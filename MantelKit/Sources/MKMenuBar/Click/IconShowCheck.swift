import Foundation
import MKCore

/// Whether an icon can be shown at all: the questions the click path asks before it reveals anything (`IconClickDriver.click`), asked for a
/// show too, so that `mantel icon show` and an icon's `.show` hotkey never say "showing" for an icon that nothing will draw.
public enum IconShowCheck {
    /// Why the icon can't be shown, or nil when it can.
    ///
    /// - An app that has no process and that the last read lists nothing of isn't running.
    /// - A system item that the plan in force takes off the bar can't be reached: macOS never draws it for a reveal.
    /// - Nor can an app that is never drawn: macOS doesn't tie its icon to it, or the person turned it off in System Settings › Menu Bar.
    /// - Nor an icon that its app doesn't list now (`MenuBarSession.hasNoSuchIcon`): there is nothing to show.
    ///
    /// - Parameters:
    ///   - hasProcess: whether a process owns the app's items (`MenuBarSession.extrasOwnerPID`); not asked for a system item.
    ///   - hasItems: whether the last read lists an item of the app (it is running, or was).
    ///   - planConceals: whether the plan in force keeps the item off the bar (`MenuBarSession.planConceals`).
    ///   - neverDrawn: whether the app is never drawn (`MenuBarSession.isUnattached`, `isTurnedOff`); not asked for a system item.
    ///   - noSuchIcon: whether the app doesn't list the icon (`MenuBarSession.hasNoSuchIcon`); not asked for a system item.
    public static func refusal(for item: ItemID, hasProcess: Bool, hasItems: Bool, planConceals: Bool,
                               neverDrawn: Bool = false, noSuchIcon: Bool = false) -> IconClickFailure? {
        if item.isSystem { return planConceals ? .unreachable : nil }
        guard hasProcess || hasItems else { return .notRunning }
        return neverDrawn || noSuchIcon ? .unreachable : nil
    }
}
