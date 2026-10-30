import Foundation

/// How the two dots are drawn.
///
/// It is written as an object with the case in `kind` and what the case needs beside it: `{"kind":"symbol","hidden":"…","always":"…"}`.
/// A kind this version doesn't know, and a symbol or an image with a name missing, are read as `dots` (and said in the log), so a file
/// written by a later version still opens and the dots are still there to be found.
public enum DotGlyphStyle: Codable, Sendable, Equatable {
    /// Mantel's own dots.
    case dots
    /// Arrowheads: one for • and two for ••.
    case chevrons
    /// An SF Symbol for each dot, by name.
    case symbol(hidden: String, always: String)
    /// Pictures the person chose, as file names in the folder Mantel keeps them in (`OwnImages`): a light picture for each dot, and
    /// optionally a dark one.
    case image(hiddenLight: String, hiddenDark: String?, alwaysLight: String, alwaysDark: String?)

    private enum CodingKeys: String, CodingKey {
        case kind, hidden, always, hiddenLight, hiddenDark, alwaysLight, alwaysDark
    }

    private enum Kind: String {
        case dots, chevrons, symbol, image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .kind) else {
            self = .dots
            return
        }
        switch Kind(rawValue: name) {
        case .dots:
            self = .dots
        case .chevrons:
            self = .chevrons
        case .symbol:
            if let hidden = try container.decodeIfPresent(String.self, forKey: .hidden),
               let always = try container.decodeIfPresent(String.self, forKey: .always) {
                self = .symbol(hidden: hidden, always: always)
            } else {
                Log.warning("settings", "a dot style with a symbol missing was read as dots")
                self = .dots
            }
        case .image:
            if let hiddenLight = try container.decodeIfPresent(String.self, forKey: .hiddenLight),
               let alwaysLight = try container.decodeIfPresent(String.self, forKey: .alwaysLight) {
                self = .image(hiddenLight: hiddenLight, hiddenDark: try container.decodeIfPresent(String.self, forKey: .hiddenDark),
                              alwaysLight: alwaysLight, alwaysDark: try container.decodeIfPresent(String.self, forKey: .alwaysDark))
            } else {
                Log.warning("settings", "a dot style with a picture missing was read as dots")
                self = .dots
            }
        case nil:
            Log.warning("settings", "a dot style this version doesn't know was read as dots")
            self = .dots
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dots:
            try container.encode(Kind.dots.rawValue, forKey: .kind)
        case .chevrons:
            try container.encode(Kind.chevrons.rawValue, forKey: .kind)
        case .symbol(let hidden, let always):
            try container.encode(Kind.symbol.rawValue, forKey: .kind)
            try container.encode(hidden, forKey: .hidden)
            try container.encode(always, forKey: .always)
        case .image(let hiddenLight, let hiddenDark, let alwaysLight, let alwaysDark):
            try container.encode(Kind.image.rawValue, forKey: .kind)
            try container.encode(hiddenLight, forKey: .hiddenLight)
            try container.encodeIfPresent(hiddenDark, forKey: .hiddenDark)
            try container.encode(alwaysLight, forKey: .alwaysLight)
            try container.encodeIfPresent(alwaysDark, forKey: .alwaysDark)
        }
    }
}

/// When •• is in the menu bar.
public enum AlwaysDotVisibility: String, Codable, Sendable, CaseIterable {
    /// Only while Always Hidden holds an icon.
    case whenNeeded
    /// Whether or not Always Hidden holds anything.
    case always
}

/// The two dots: how they are drawn and when they are there. Kept in `settings.json` under `dots`; a key missing from the file takes its
/// default.
public struct DotSettings: Codable, Sendable, Equatable {
    public var style: DotGlyphStyle = .dots
    public var alwaysDot: AlwaysDotVisibility = .whenNeeded
    /// Neither dot is in the menu bar (Mantel's menu is reached by a shortcut instead).
    public var hideBothDots = false
    /// A divider is drawn at the left edge of Shown.
    public var showsDivider = false

    public init() {}

    public init(style: DotGlyphStyle, alwaysDot: AlwaysDotVisibility, hideBothDots: Bool, showsDivider: Bool) {
        self.style = style
        self.alwaysDot = alwaysDot
        self.hideBothDots = hideBothDots
        self.showsDivider = showsDivider
    }

    private enum CodingKeys: String, CodingKey {
        case style, alwaysDot, hideBothDots, showsDivider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DotSettings()
        self.init(style: try container.decodeIfPresent(DotGlyphStyle.self, forKey: .style) ?? defaults.style,
                  alwaysDot: container.decodeLeniently(AlwaysDotVisibility.self, forKey: .alwaysDot) ?? defaults.alwaysDot,
                  hideBothDots: try container.decodeIfPresent(Bool.self, forKey: .hideBothDots) ?? defaults.hideBothDots,
                  showsDivider: try container.decodeIfPresent(Bool.self, forKey: .showsDivider) ?? defaults.showsDivider)
    }
}
