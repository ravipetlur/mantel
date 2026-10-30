import Foundation

/// What the mouse did when a dot's button sent its action: the kinds that matter.
public enum DotClickEvent: Sendable, Equatable {
    case leftMouseUp
    /// The right button went up on the dot's own window: the person right-clicked the dot.
    case rightMouseUp
    /// Nothing that is a click on the dot. The app's current event is the last one it retrieved, whatever its kind and wherever it was, so
    /// when an assistive tool presses the button it is some earlier event: a right click on another window, say, is not a right click on
    /// the dot.
    case noMouseEvent
}

/// What a click on a dot does.
public enum DotClickAction: Sendable, Equatable {
    /// Reveal what the dot shows, or put it away again.
    case reveal
    /// Open the menu under the dot.
    case openMenu
}

/// Which clicks on a dot open the menu and which reveal.
///
/// The right button opens the menu, and nothing that opens it ever reveals. Everything else that sends the action is a click on the dot:
/// the left button, and an assistive tool that presses it (which comes with no mouse event of its own). A modifier key changes nothing,
/// so a click with ⌃ held reveals.
public enum DotClickRule {
    /// The longest ago an event may have been dispatched and still be the click that sent the action, in seconds. Long enough for a busy
    /// Mac, where the action can come a second or more after the button went up (a right click taken as too old would reveal instead of
    /// opening the menu), and short enough that the event left over from long before an assistive tool's press isn't taken for it.
    public static let freshEventAge: TimeInterval = 2

    /// What the app's current event makes of the action that arrived. A right click counts only when it is on the dot's own window; a left
    /// click is one wherever its window is. Neither counts when the event was dispatched longer ago than `freshEventAge` (`age`): a press
    /// comes with no event of its own, and the current event is then one from long before it.
    public static func event(isLeftMouseUp: Bool, isRightMouseUp: Bool, isOnTheDotsWindow: Bool, age: TimeInterval) -> DotClickEvent {
        guard age <= freshEventAge else { return .noMouseEvent }
        if isRightMouseUp, isOnTheDotsWindow { return .rightMouseUp }
        if isLeftMouseUp { return .leftMouseUp }
        return .noMouseEvent
    }

    public static func action(for event: DotClickEvent) -> DotClickAction {
        event == .rightMouseUp ? .openMenu : .reveal
    }

    /// What the log says, once a run, when a dot's action arrived with an event that wasn't a click on the dot: it gives the event's type
    /// (`NSEvent.EventType`'s raw value), so that if a click on a dot ever does the wrong thing, the log says what the system sent. Nil
    /// for a click, and for a press that came with no event at all (`typeCode` is nil): those are as expected.
    public static func unexpectedEventLogLine(typeCode: Int?, event: DotClickEvent) -> String? {
        guard let typeCode, event == .noMouseEvent else { return nil }
        return "a dot's action arrived with an event of type \(typeCode), which is no click on the dot"
    }
}
