import Foundation

/// What holds the relaunch off once the new app is in place. The relaunch quits Mantel (`AppQuit.request()`), which puts back
/// every hidden icon and writes an order change that is still held, as any quit does; two things it mustn't cut off are
/// waited for first:
///
/// - **An open alert, sheet or open panel.** The person is answering it, and the quit would end it with the answer a quit gives.
///   That is an app-modal alert, a sheet attached to any window (Settings' alerts and its relaunch sheet) and a panel that is
///   showing (the file-grant panel). It is waited for for as long as it is open, which is what the window says
///   (`InstallFlow.restartWaitingText`).
/// - **A change of the menu bar's order being written, or checked on the bar.** A quit within its limit flushes one that is
///   still waiting, but can't call back one whose write has begun. This wait is short and has a limit (`layoutLimit`): a
///   write that is held for something else never keeps the update from finishing.
public enum RelaunchWait {
    /// The longest the relaunch waits for the order of the menu bar to be written.
    public static let layoutLimit: TimeInterval = 20

    /// Whether the relaunch has to wait now. `layoutWaited` is how long it has already waited for a write of the order.
    public static func mustWait(dialogIsOpen: Bool, layoutWriteIsUnderWay: Bool, layoutWaited: TimeInterval) -> Bool {
        dialogIsOpen || (layoutWriteIsUnderWay && layoutWaited < layoutLimit)
    }
}
