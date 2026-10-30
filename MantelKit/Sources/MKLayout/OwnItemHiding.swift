/// How one of Mantel's own items (a dot, a spacer, a group's icon, the divider) is taken off the menu bar without anything being written to
/// the order table. The two ways differ in whether macOS keeps the item's place while it is off.
public enum OwnItemHiding: String, Sendable {
    /// The item's `isVisible` is turned off. Where the item was is remembered, and it comes back to that place.
    case visibility
    /// The item is made no wider than nothing and its button is hidden, and `isVisible` is never touched: turning it off loses the
    /// item's place.
    case zeroLength

    /// The way this build hides an own item. One value, for every own item, so that it is changed in one place.
    public static let current = OwnItemHiding.visibility

    /// What an own item looks like to the system for the way it is put on the bar or taken off it.
    public struct Presentation: Sendable, Equatable {
        /// What the status item's `isVisible` is set to.
        public let isVisible: Bool
        /// Whether the item has no width and its button is hidden.
        public let isCollapsed: Bool

        public init(isVisible: Bool, isCollapsed: Bool) {
            self.isVisible = isVisible
            self.isCollapsed = isCollapsed
        }
    }

    /// What to set on an own item's status item to put it on the bar (`onBar` true) or to take it off.
    public func presentation(onBar: Bool) -> Presentation {
        switch self {
        case .visibility:
            Presentation(isVisible: onBar, isCollapsed: false)
        case .zeroLength:
            Presentation(isVisible: true, isCollapsed: !onBar)
        }
    }
}
