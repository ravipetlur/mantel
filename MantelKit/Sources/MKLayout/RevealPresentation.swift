import MKCore

/// Where revealed icons are shown.
public enum RevealPresentation: String, Sendable, Codable {
    /// On the menu bar itself, where macOS draws them.
    case inline
    /// In a bar of Mantel's own under the menu bar. The menu bar itself keeps what the person's sections say.
    case secondBar
}

/// What asked for a reveal.
public enum RevealTrigger: Sendable, Equatable {
    /// A click on one of Mantel's dots.
    case dot
    /// The pointer resting in empty space on the bar.
    case hover
    /// A click in empty space on the bar.
    case emptySpaceClick
    /// A scroll on the bar.
    case scroll
    /// The hotkeys that show Hidden or everything.
    case hotkey
    /// The hotkey for the second bar.
    case secondBarHotkey
    /// A command (`mantel show`, the menu).
    case command
    /// A ⌘-drag of an icon: the person is moving icons on the menu bar, so they have to be there.
    case commandDrag
}

/// Where the second bar is anchored.
public enum SecondBarAnchorKind: Sendable, Equatable {
    /// Under the dot that was clicked.
    case underDot
    /// Against the right edge of the screen.
    case rightAligned
    /// Under the pointer.
    case pointer
}

/// How a reveal is shown, where the second bar goes and whether it takes the keyboard.
///
/// - **Every reveal follows the setting**, whatever asked for it: the dots, hover, a click, a scroll, the hotkeys and the commands.
/// - **The hotkey for the second bar always opens it**, at the pointer, whatever the setting is.
/// - **A ⌘-drag always reveals inline:** the drag needs the icons on the menu bar.
public enum RevealPresentationPolicy {
    /// - Parameters:
    ///   - opens: when the person has the second bar open: always, or only when the icons that are revealed don't fit.
    ///   - predictedFits: whether the icons to be revealed are predicted to fit on the menu bar (`RoomPrediction`). Only read for
    ///     `.whenNoRoom`.
    public static func presentation(opens: SecondBarOpening, trigger: RevealTrigger, predictedFits: Bool) -> RevealPresentation {
        switch trigger {
        case .secondBarHotkey:
            return .secondBar
        case .commandDrag:
            return .inline
        case .dot, .hover, .emptySpaceClick, .scroll, .hotkey, .command:
            switch opens {
            case .always: return .secondBar
            case .whenNoRoom: return predictedFits ? .inline : .secondBar
            }
        }
    }

    /// What a reveal that is to be shown in the second bar comes to when the bar would list nothing (the Hidden icons that are left are
    /// all gone, or all turned off): shown on the menu bar itself, since an empty bar would fill the dots and show nothing.
    public static func presentation(_ chosen: RevealPresentation, secondBarListsSomething: Bool) -> RevealPresentation {
        chosen == .secondBar && !secondBarListsSomething ? .inline : chosen
    }

    /// Where the bar is anchored.
    ///
    /// - The hotkey for the second bar: the pointer.
    /// - A dot: where the person's setting says, under the dot or against the right edge.
    /// - Anything else has no dot that was clicked to go under, so the bar goes against the right edge, whatever the setting is.
    public static func anchor(trigger: RevealTrigger, position: SecondBarPosition) -> SecondBarAnchorKind {
        switch trigger {
        case .secondBarHotkey:
            return .pointer
        case .dot:
            switch position {
            case .underDot: return .underDot
            case .rightAligned: return .rightAligned
            }
        case .hover, .emptySpaceClick, .scroll, .hotkey, .command, .commandDrag:
            return .rightAligned
        }
    }

    /// Whether the icons that don't fit on the bar after a reveal are made room for (taking over the menu bar, the second bar, a swap). A
    /// ⌘-drag's reveal never makes room: the person is holding an icon with the mouse, and Mantel must not become the active app, move the
    /// reveal into the second bar or conceal Shown apps under the pointer meanwhile.
    public static func makesRoom(trigger: RevealTrigger) -> Bool {
        switch trigger {
        case .commandDrag: false
        case .dot, .hover, .emptySpaceClick, .scroll, .hotkey, .secondBarHotkey, .command: true
        }
    }

    /// Whether the bar takes the keyboard when it opens. A click on a dot or in empty space and the hotkeys mean the person wants to
    /// use it; a hover, a scroll, a command and a ⌘-drag must never take what they are typing.
    public static func makesKey(trigger: RevealTrigger) -> Bool {
        switch trigger {
        case .dot, .emptySpaceClick, .hotkey, .secondBarHotkey: true
        case .hover, .scroll, .command, .commandDrag: false
        }
    }
}
