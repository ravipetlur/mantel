import Foundation

/// How thick the material behind a panel is: the five thicknesses the system offers, thinnest first.
public enum MaterialThickness: String, Codable, Sendable, CaseIterable {
    case ultraThin, thin, regular, thick, ultraThick
}

/// What is drawn behind the icons of a panel (the second bar, a group's panel).
///
/// It is written as an object with the case in `kind` and what the case needs beside it, so that a file stays readable by hand:
/// `{"kind":"gradient","from":{…},"to":{…},"angle":90}`. A part that is missing takes its default, and a kind this version doesn't know
/// is read as `matchMenuBar` (and said in the log), so a file written by a later version still opens.
public enum PanelBackground: Codable, Sendable, Equatable {
    /// The menu bar's own look.
    case matchMenuBar
    /// The system's glass, tinted when a colour is given.
    case glass(tint: RGBAColor?)
    /// One of the system's materials.
    case material(MaterialThickness)
    /// One colour.
    case solid(RGBAColor)
    /// Two colours, blended along a line at `angle` degrees (0 to 359).
    case gradient(from: RGBAColor, to: RGBAColor, angle: Int)

    /// An angle in degrees brought into 0 to 359: it is a direction, so 360 is 0 again and -90 is 270.
    static func wrapped(angle: Int) -> Int {
        ((angle % 360) + 360) % 360
    }

    /// The background with a gradient's angle wrapped into 0 to 359. A case can't check what it is given, so this is where a background
    /// that was made by hand is brought into range (`PanelStyle.init` does it, and the encoder writes the wrapped angle).
    var normalized: PanelBackground {
        if case .gradient(let from, let to, let angle) = self {
            return .gradient(from: from, to: to, angle: Self.wrapped(angle: angle))
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case kind, tint, thickness, color, from, to, angle
    }

    private enum Kind: String {
        case matchMenuBar, glass, material, solid, gradient
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .kind)
        guard let name else {
            self = .matchMenuBar
            return
        }
        switch Kind(rawValue: name) {
        case .matchMenuBar:
            self = .matchMenuBar
        case .glass:
            self = .glass(tint: try container.decodeIfPresent(RGBAColor.self, forKey: .tint))
        case .material:
            self = .material(container.decodeLeniently(MaterialThickness.self, forKey: .thickness) ?? .regular)
        case .solid:
            self = .solid(try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .black)
        case .gradient:
            self = .gradient(from: try container.decodeIfPresent(RGBAColor.self, forKey: .from) ?? .black,
                             to: try container.decodeIfPresent(RGBAColor.self, forKey: .to) ?? .white,
                             angle: Self.wrapped(angle: try container.decodeIfPresent(Int.self, forKey: .angle) ?? 0))
        case nil:
            Log.warning("settings", "a panel background this version doesn't know was read as the menu bar's look")
            self = .matchMenuBar
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .matchMenuBar:
            try container.encode(Kind.matchMenuBar.rawValue, forKey: .kind)
        case .glass(let tint):
            try container.encode(Kind.glass.rawValue, forKey: .kind)
            try container.encodeIfPresent(tint, forKey: .tint)
        case .material(let thickness):
            try container.encode(Kind.material.rawValue, forKey: .kind)
            try container.encode(thickness, forKey: .thickness)
        case .solid(let color):
            try container.encode(Kind.solid.rawValue, forKey: .kind)
            try container.encode(color, forKey: .color)
        case .gradient(let from, let to, let angle):
            try container.encode(Kind.gradient.rawValue, forKey: .kind)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(Self.wrapped(angle: angle), forKey: .angle)
        }
    }
}

/// Whether a panel is drawn light or dark, or as the menu bar is.
public enum PanelAppearance: String, Codable, Sendable, CaseIterable {
    case matchMenuBar, light, dark
}

/// A border of the person's own around a panel.
public struct PanelBorder: Codable, Sendable, Equatable {
    /// The widths of a border, in points.
    public static let widthRange = 1...4

    public var color: RGBAColor
    /// 1 to 4 points; a width that is given outside them (a file's, or the initializer's) is brought to the nearest of those.
    public var width: Int

    public init(color: RGBAColor, width: Int = 1) {
        self.color = color
        self.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case color, width
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? RGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5),
                  width: try container.decodeIfPresent(Int.self, forKey: .width) ?? 1)
    }
}

/// How a panel looks: what is behind its icons, light or dark, a border and a shadow. A key missing from the file takes its default.
public struct PanelStyle: Codable, Sendable, Equatable {
    public var background: PanelBackground = .matchMenuBar
    public var appearance: PanelAppearance = .matchMenuBar
    /// Nil: the 1 point separator border every floating panel has.
    public var border: PanelBorder? = nil
    public var shadow = true

    public init() {}

    public init(background: PanelBackground, appearance: PanelAppearance, border: PanelBorder?, shadow: Bool) {
        self.background = background.normalized
        self.appearance = appearance
        self.border = border
        self.shadow = shadow
    }

    private enum CodingKeys: String, CodingKey {
        case background, appearance, border, shadow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PanelStyle()
        self.init(background: try container.decodeIfPresent(PanelBackground.self, forKey: .background) ?? defaults.background,
                  appearance: container.decodeLeniently(PanelAppearance.self, forKey: .appearance) ?? defaults.appearance,
                  border: try container.decodeIfPresent(PanelBorder.self, forKey: .border),
                  shadow: try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? defaults.shadow)
    }
}

/// The kinds of background a panel can have, as the pane that edits them lists them (the cases of `PanelBackground`, without what each holds).
public enum PanelBackgroundKind: String, Sendable, CaseIterable {
    case matchMenuBar, glass, material, solid, gradient
}

extension PanelStyle {
    /// The colour a new gradient starts from when the background held none, and the one it ends on.
    private static let defaultFrom = RGBAColor.black
    private static let defaultTo = RGBAColor.white

    public var backgroundKind: PanelBackgroundKind {
        switch background {
        case .matchMenuBar: .matchMenuBar
        case .glass: .glass
        case .material: .material
        case .solid: .solid
        case .gradient: .gradient
        }
    }

    /// The style with its background switched to `kind`, keeping the colours the new kind can use: a solid colour becomes a gradient's
    /// "From" and a gradient's "From" becomes the solid colour, so that going there and back leaves the colour as it was. A glass tint
    /// isn't carried: it is translucent, and a solid colour or a gradient is drawn opaque. Anything the new kind needs and the old one
    /// didn't hold takes its default. The same kind returns the style as it is. Appearance, border and shadow don't change.
    public func withBackgroundKind(_ kind: PanelBackgroundKind) -> PanelStyle {
        guard kind != backgroundKind else { return self }
        let carried: RGBAColor? = switch background {
        case .solid(let color): color
        case .gradient(let from, _, _): from
        case .matchMenuBar, .glass, .material: nil
        }
        var changed = self
        changed.background = switch kind {
        case .matchMenuBar: .matchMenuBar
        case .glass: .glass(tint: nil)
        case .material: .material(.regular)
        case .solid: .solid(carried ?? Self.defaultFrom)
        case .gradient: .gradient(from: carried ?? Self.defaultFrom, to: Self.defaultTo, angle: 0)
        }
        return changed
    }

    /// The style with its border's width set, brought to 1 to 4 points. A style with no border of its own is returned as it is.
    public func withBorderWidth(_ width: Int) -> PanelStyle {
        guard let own = border else { return self }
        var changed = self
        changed.border = PanelBorder(color: own.color, width: width)
        return changed
    }
}
