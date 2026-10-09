import Foundation

/// Links into System Settings (`x-apple.systempreferences:`): the panes for Mantel's permissions, and Keyboard.
public enum SystemSettingsLinks {
    public static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// The Privacy & Security pane for `kind`, or nil for the two file grants, which have no pane: the person picks the
    /// file instead.
    public static func privacy(_ kind: PermissionKind) -> URL? {
        let anchor: String? = switch kind {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        case .calendars: "Privacy_Calendars"
        case .location: "Privacy_LocationServices"
        case .bluetooth: "Privacy_Bluetooth"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .menuBarLayoutFile, .controlCenterFile: nil
        }
        return anchor.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
    }
}
