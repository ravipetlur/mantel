import Foundation

/// What Mantel answers a command with when it has done it. (A person reads these on the command line.)
public enum CommandAnswers {
    /// `mantel show`: what was done.
    public static func show(_ target: ShowTarget) -> String {
        switch target {
        case .hidden: "Showing hidden icons."
        case .all: "Showing all icons."
        case .nothing: "Hiding icons again."
        }
    }

    /// `mantel focus`: how Focus Mode is now (after a toggle, which it is is only known afterwards).
    public static func focus(isOn: Bool) -> String {
        isOn ? "Focus Mode is on." : "Focus Mode is off."
    }

    /// `mantel refresh`.
    public static let refreshed = "Menu bar refreshed."

    /// `mantel reset`, when it is done.
    public static let reset = "Menu bar reset."

    /// `mantel reset`, asked while another reset is still running; and `mantel refresh`, asked during one.
    public static let resetUnderWay = "A reset is already under way."

    /// A command that changes the menu bar, asked once Mantel has begun to quit.
    public static let quitting = "Mantel is quitting."

    /// A command that needs the menu bar, asked while Mantel is still starting.
    public static let stillStarting = "Mantel is still starting. Try again in a moment."
}

/// How a reset of the menu bar came out, and what the commands and Settings say of it.
public enum ResetOutcome: Sendable, Equatable {
    /// Everything was put back, the menu bar was restarted, and hiding is going again.
    case done
    /// Another reset was still running, and this one wasn't started.
    case alreadyUnderWay
    /// It wasn't started, and nothing was changed: the sentence says why (a platform test is changing the menu bar, Mantel is quitting).
    case refused(String)
    /// It was started and stopped, and everything is shown: the sentence says what happened and what to do.
    case failed(String)

    /// What the person is told.
    public var message: String {
        switch self {
        case .done: CommandAnswers.reset
        case .alreadyUnderWay: CommandAnswers.resetUnderWay
        case .refused(let message), .failed(let message): message
        }
    }

    /// What `reset` answers a command with.
    public var result: CommandResult {
        switch self {
        case .done: .ok(.string(CommandAnswers.reset))
        case .alreadyUnderWay: .failure(code: .unavailable, message: CommandAnswers.resetUnderWay)
        case .refused(let message): .failure(code: .unavailable, message: message)
        case .failed(let message): .failure(code: .failed, message: message)
        }
    }
}

/// How a refresh of the menu bar came out: it was made, or it wasn't, and the sentence says why.
public enum RefreshOutcome: Sendable, Equatable {
    case done
    /// Nothing was refreshed (a reset is under way, Mantel is quitting).
    case refused(String)

    /// What the person is told.
    public var message: String {
        switch self {
        case .done: CommandAnswers.refreshed
        case .refused(let message): message
        }
    }

    /// What `refresh` answers a command with.
    public var result: CommandResult {
        switch self {
        case .done: .ok(.string(CommandAnswers.refreshed))
        case .refused(let message): .failure(code: .unavailable, message: message)
        }
    }
}
