import Foundation
import MKCommands
import MKCore

/// What the commands answer for a click, in words.
public extension IconClickOutcome {
    /// The answer to `mantel icon click` for the icon of `app` (an app's name, or a system item's), clicked this way.
    func result(app: String, kind: ClickKind) -> CommandResult {
        switch self {
        case .clicked:
            return .ok(.string(CommandAnswers.iconClicked(app: app, kind: kind)))
        case .failed(let failure):
            let text: String
            switch failure {
            case .noRoom: text = CommandAnswers.iconNoRoom(app: app)
            case .hiddenBar: text = CommandAnswers.iconBarHidden(app: app, kind: kind)
            case .refused(let reason): text = CommandAnswers.iconRefused(app: app, text: reason)
            case .notRunning: text = CommandAnswers.iconNotRunning(app: app)
            case .unreachable: text = CommandAnswers.iconUnreachable(app: app)
            }
            return .failure(code: .failed, message: text)
        case .overtaken:
            // A newer click (a panel's, a hotkey's or another command's) took over before this one was sent.
            return .failure(code: .failed, message: CommandAnswers.iconOvertaken(app: app))
        }
    }
}

/// What `mantel layout restore` answers for what the writer did.
public extension Result where Success == Int, Failure == LayoutWriteError {
    /// The answer: the order is back, nothing was there to put back, or why it couldn't be.
    var restoreResult: CommandResult {
        switch self {
        case .success(let count):
            return .ok(.string(count > 0 ? CommandAnswers.layoutRestored : CommandAnswers.layoutNothingToRestore))
        case .failure(.needsGrant):
            return .failure(code: .unavailable, message: CommandAnswers.layoutNeedsGrant)
        case .failure(let error):
            return .failure(code: .failed, message: CommandAnswers.layoutRestoreFailed(error.restoreWords))
        }
    }
}

extension LayoutWriteError {
    /// Why the order couldn't be put back, for the end of a sentence. (The detail of a write that failed is for the log, unless it is the
    /// reason the write was held.)
    var restoreWords: String {
        switch self {
        case .needsGrant: LayoutWords.needsGrant
        case .broken(let text): text
        case .notAccepted: "macOS didn't accept the old order."
        case .failed(let text): LayoutHold.reasons.contains(text) ? text : "macOS didn't take the change."
        }
    }
}
