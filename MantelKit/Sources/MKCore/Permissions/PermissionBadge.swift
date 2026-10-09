import Foundation

/// What the Permissions pane writes on a row, and in which colour: the state of one permission in words.
public struct PermissionBadge: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        /// Green.
        case good
        /// Orange: something to do.
        case warning
        /// Grey.
        case neutral
    }

    public let title: String
    public let tone: Tone

    public init(title: String, tone: Tone) {
        self.title = title
        self.tone = tone
    }

    /// Accessibility, Screen Recording and Input Monitoring only say whether access is on (see `PermissionState`), so for
    /// them "not decided" is "Not granted": the person may have denied it or never been asked, and the pane can't tell.
    public static func make(state: PermissionState, kind: PermissionKind) -> PermissionBadge {
        switch state {
        case .granted:
            PermissionBadge(title: "Granted", tone: .good)
        case .denied:
            PermissionBadge(title: "Not granted", tone: .warning)
        case .notDetermined:
            switch kind {
            case .accessibility, .screenRecording, .inputMonitoring:
                PermissionBadge(title: "Not granted", tone: .warning)
            case .microphone, .calendars, .location, .bluetooth, .menuBarLayoutFile, .controlCenterFile, .fullDiskAccess:
                PermissionBadge(title: "Not asked yet", tone: .warning)
            }
        case .unknown:
            PermissionBadge(title: "Unknown", tone: .neutral)
        }
    }
}
