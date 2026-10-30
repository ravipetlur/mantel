/// What Mantel itself can do, that the command bar offers next to the icons.
public enum CommandBarActionID: String, Codable, Sendable, CaseIterable {
    case showHidden, showAll, hideAgain, focusModeOn, focusModeOff, openSecondBar, refreshMenuBar, recaptureIcons,
         openSettings, openLayout, openHotkeys

    /// What the person calls it.
    public var title: String {
        switch self {
        case .showHidden: "Show hidden icons"
        case .showAll: "Show all icons"
        case .hideAgain: "Hide icons again"
        case .focusModeOn: "Turn Focus Mode on"
        case .focusModeOff: "Turn Focus Mode off"
        case .openSecondBar: "Open the second bar"
        case .refreshMenuBar: "Refresh Menu Bar"
        case .recaptureIcons: "Recapture icons"
        case .openSettings: "Open Settings"
        case .openLayout: "Open Layout settings"
        case .openHotkeys: "Open Hotkeys settings"
        }
    }

    /// Other words the action is found by.
    var keywords: [String] {
        switch self {
        case .showHidden: ["reveal", "hidden"]
        case .showAll: ["reveal", "hidden", "always hidden", "everything"]
        case .hideAgain: ["conceal", "collapse"]
        case .focusModeOn, .focusModeOff: ["focus", "quiet"]
        case .openSecondBar: ["bar", "panel"]
        case .refreshMenuBar: ["refresh", "reload", "rescan"]
        case .recaptureIcons: ["images", "capture", "pictures"]
        case .openSettings: ["settings", "preferences"]
        case .openLayout: ["settings", "layout", "arrange", "order"]
        case .openHotkeys: ["settings", "shortcuts", "keyboard"]
        }
    }
}

/// What decides which of Mantel's actions apply now.
public struct MantelActionState: Sendable, Equatable {
    /// Focus Mode is on, so the one action offered is turning it off.
    public var focusModeOn: Bool
    /// Hidden icons are revealed now, so "Hide icons again" is offered.
    public var revealed: Bool

    public init(focusModeOn: Bool, revealed: Bool) {
        self.focusModeOn = focusModeOn
        self.revealed = revealed
    }
}

/// Offers Mantel's own actions: the ones that apply now, below an icon that matches as well as they do.
public struct MantelActionsProvider: CommandBarProvider {
    /// How far an action's score is held down, so that an icon that matches as well is listed above it.
    static let boost = -20

    private let state: @Sendable () async -> MantelActionState

    /// `state` is asked each time the command bar opens.
    public init(state: @escaping @Sendable () async -> MantelActionState) {
        self.state = state
    }

    public var name: String { "Mantel" }

    public func candidates() async -> [SearchCandidate] {
        let now = await state()
        return CommandBarActionID.allCases
            .filter { action in
                switch action {
                case .hideAgain: now.revealed
                case .focusModeOn: !now.focusModeOn
                case .focusModeOff: now.focusModeOn
                default: true
                }
            }
            .map { action in
                SearchCandidate(id: SearchResultKind.action(action).candidateID, kind: .action(action), title: action.title,
                                terms: action.keywords, boost: Self.boost)
            }
    }
}
