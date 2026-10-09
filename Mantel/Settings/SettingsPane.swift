import MKCommands

/// A pane of the Settings window. The raw values are the words of `SettingsPage`, which is how a command names a pane, and
/// what `GeneralSettings.settingsPage` keeps.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, hotkeys, permissions, diagnostics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .hotkeys: "Hotkeys"
        case .permissions: "Permissions"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hotkeys: "keyboard"
        case .permissions: "lock.shield"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }

    /// The panes Settings shows, in the sidebar's order.
    static var available: [SettingsPane] {
        [.general, .hotkeys, .permissions, .diagnostics, .about]
    }

    /// The pane a command's page opens.
    init(page: SettingsPage) {
        switch page {
        case .general: self = .general
        case .hotkeys: self = .hotkeys
        case .permissions: self = .permissions
        case .about: self = .about
        case .diagnostics: self = .diagnostics
        }
    }
}
