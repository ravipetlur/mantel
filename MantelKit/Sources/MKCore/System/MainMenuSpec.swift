/// How much of a main menu Mantel has while it is an ordinary app.
public enum MainMenuKind: Sendable, Equatable {
    /// A menu bar app has none.
    case none
    /// The Mantel menu alone: a takeover of the menu bar with no window open. The menu stays short, which is what frees the room on the bar.
    case appOnly
    /// The Mantel, Edit and Window menus: a window is open, and it has text fields to copy and paste in, and a window to close.
    case full
}

/// What the main menu says, for the app to draw: the menus, their items, and the shortcuts. The app turns each action into the selector
/// and target it is (the ones for text and windows have no target: they go to whatever has the focus, which is how ⌘C, ⌘V and ⌘W reach
/// a text field and the window that is key).
public struct MainMenuSpec: Sendable, Equatable {
    /// What an item does.
    public enum Action: Sendable, Equatable {
        case about, settings
        case hide, hideOthers, showAll, quit
        case undo, redo, cut, copy, paste, selectAll
        case minimize, close
    }

    public struct Item: Sendable, Equatable {
        public let title: String
        public let action: Action
        /// The key of the shortcut ("" for none), without the modifiers.
        public let key: String
        public let modifiers: ModifierSet

        public init(_ title: String, _ action: Action, key: String = "", modifiers: ModifierSet = .command) {
            self.title = title
            self.action = action
            self.key = key
            self.modifiers = key.isEmpty ? [] : modifiers
        }
    }

    public struct Menu: Sendable, Equatable {
        public let title: String
        /// The items, in groups: a separator stands between two groups.
        public let groups: [[Item]]
        /// Whether this is the menu that lists the windows (`NSApp.windowsMenu`).
        public let isWindowsMenu: Bool

        public init(_ title: String, groups: [[Item]], isWindowsMenu: Bool = false) {
            self.title = title
            self.groups = groups
            self.isWindowsMenu = isWindowsMenu
        }
    }

    public let menus: [Menu]

    /// The menus of a kind: none, the Mantel menu, or that and Edit and Window.
    public static func menus(for kind: MainMenuKind) -> MainMenuSpec {
        switch kind {
        case .none: MainMenuSpec(menus: [])
        case .appOnly: MainMenuSpec(menus: [mantel])
        case .full: MainMenuSpec(menus: [mantel, edit, window])
        }
    }

    private static let mantel = Menu("Mantel", groups: [
        [Item("About Mantel", .about), Item("Settings…", .settings, key: ",")],
        [Item("Hide Mantel", .hide, key: "h"), Item("Hide Others", .hideOthers, key: "h", modifiers: [.option, .command]),
         Item("Show All", .showAll)],
        [Item("Quit Mantel", .quit, key: "q")],
    ])

    private static let edit = Menu("Edit", groups: [
        [Item("Undo", .undo, key: "z"), Item("Redo", .redo, key: "z", modifiers: [.shift, .command])],
        [Item("Cut", .cut, key: "x"), Item("Copy", .copy, key: "c"), Item("Paste", .paste, key: "v"),
         Item("Select All", .selectAll, key: "a")],
    ])

    private static let window = Menu("Window", groups: [
        [Item("Minimize", .minimize, key: "m"), Item("Close", .close, key: "w")],
    ], isWindowsMenu: true)
}
