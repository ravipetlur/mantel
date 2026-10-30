import Foundation

/// What MantelTestItem takes the event behind an item's action to be. The action is sent for a click, and also for a press, which comes
/// with no mouse event of its own: the last event the app saw is then an older one, and must not be taken for what was done now. This
/// file holds the rule and nothing else of the app, so that the package's tests can compile it (they link it from here) and check it.
enum ClickEventRule {
    /// The kind of click that goes into the click log.
    enum Kind: String {
        case left, right, option
    }

    /// The event the app had been given last when an item's action ran, reduced to what decides the kind of click.
    struct LastEvent: Equatable {
        enum Button {
            case left, right
        }

        /// Which mouse button went up; nil when the event was something else.
        let mouseUp: Button?
        let isOptionHeld: Bool
        /// The event was sent to the item's own window.
        let isOnTheItem: Bool
        /// How long before now it was dispatched, in seconds.
        let age: TimeInterval
    }

    /// The longest ago an event may have been dispatched and still be the click that sent the action, in seconds.
    static let freshEventAge: TimeInterval = 0.5

    /// The kind of click. The last event counts only when it is a mouse-up on the item's own window that was dispatched within half a second
    /// of now. Anything else is a left click: that is what a press is, whatever the app saw before it. Of an event that counts, a right
    /// mouse-up is a right click, and the Option key held is an option click.
    static func kind(of event: LastEvent?) -> Kind {
        guard let event, event.isOnTheItem, let button = event.mouseUp, event.age <= freshEventAge else { return .left }
        if button == .right { return .right }
        return event.isOptionHeld ? .option : .left
    }
}
