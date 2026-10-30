import Foundation
import MKCore

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

/// What Mantel answers the commands about icons, the second bar, the pictures and the order with. (A person reads these on the command line.)
public extension CommandAnswers {
    /// `mantel icon show`.
    static func iconShown(app: String) -> String {
        "Showing \(app)."
    }

    /// `mantel icon click`: an option click arrives as a plain click (macOS gives an icon no other), and the answer says so.
    static func iconClicked(app: String, kind: ClickKind) -> String {
        kind == .option ? "Clicked \(app) as a left click." : "Clicked \(app)."
    }

    /// What a click that failed says: the sentence, for the app (or system item) whose icon it was.
    static func iconNoRoom(app: String) -> String {
        "There's no room on the menu bar to click \(app)."
    }

    /// The menu bar is hidden by a full-screen app, so a right click or an option click can't be sent.
    static func iconBarHidden(app: String, kind: ClickKind) -> String {
        "The menu bar is hidden by a full-screen app, so \(app) can't be \(kind == .option ? "option" : "right")-clicked."
    }

    static func iconRefused(app: String, text: String) -> String {
        "\(app) didn't respond to the click: \(text)"
    }

    static func iconNotRunning(app: String) -> String {
        "\(app) isn't running."
    }

    static func iconUnreachable(app: String) -> String {
        "Mantel couldn't reach \(app)'s icon."
    }

    /// A newer click took over before this one was sent: nothing was clicked.
    static func iconOvertaken(app: String) -> String {
        "\(app)'s icon wasn't clicked: another click came first."
    }

    /// `mantel bar`: whether the second bar is open now.
    static func bar(isOpen: Bool) -> String {
        isOpen ? "The second bar is open." : "The second bar is closed."
    }

    /// What `mantel recapture` says when the pictures were taken.
    static func recaptured(count: Int) -> String {
        count == 1 ? "Captured 1 icon." : "Captured \(count) icons."
    }

    /// How the collector words a capture that was skipped because Screen Recording is off.
    static let screenRecordingOffReason = "Screen Recording is off"

    /// `mantel recapture` with Screen Recording off: app icons stand in for the pictures.
    static let screenRecordingOff = "Screen Recording is off for Mantel, so app icons stand in. Turn it on in Settings › Permissions."

    /// `mantel layout restore`.
    static let layoutRestored = "The menu bar order is back to how it was."
    static let layoutNothingToRestore = "Nothing to put back: Mantel hasn't changed the order."
    static let layoutNeedsGrant = "Grant access to the layout file in Settings › Layout first."

    static func layoutRestoreFailed(_ text: String) -> String {
        "Couldn't change the menu bar order: \(text)"
    }

    /// What `recapture` answers a command with: the count, or why nothing was captured.
    static func recapture(captured: Int, skipped: String?) -> CommandResult {
        if let skipped {
            if skipped.hasPrefix(screenRecordingOffReason) {
                return .failure(code: .unavailable, message: screenRecordingOff)
            }
            // The collector's reasons have no full stop of their own; the sentence the person reads has one.
            return .failure(code: .unavailable, message: skipped.hasSuffix(".") ? skipped : skipped + ".")
        }
        return .ok(.string(recaptured(count: captured)))
    }
}

/// One icon as `mantel icons` lists it.
public struct IconListRow: Sendable, Equatable {
    /// The icon's ID, in the text form `mantel icon` takes.
    public let id: String
    /// The bundle ID of the app that draws it (the system's for a system item).
    public let app: String
    /// The app's name, or a system item's module's title. Never the icon's own label, which can hold a network's name.
    public let name: String
    /// Shown, hidden or always; nil for an icon in a group.
    public let section: IconListFilter?
    /// The title of the group the icon is in; nil when it is in none.
    public let group: String?
    /// The path of the icon's picture, a PNG; nil when none was taken.
    public let image: String?

    public init(id: String, app: String, name: String, section: IconListFilter?, group: String?, image: String?) {
        self.id = id
        self.app = app
        self.name = name
        self.section = section
        self.group = group
        self.image = image
    }
}

public extension CommandAnswers {
    /// `mantel icons`: the rows that `filter` lets through (all of them for nil), as an array of objects.
    static func iconList(_ rows: [IconListRow], filter: IconListFilter?) -> JSONValue {
        let kept = rows.filter { row in
            switch filter {
            case nil: true
            case .grouped: row.group != nil
            case .some(let section): row.section == section
            }
        }
        return .array(kept.map { row in
            .object(["id": .string(row.id), "app": .string(row.app), "name": .string(row.name),
                     "section": row.section.map { .string($0.rawValue) } ?? .null,
                     "group": row.group.map { .string($0) } ?? .null,
                     "image": row.image.map { .string($0) } ?? .null])
        })
    }
}
