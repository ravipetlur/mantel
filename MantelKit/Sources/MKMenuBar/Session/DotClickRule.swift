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
    /// What the app's current event makes of the action that arrived. A right click counts only when it is on the dot's own window; a left
    /// click is one wherever its window is.
    public static func event(isLeftMouseUp: Bool, isRightMouseUp: Bool, isOnTheDotsWindow: Bool) -> DotClickEvent {
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
