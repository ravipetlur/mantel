import Foundation

/// The ways icon spacing can be set from Settings.
public enum IconSpacingPreset: String, Codable, Sendable, CaseIterable {
    /// Both keys removed: macOS decides.
    case macOSDefault
    case small, tiny, none
    /// Values the person chose, each 0 to 20.
    case custom

    public var title: String {
        switch self {
        case .macOSDefault: "macOS default"
        case .small: "Small"
        case .tiny: "Tiny"
        case .none: "None"
        case .custom: "Custom"
        }
    }
}

/// What the two spacing keys hold: how far apart icons are (`spacing`) and how much room is round each icon's highlight (`padding`).
public struct IconSpacingValues: Codable, Sendable, Equatable {
    /// `NSStatusItemSpacing`.
    public var spacing: Int
    /// `NSStatusItemSelectionPadding`.
    public var padding: Int

    /// What either value may be.
    public static let range: ClosedRange<Int> = 0...20

    public init(spacing: Int, padding: Int) {
        self.spacing = spacing
        self.padding = padding
    }

    /// The values, each brought into `range`.
    public var clamped: IconSpacingValues {
        IconSpacingValues(spacing: min(max(spacing, Self.range.lowerBound), Self.range.upperBound),
                          padding: min(max(padding, Self.range.lowerBound), Self.range.upperBound))
    }
}

/// Icon spacing: the two keys macOS reads, and the values the presets stand for.
public enum IconSpacing {
    /// Whether macOS applies the two keys to the icons of apps that open after they change, as the platform check found it does on this
    /// version. Where it didn't, Settings would switch the section off and say so (`notAppliedText`).
    public static let macOSApplies = true

    /// What Settings and Diagnostics say on a Mac where changing the keys does nothing to the icons.
    public static let notAppliedText = "macOS 27 doesn't apply icon spacing on this Mac."

    /// The key for the distance between icons, in the global preferences for this Mac.
    public static let spacingKey = "NSStatusItemSpacing"
    /// The key for the room round each icon's highlight, in the global preferences for this Mac.
    public static let paddingKey = "NSStatusItemSelectionPadding"

    /// The values a preset stands for, spacing first: Small 8 / 8, Tiny 4 / 6, None 0 / 4, and `custom`'s own, brought into 0 to 20.
    /// Nil for "macOS default": both keys are removed, and there are no values.
    public static func values(for preset: IconSpacingPreset, custom: IconSpacingValues) -> IconSpacingValues? {
        switch preset {
        case .macOSDefault: nil
        case .small: IconSpacingValues(spacing: 8, padding: 8)
        case .tiny: IconSpacingValues(spacing: 4, padding: 6)
        case .none: IconSpacingValues(spacing: 0, padding: 4)
        case .custom: custom.clamped
        }
    }

    /// The preset the keys' values are: both missing is "macOS default"; values a preset stands for are that preset; anything else
    /// (one key missing, other numbers) is `custom`.
    public static func preset(spacing: Int?, padding: Int?) -> IconSpacingPreset {
        guard let spacing, let padding else {
            return spacing == nil && padding == nil ? .macOSDefault : .custom
        }
        let held = IconSpacingValues(spacing: spacing, padding: padding)
        let named: [IconSpacingPreset] = [.small, .tiny, .none]
        return named.first { values(for: $0, custom: held) == held } ?? .custom
    }
}
