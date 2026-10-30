import Foundation

/// What a toast says: an SF Symbol and one line of text.
public struct ToastContent: Sendable, Equatable {
    public let symbol: String
    public let text: String

    public init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }
}

/// The words of the toasts that confirm or report something that needs no action.
public enum ToastCopy {
    /// After the pictures of the icons were taken again.
    public static let iconsCaptured = ToastContent(symbol: "photo.on.rectangle", text: "Icons captured")

    /// What a click that failed says, naming the app (or system item) whose icon it was.
    public static func click(_ failure: IconClickFailure, app: String) -> ToastContent {
        switch failure {
        case .noRoom: ToastContent(symbol: "menubar.rectangle", text: "No room to click \(app)")
        case .refused: ToastContent(symbol: "exclamationmark.triangle", text: "Couldn't click \(app)")
        case .hiddenBar: ToastContent(symbol: "menubar.rectangle", text: "The menu bar is hidden right now")
        case .notRunning: ToastContent(symbol: "xmark.circle", text: "\(app) isn't running")
        case .unreachable: ToastContent(symbol: "questionmark.circle", text: "Couldn't reach \(app)'s icon")
        }
    }

    /// The toast for what the layout writer did between two states, when it failed in a way the person should hear of: once for each
    /// write that ends in `notAccepted` or `failed` (the state it ends in is not pending and carries the error, and the one before it
    /// was pending, carried another, or carried the same from an earlier write: a write that fails fast may never be seen pending, and
    /// `lastErrorAt` tells the two failures apart).
    public static func layout(previous: LayoutStatus?, now: LayoutStatus?) -> ToastContent? {
        guard let now, !now.isPending, let error = now.lastError else { return nil }
        let text: String
        switch error {
        case .notAccepted: text = LayoutWords.notAccepted
        case .failed: text = LayoutWords.couldntChange
        case .needsGrant, .broken: return nil
        }
        // The same error from the same write as before is the one that was already told.
        if let previous, !previous.isPending, previous.lastError == error, previous.lastErrorAt == now.lastErrorAt { return nil }
        return ToastContent(symbol: "exclamationmark.triangle", text: text)
    }
}
