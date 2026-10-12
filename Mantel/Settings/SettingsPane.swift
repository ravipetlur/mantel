import MKCommands

/// A pane of the Settings window. The raw values are the words of `SettingsPage`, which is how a command names a pane, and
/// what `GeneralSettings.settingsPage` keeps.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, layout, hotkeys, permissions, advanced, diagnostics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .hotkeys: "Hotkeys"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "rectangle.split.3x1"
        case .hotkeys: "keyboard"
        case .permissions: "lock.shield"
        case .advanced: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }

    /// The panes Settings shows, in the sidebar's order.
    static var available: [SettingsPane] {
        [.general, .layout, .hotkeys, .permissions, .advanced, .diagnostics, .about]
    }

    /// The pane a command's page opens.
    init(page: SettingsPage) {
        switch page {
        case .general: self = .general
        case .layout: self = .layout
        case .hotkeys: self = .hotkeys
        case .permissions: self = .permissions
        case .advanced: self = .advanced
        case .about: self = .about
        case .diagnostics: self = .diagnostics
        }
    }
}
