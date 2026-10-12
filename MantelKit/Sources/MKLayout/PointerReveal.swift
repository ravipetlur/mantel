import CoreGraphics
import MKCore

/// What the pointer on the menu bar says to the reveal: which of its movements, clicks and scrolls are events for the machine
/// (`RevealMachine` then decides whether the person turned each kind on).
///
/// The place is a `EmptySpace.Spot`: the pointer is classified once, where the event happened, and only the empty part of a bar that
/// is on screen asks for anything. A click on an icon or on the front app's menus, or a pointer pushed against the top of a screen
/// whose bar a full-screen app has hidden, is never a request to reveal.
public enum PointerReveal {
    /// How far a scroll has to go to count, in the units `NSEvent.deltaY` gives (lines): a smaller one is a hand resting on the pad.
    public static let scrollThreshold: CGFloat = 3

    /// What the pointer did, at the place `events(for:from:to:)` is given.
    public enum Action: Sendable, Equatable {
        case moved
        case clicked
        /// A scroll by `deltaY`, with `invertedFromDevice` as the event says it (natural scrolling is on).
        case scrolled(deltaY: CGFloat, invertedFromDevice: Bool)
    }

    /// Everything that an action at `new` says to the reveal, in the order it is to be sent. The pointer has to be known to be where the
    /// action happened first, so a click or a scroll tells of a move into or out of empty space before it tells of itself: the pointer may
    /// have come there without a move being seen, and a click in empty space is then also an entering of it.
    public static func events(for action: Action, from old: EmptySpace.Spot?, to new: EmptySpace.Spot) -> [RevealEvent] {
        var events = moved(from: old, to: new)
        switch action {
        case .moved:
            break
        case .clicked:
            if let click = clicked(at: new) { events.append(click) }
        case .scrolled(let deltaY, let inverted):
            if let scroll = scrolled(deltaY: deltaY, invertedFromDevice: inverted, at: new) { events.append(scroll) }
        }
        return events
    }

    /// What a move of the pointer from `old` (nil for the first place that is known) to `new` says: it has entered empty space, left
    /// it, or, going from the empty space of one display's bar to another's, both.
    public static func moved(from old: EmptySpace.Spot?, to new: EmptySpace.Spot) -> [RevealEvent] {
        switch (old, new) {
        case (.empty(let before)?, .empty(let now)):
            before == now ? [] : [.pointerLeftEmptySpace, .pointerEnteredEmptySpace]
        case (_, .empty):
            [.pointerEnteredEmptySpace]
        case (.empty?, _):
            [.pointerLeftEmptySpace]
        default:
            []
        }
    }

    /// What a click at `spot` says: a click in empty space.
    public static func clicked(at spot: EmptySpace.Spot) -> RevealEvent? {
        if case .empty = spot { .emptySpaceClicked } else { nil }
    }

    /// Whether a scroll moved the hand (the fingers on the pad, or the wheel) down, whatever the person's scrolling direction is.
    ///
    /// A positive `NSEvent.deltaY` takes the view toward the top of what is scrolled. With the classic direction, fingers or a wheel moving
    /// down take it toward the bottom, a negative delta; with natural scrolling (`isDirectionInvertedFromDevice`) the system has turned
    /// the sign round, and the same movement gives a positive one. So the hand moved down when the delta is negative and the direction is
    /// the device's, or positive and it is inverted.
    public static func movesDown(deltaY: CGFloat, invertedFromDevice: Bool) -> Bool {
        (deltaY < 0) != invertedFromDevice
    }

    /// What a scroll by `deltaY` at `spot` says: the hand moving down on the bar reveals, moving up hides (`RevealMachine`). It has to be
    /// in a bar that is on screen (on an icon or the menus too: the person is on the bar), and reach `scrollThreshold`.
    public static func scrolled(deltaY: CGFloat, invertedFromDevice: Bool, at spot: EmptySpace.Spot) -> RevealEvent? {
        guard EmptySpace.isInBar(spot), abs(deltaY) >= scrollThreshold else { return nil }
        return .scrolled(down: movesDown(deltaY: deltaY, invertedFromDevice: invertedFromDevice))
    }
}

extension RevealEvent {
    /// What a hotkey does to the reveal: show-hidden and show-all toggle that much, and focus-mode toggles Focus Mode. Nil for a
    /// hotkey that has nothing to do with it (opening Settings, or one a newer Mantel wrote).
    public static func forHotkey(_ id: HotkeyID) -> RevealEvent? {
        switch id {
        case .showHidden: .toggle(.hidden)
        case .showAll: .toggle(.all)
        case .focusMode: .toggleFocusMode
        default: nil
        }
    }
}

/// How the two dots are drawn for what the reveal shows: each filled while its section is on the bar, outlined while it is put away.
public struct DotAppearance: Sendable, Equatable {
    /// • is filled while Hidden shows (a reveal of Hidden, or of everything).
    public let hiddenDotFilled: Bool
    /// •• is filled while Always Hidden shows.
    public let alwaysDotFilled: Bool
    /// •• is on the bar only while something that is running is in Always Hidden.
    public let alwaysDotVisible: Bool

    public init(reveal: RevealState, alwaysHiddenHasApps: Bool) {
        hiddenDotFilled = reveal == .hiddenShown || reveal == .allShown
        alwaysDotFilled = reveal == .allShown
        alwaysDotVisible = alwaysHiddenHasApps
    }
}
