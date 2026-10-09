import Foundation

/// What Mantel may need to be allowed, one entry for each row of the Permissions pane. Eight are System Settings
/// privacy switches; the other two, `menuBarLayoutFile` and `controlCenterFile`, are files the person picks once (see
/// `FileGrantStore`).
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case accessibility, screenRecording, inputMonitoring, microphone, calendars, location, bluetooth,
         menuBarLayoutFile, controlCenterFile, fullDiskAccess

    /// The file grant this permission is, for the two that are one; nil for the privacy switches.
    public var fileGrantKind: FileGrantKind? {
        switch self {
        case .menuBarLayoutFile: .menuBarLayout
        case .controlCenterFile: .controlCenterApprovals
        case .accessibility, .screenRecording, .inputMonitoring, .microphone, .calendars, .location, .bluetooth,
             .fullDiskAccess:
            nil
        }
    }
}

/// Where a permission stands.
///
/// macOS can't always tell "denied" from "never asked" (Accessibility, Screen Recording and Input Monitoring only say
/// whether access is on), and has no check at all for Full Disk Access: those report `.notDetermined` until granted,
/// and `.unknown` for the one that can't be told.
public enum PermissionState: String, Codable, Sendable {
    case granted, denied, notDetermined, unknown
}
