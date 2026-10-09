import Foundation
import ServiceManagement

/// Launch at login, as the toggle should show it. Pending approval counts as on: Mantel is registered, and the person
/// still has to approve it in System Settings.
public enum LoginItemState: Sendable, Equatable {
    case enabled, disabled, requiresApproval

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        default: self = .disabled
        }
    }

    public var isOn: Bool { self != .disabled }
}

/// What to tell the person about the login item.
public enum LoginItemFeedback {
    public static let approvalMessage = "Approve Mantel in System Settings › General › Login Items to finish."

    /// What to tell the person after registering or unregistering failed, or nil when the error only
    /// means the item was already in the requested state.
    public static func message(for error: Error) -> String? {
        let code = (error as NSError).code
        switch code {
        case kSMErrorAlreadyRegistered, kSMErrorJobNotFound:
            return nil
        case kSMErrorLaunchDeniedByUser:
            return "Mantel is turned off in System Settings › General › Login Items. Turn it on there to launch at login."
        case kSMErrorInvalidSignature:
            return "macOS rejected Mantel's signature, so it can't launch at login. Reinstall it with make install, then add it in System Settings › General › Login Items if needed."
        default:
            return "macOS couldn't change the login item (error \(code)). Try again, or add Mantel in System Settings › General › Login Items."
        }
    }
}
