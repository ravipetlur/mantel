import Foundation

/// What an alert says: a title, a line of text and the labels of its two buttons (the first is the default).
public struct AlertContent: Sendable, Equatable {
    public let title: String
    public let text: String
    public let defaultButton: String
    public let cancelButton: String

    public init(title: String, text: String, defaultButton: String, cancelButton: String) {
        self.title = title
        self.text = text
        self.defaultButton = defaultButton
        self.cancelButton = cancelButton
    }
}

/// What the person is told about a click, if anything.
public enum ClickNotice: Sendable, Equatable {
    /// A short capsule near the pointer: something happened that needs no action.
    case toast(ToastContent)
    /// An alert: the person has to do something about it (Mantel's own grant is missing).
    case alert(AlertContent)
    /// Nothing is said: the click was made, or the one who asked says it in its own way.
    case nothing

    /// What Mantel says when it can't click an icon for want of its own grant.
    public static let needsGrant = AlertContent(
        title: "Mantel can't click icons",
        text: "Turn on Mantel in System Settings › Privacy & Security › Device control and data access.",
        defaultButton: "Open System Settings", cancelButton: "Cancel")

    /// The notice for what a click came to.
    ///
    /// - A click that was made says nothing.
    /// - A click that another took over says nothing: the newer click is the one that counts.
    /// - While Mantel isn't trusted, every failure but "isn't running" is Mantel's own missing grant (a press is refused, or nothing can
    ///   be found to click at), which the person must act on: an alert.
    /// - Every other failure is a toast naming the app.
    /// - Whoever doesn't want the toasts (a command, which answers in its own words) hears nothing for a failure.
    ///
    /// - Parameters:
    ///   - mantelIsTrusted: whether Mantel has the grant it clicks with. Only asked for a failure.
    ///   - announces: whether a failure is to be told here.
    public static func of(_ outcome: IconClickOutcome, app: String, mantelIsTrusted: () -> Bool, announces: Bool = true) -> ClickNotice {
        guard announces, case .failed(let failure) = outcome else { return .nothing }
        if failure != .notRunning, !mantelIsTrusted() { return .alert(needsGrant) }
        return .toast(ToastCopy.click(failure, app: app))
    }

    /// The notice for an icon that can't be shown: a toast naming the app, never the alert for Mantel's grant, because showing an icon
    /// clicks nothing. Nothing when whoever asked says it in its own words (`announces` false).
    public static func ofShow(_ refusal: IconClickFailure, app: String, announces: Bool = true) -> ClickNotice {
        of(.failed(refusal), app: app, mantelIsTrusted: { true }, announces: announces)
    }
}
