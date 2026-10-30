import Foundation

/// Where the two dots are in the menu bar.
public enum DotsPlacement: String, Codable, Sendable, CaseIterable {
    /// Between the sections: Always Hidden, ••, Hidden, •, Shown.
    case betweenSections
    /// Beside the clock, after Shown, so that macOS never takes them into its « menu.
    case besideClock
}

/// How the layout behaves. Kept in `settings.json` under `layout`; a key missing from the file takes its default.
public struct LayoutSettings: Codable, Sendable, Equatable {
    public var dotsPlacement: DotsPlacement = .betweenSections
    /// Holding ⌘ with the mouse down in the menu bar shows every section while the icons are dragged.
    public var showAllWhileCommandDragging = false

    public init() {}

    public init(dotsPlacement: DotsPlacement, showAllWhileCommandDragging: Bool) {
        self.dotsPlacement = dotsPlacement
        self.showAllWhileCommandDragging = showAllWhileCommandDragging
    }

    private enum CodingKeys: String, CodingKey {
        case dotsPlacement, showAllWhileCommandDragging
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LayoutSettings()
        self.init(dotsPlacement: container.decodeLeniently(DotsPlacement.self, forKey: .dotsPlacement) ?? defaults.dotsPlacement,
                  showAllWhileCommandDragging: try container.decodeIfPresent(Bool.self, forKey: .showAllWhileCommandDragging)
                      ?? defaults.showAllWhileCommandDragging)
    }
}
