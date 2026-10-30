/// What one of Mantel's own items in the menu bar is: a dot, the divider, a spacer or a group's icon.
///
/// An item of Mantel's that is none of these (the invisible items the wide spacer uses) has no kind. The words that tell the kinds apart
/// are in `OwnItems` (MKLayout), and the matcher sets the kind of every item it finds of Mantel's.
public enum OwnItemKind: String, Codable, Sendable, CaseIterable {
    /// • : shows Hidden.
    case hiddenDot
    /// •• : shows Hidden and Always Hidden.
    case alwaysDot
    /// The line at the left edge of Shown.
    case divider
    /// A gap, of a width the person chose, between icons.
    case spacer
    /// An icon that opens a panel of other icons.
    case group

    /// Whether the kind is one of the two dots.
    public var isDot: Bool {
        self == .hiddenDot || self == .alwaysDot
    }
}
