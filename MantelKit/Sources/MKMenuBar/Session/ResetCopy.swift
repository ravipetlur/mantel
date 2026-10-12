import Foundation

/// The words of the question Settings › Diagnostics asks before it resets the menu bar. (The command line asks the same question in its
/// own words, `CLIConfirmation.resetQuestion`.)
public enum ResetCopy {
    public static let alertTitle = "Reset the menu bar?"
    public static let alertText = "Mantel shows every icon, puts back what it changed, and restarts macOS's menu bar. Your sections stay as they are."
    /// The two buttons: the first is the one the Return key presses.
    public static let confirmButton = "Reset"
    public static let cancelButton = "Cancel"
}
