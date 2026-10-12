/// Keeps track of a dot's menu being asked for, so that a menu that doesn't open is noticed and a click can't start a second ask.
///
/// A right click gives the dot's status item its menu and clicks its button (`performClick`), and the system opens the menu under the
/// dot. Nothing says that it will: if it doesn't, the item would keep its menu, and every left click after that would open it instead of
/// revealing. So the app notes when a menu opens (`menuWillOpen`), and after the ask checks that one did (`hasOpened(since:)`); when none
/// did it takes the menu away again and says so in the log. The check is made twice: `performClick` may return before the menu has begun
/// to track, so a menu that hasn't opened by then is looked for again `recheckDelay` seconds later.
///
/// A status item that has a menu is not supposed to send its action when it is clicked, and the app relies on that, which isn't written
/// down anywhere. If it ever did, the action would come in the middle of the ask and ask again, without end. So a click that arrives while
/// an ask is under way (`isAsking`) is not a click.
public struct DotMenuOpening: Sendable, Equatable {
    /// How long after the ask returns a menu that hasn't opened is looked for again, in seconds.
    public static let recheckDelay: Double = 0.3

    /// What the log says, once for as long as the app runs, when the menu didn't open.
    public static let didNotOpenLogLine = "the status item didn't open the menu"

    /// The state of the count of menus that have opened, when an ask began.
    public struct Ticket: Sendable, Equatable {
        fileprivate let opened: Int
    }

    private var opened = 0
    private var asking = false

    public init() {}

    /// Whether an ask is under way: an action that arrives now is not a click.
    public var isAsking: Bool { asking }

    /// A menu is about to be asked for. The ticket is what `hasOpened(since:)` is asked with; nil when an ask is under way already.
    public mutating func beginAsking() -> Ticket? {
        guard !asking else { return nil }
        asking = true
        return Ticket(opened: opened)
    }

    /// The ask has returned.
    public mutating func endAsking() {
        asking = false
    }

    /// A menu is about to open (the menu's delegate hears it).
    public mutating func menuWillOpen() {
        opened += 1
    }

    /// Whether a menu has opened since the ask the ticket is of began. It has when the ask opened one, however long it took to return
    /// (a menu that is open is tracked inside the ask), and when it opened after the ask had returned.
    public func hasOpened(since ticket: Ticket) -> Bool {
        opened > ticket.opened
    }
}
