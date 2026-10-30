import Foundation

/// How an icon in the menu bar is clicked.
public enum ClickKind: String, Codable, Sendable, CaseIterable {
    /// The ordinary click.
    case left
    /// The secondary click, which many icons answer with a menu of their own.
    case right
    /// A click with the Option key held, which some icons answer differently.
    case option

    /// What the person calls it.
    public var title: String {
        switch self {
        case .left: "Click"
        case .right: "Right-click"
        case .option: "Option-click"
        }
    }
}
