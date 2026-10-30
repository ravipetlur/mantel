import Foundation

/// When the second bar opens.
public enum SecondBarOpening: String, Codable, Sendable, CaseIterable {
    /// Only when the icons that are revealed don't fit on the menu bar.
    case whenNoRoom
    /// Every reveal opens it, and nothing is shown in the menu bar itself.
    case always
}

/// Where the second bar is put.
public enum SecondBarPosition: String, Codable, Sendable, CaseIterable {
    /// Under the dot that opened it.
    case underDot
    /// Against the right edge of the screen.
    case rightAligned
}

/// The second bar: when it opens, where, and how it looks. Kept in `settings.json` under `secondBar`; a key missing from the file takes
/// its default.
public struct SecondBarSettings: Codable, Sendable, Equatable {
    public var opens: SecondBarOpening = .whenNoRoom
    public var position: SecondBarPosition = .underDot
    public var style = PanelStyle()

    public init() {}

    public init(opens: SecondBarOpening, position: SecondBarPosition, style: PanelStyle) {
        self.opens = opens
        self.position = position
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case opens, position, style
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SecondBarSettings()
        self.init(opens: container.decodeLeniently(SecondBarOpening.self, forKey: .opens) ?? defaults.opens,
                  position: container.decodeLeniently(SecondBarPosition.self, forKey: .position) ?? defaults.position,
                  style: try container.decodeIfPresent(PanelStyle.self, forKey: .style) ?? defaults.style)
    }
}
