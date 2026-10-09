import Foundation

/// What the Permissions pane and onboarding say about one permission: its name, why Mantel needs it, and where in System
/// Settings to switch it on.
public struct PermissionInfo: Sendable, Equatable {
    public let kind: PermissionKind
    /// The name of the row, such as "Accessibility".
    public let title: String
    /// One sentence on what the person gets from allowing it.
    public let reason: String
    /// The System Settings pane to open. Nil for the two file grants, which are given by choosing the file in an open panel.
    public let settingsURL: URL?

    public static func info(for kind: PermissionKind) -> PermissionInfo {
        let (title, reason): (String, String) = switch kind {
        case .accessibility:
            ("Accessibility", "Mantel reads your menu bar and clicks its icons for you.")
        case .screenRecording:
            ("Screen Recording", "Shows real icon pictures instead of app icons.")
        case .inputMonitoring:
            ("Input Monitoring", "Lets a modifier key on its own work as push-to-talk.")
        case .microphone:
            ("Microphone", "Needed for the AirPods squeeze and the level meter.")
        case .calendars:
            ("Calendars", "Shows your next meetings in the top shelf.")
        case .location:
            ("Location", "macOS shows Wi-Fi network names only to apps with Location.")
        case .bluetooth:
            ("Bluetooth", "Shows your AirPods and other devices' battery.")
        case .menuBarLayoutFile:
            ("Menu bar layout", "Lets Mantel put your icons in the order you choose.")
        case .controlCenterFile:
            (#""Allow in the Menu Bar" list"#, "Keeps the mic indicator visible during calls.")
        case .fullDiskAccess:
            ("Full Disk Access", "Optional: covers both files above in one step.")
        }
        return PermissionInfo(kind: kind, title: title, reason: reason, settingsURL: SystemSettingsLinks.privacy(kind))
    }
}
