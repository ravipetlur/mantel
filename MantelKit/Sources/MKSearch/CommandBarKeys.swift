import MKCore

/// What a key pressed in the command bar does.
public enum CommandBarActivation: Sendable, Equatable {
    /// Click the selected icon this way.
    case click(ClickKind)
    /// Show the selected icon without clicking it.
    case show
    /// Run the selected action.
    case run
    case close
    case moveUp
    case moveDown
    /// Return with nothing selected: the key is the command bar's and does nothing (the field would take it, end its editing and select
    /// its text, so that the next key typed replaced the whole query).
    case nothing
    /// The key isn't one the command bar answers to: the search field gets it.
    case ignored
}

/// The standard editing actions a command-key shortcut asks of the search field.
public enum CommandBarEditing: Sendable, Equatable, CaseIterable {
    case undo, redo, cut, copy, paste, selectAll
}

/// The command bar's keys, and the line of hints under its results.
///
/// - **↑ and ↓** move the selection, **Esc** closes.
/// - **Return** clicks the selected icon, **⌥Return** option-clicks it, **⌘Return** right-clicks it (⌘ wins when both are held) and
///   **⇧Return** shows it without clicking (⇧ wins over the other two, since it is the one that doesn't click). Any Return runs an action.
/// - **Return with nothing selected** does nothing.
/// - **⌘V, ⌘C, ⌘X, ⌘A, ⌘Z and ⇧⌘Z** are the editing actions of the field (`editing`): Mantel has no Edit menu while it is a menu bar app
///   with no window open, which is what carries these to a text field everywhere else.
/// - **A kind of click that doesn't arrive** (`ClickRouteRules.postedRightWorks`, `postedOptionWorks`) is left out of the footer. A right
///   click that can't be posted is a left click. An option click is still asked for as one: the click driver makes it a left click when
///   it can't be posted, and says so.
public enum CommandBarKeys {
    private static let upArrow: UInt16 = 126
    private static let downArrow: UInt16 = 125
    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76

    /// What the key does with this icon or action selected (nil when nothing is).
    ///
    /// - Parameters:
    ///   - keyCode: the key's virtual key code.
    ///   - modifiers: the modifiers held.
    ///   - selected: what is selected in the list.
    ///   - postedRightWorks: whether a right click posted at an icon arrives as one.
    ///   - postedOptionWorks: whether an option click posted at an icon arrives as one.
    public static func activation(keyCode: UInt16, modifiers: ModifierSet, selected: SearchResultKind?, postedRightWorks: Bool,
                                  postedOptionWorks: Bool) -> CommandBarActivation {
        switch keyCode {
        case upArrow: return .moveUp
        case downArrow: return .moveDown
        case escape: return .close
        case returnKey, keypadEnter:
            guard let selected else { return .nothing }
            switch selected {
            case .action:
                return .run
            case .icon:
                if modifiers.contains(.shift) { return .show }
                if modifiers.contains(.command) { return .click(postedRightWorks ? .right : .left) }
                if modifiers.contains(.option) { return .click(.option) }
                return .click(.left)
            }
        default:
            return .ignored
        }
    }

    /// The editing action a key asks of the search field, nil for a key that isn't one. It goes by the character the key makes (so that a
    /// layout whose ⌘V is on another key still pastes), not by the key code; ⇧ is held for Redo alone, and nothing else may be held.
    ///
    /// - Parameters:
    ///   - characters: the key's characters with the modifiers left out (`NSEvent.charactersIgnoringModifiers`), in either case.
    ///   - modifiers: the modifiers held.
    public static func editing(characters: String, modifiers: ModifierSet) -> CommandBarEditing? {
        let key = characters.lowercased()
        if modifiers == [.command, .shift] { return key == "z" ? .redo : nil }
        guard modifiers == [.command] else { return nil }
        switch key {
        case "z": return .undo
        case "x": return .cut
        case "c": return .copy
        case "v": return .paste
        case "a": return .selectAll
        default: return nil
        }
    }

    /// The line of hints under the results for what is selected: the ways to click an icon that work, or the one way to run an action.
    /// Empty when nothing is selected.
    public static func footer(for kind: SearchResultKind?, postedRightWorks: Bool, postedOptionWorks: Bool) -> String {
        switch kind {
        case nil:
            return ""
        case .action:
            return "↩ Run"
        case .icon:
            var parts = ["↩ Click"]
            if postedOptionWorks { parts.append("⌥↩ Option-click") }
            if postedRightWorks { parts.append("⌘↩ Right-click") }
            parts.append("⇧↩ Show")
            return parts.joined(separator: "  ")
        }
    }
}

/// A part of a result's title, and whether the query matched its characters (they are drawn in `.semibold`).
public struct CommandBarTitleRun: Sendable, Equatable {
    public let text: String
    public let matched: Bool

    public init(text: String, matched: Bool) {
        self.text = text
        self.matched = matched
    }
}

/// How a result's title is split for drawing the characters the query matched in a heavier weight.
public enum CommandBarTitle {
    /// The title in runs: neighbouring characters that were matched, or weren't, are one run. `offsets` are the characters' places in
    /// the title (`SearchResult.titleOffsets`); one that is past the end of the title is left out.
    public static func runs(of title: String, matching offsets: [Int]) -> [CommandBarTitleRun] {
        let matched = Set(offsets)
        var runs: [CommandBarTitleRun] = []
        for (place, character) in title.enumerated() {
            let isMatched = matched.contains(place)
            if let last = runs.last, last.matched == isMatched {
                runs[runs.count - 1] = CommandBarTitleRun(text: last.text + String(character), matched: isMatched)
            } else {
                runs.append(CommandBarTitleRun(text: String(character), matched: isMatched))
            }
        }
        return runs
    }
}

extension CommandBarActionID {
    /// The SF Symbol an action's row shows.
    public var symbolName: String {
        switch self {
        case .showHidden: "eye"
        case .showAll: "eye.fill"
        case .hideAgain: "eye.slash"
        case .focusModeOn: "moon"
        case .focusModeOff: "moon.fill"
        case .openSecondBar: "rectangle.topthird.inset.filled"
        case .refreshMenuBar: "arrow.clockwise"
        case .recaptureIcons: "camera.viewfinder"
        case .openSettings: "gearshape"
        case .openLayout: "rectangle.split.3x1"
        case .openHotkeys: "keyboard"
        }
    }
}

/// Which result the keyboard is on.
///
/// - **A new answer keeps the selected result** when it is still listed, else the first result is selected; with no results nothing is.
/// - **↑ and ↓ stop at the ends.** With nothing selected, ↓ goes to the first result and ↑ to the last.
public struct CommandBarSelection: Sendable, Equatable {
    /// The selected result's place in the list; nil while there are none.
    public let index: Int?

    public init(index: Int?) {
        self.index = index
    }

    /// The selection once `results` are what is listed, the result with the ID `kept` having been selected before (nil for none).
    public static func selecting(results: [SearchResult], keeping kept: String?) -> CommandBarSelection {
        guard !results.isEmpty else { return CommandBarSelection(index: nil) }
        return CommandBarSelection(index: kept.flatMap { id in results.firstIndex { $0.id == id } } ?? 0)
    }

    /// The selection after ↓ (`step` 1) or ↑ (-1) with `count` results listed.
    public func moved(by step: Int, count: Int) -> CommandBarSelection {
        guard count > 0 else { return CommandBarSelection(index: nil) }
        let start = index ?? (step > 0 ? -1 : count)
        return CommandBarSelection(index: min(max(0, start + step), count - 1))
    }
}
