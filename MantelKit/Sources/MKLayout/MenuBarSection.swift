/// Where an app's icons live: on the bar, or tucked away until a reveal.
public enum MenuBarSection: String, Codable, Sendable, CaseIterable {
    /// On the menu bar all the time.
    case shown
    /// Off the bar until the • dot (or a hover, a click, a scroll or a hotkey) reveals it.
    case hidden
    /// Off the bar until the •• dot or the Show all icons hotkey reveals it.
    case alwaysHidden

    /// The name Settings gives the section.
    public var title: String {
        switch self {
        case .shown: "Shown"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
}

/// How much of what is hidden a reveal shows.
public enum RevealLevel: String, Codable, Sendable {
    /// Nothing is revealed: Hidden and Always Hidden stay off the bar. (Written `none` in a file.)
    case off = "none"
    /// Hidden is revealed.
    case hidden
    /// Hidden and Always Hidden are revealed.
    case all
}

/// A dictionary keyed by `MenuBarSection` is written as a JSON object (`{"hidden": …}`), not as the flat list of keys and values that
/// the encoder makes of a dictionary whose keys it doesn't know to be strings. The standard conformance for a type with a string
/// raw value does it: the key is the raw value.
extension MenuBarSection: CodingKeyRepresentable {}
