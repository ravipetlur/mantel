import CoreGraphics
import MKCore

/// What one dot is drawn as, for the way the dots are styled (`DotGlyphStyle`), whether the dot's section is on the bar, and whether the
/// bar is dark behind it.
public enum DotGlyph: Sendable, Equatable {
    /// Mantel's own dots: each rect is a circle in an 18 × 18 box (the origin at the lower left), solid when `filled` and a ring as big as
    /// the circle otherwise.
    case circles(rects: [CGRect], filled: Bool)
    /// Arrowheads pointing left, one for • and two for ••: solid when `filled`, outlined otherwise (`DotGlyphs.arrowheadPath`).
    case arrowheads(count: Int, filled: Bool)
    /// An SF Symbol, by name, drawn at `opacity`.
    case symbol(name: String, opacity: Double)
    /// A picture the person chose, as a file name in the folder Mantel keeps them in, drawn as it is at `opacity`.
    case image(fileName: String, opacity: Double)
}

/// The decisions about how a dot is drawn. What draws it is the app's.
public enum DotGlyphs {
    /// How opaque a symbol or a picture is while its dot's section is off the bar. (It is fully opaque while the section is on it.)
    public static let closedOpacity = 0.55

    /// The side of the square every dot is drawn in, in points.
    public static let boxSide: CGFloat = 18

    /// How wide and how tall one arrowhead is, and the gap between two, in points.
    public static let arrowheadWidth: CGFloat = 6
    public static let arrowheadHeight: CGFloat = 8
    public static let arrowheadGap: CGFloat = 4

    /// How thick an outlined arrowhead's line is, in points.
    public static let arrowheadStroke: CGFloat = 1.5

    /// What `dot` is drawn as.
    ///
    /// - Parameters:
    ///   - open: whether the dot's section is on the bar.
    ///   - darkBar: whether the bar is dark behind the dot, which chooses between a picture's light file and its dark one.
    ///   - symbolExists: whether the system has a symbol of this name. It is asked of the filled form of a symbol's name only: a name that
    ///     isn't a symbol at all is for what draws the glyph to find out.
    public static func glyph(_ dot: DotKind, open: Bool, style: DotGlyphStyle, darkBar: Bool,
                             symbolExists: (String) -> Bool) -> DotGlyph {
        switch style {
        case .dots:
            return .circles(rects: circles(for: dot), filled: open)
        case .chevrons:
            return .arrowheads(count: dot == .hidden ? 1 : 2, filled: open)
        case .symbol(let hidden, let always):
            let name = dot == .hidden ? hidden : always
            guard open else { return .symbol(name: name, opacity: closedOpacity) }
            // The filled form shows the dot is on; a symbol that has none is shown at full strength instead.
            let filled = name + ".fill"
            return .symbol(name: symbolExists(filled) ? filled : name, opacity: 1)
        case .image(let hiddenLight, let hiddenDark, let alwaysLight, let alwaysDark):
            let light = dot == .hidden ? hiddenLight : alwaysLight
            let dark = dot == .hidden ? hiddenDark : alwaysDark
            let file = darkBar ? (dark.flatMap { $0.isEmpty ? nil : $0 } ?? light) : light
            return .image(fileName: file, opacity: open ? 1 : closedOpacity)
        }
    }

    /// The circles of Mantel's own dots: • is one 6 points across, and •• is two of 5 points, 3 points apart, in the 18 × 18 box.
    public static func circles(for dot: DotKind) -> [CGRect] {
        switch dot {
        case .hidden:
            [CGRect(x: 6, y: 6, width: 6, height: 6)]
        case .always:
            [CGRect(x: 2.5, y: 6.5, width: 5, height: 5), CGRect(x: 10.5, y: 6.5, width: 5, height: 5)]
        }
    }

    /// The most arrowheads that fit the box side by side.
    public static let mostArrowheads = 2

    /// `count` arrowheads, each a triangle pointing left, as a list of its corners (the tip first), side by side and centred in the
    /// 18 × 18 box (the origin at the lower left). Each is 6 points wide and 8 tall, and 4 points from the next. A count past the
    /// most that fit is the most that fit, and one below 1 has none.
    public static func arrowheadPath(count: Int) -> [[CGPoint]] {
        let heads = min(max(count, 0), mostArrowheads)
        let total = CGFloat(heads) * arrowheadWidth + CGFloat(max(heads - 1, 0)) * arrowheadGap
        let left = (boxSide - total) / 2
        let bottom = (boxSide - arrowheadHeight) / 2
        let middle = boxSide / 2
        return (0..<heads).map { index in
            let x = left + CGFloat(index) * (arrowheadWidth + arrowheadGap)
            return [CGPoint(x: x, y: middle),
                    CGPoint(x: x + arrowheadWidth, y: bottom + arrowheadHeight),
                    CGPoint(x: x + arrowheadWidth, y: bottom)]
        }
    }

    /// The corners to stroke for an outlined arrowhead: each of `arrowheadPath`'s triangles drawn in toward its centre by half of
    /// `arrowheadStroke`. A stroke is centred on its path, so with the round joins the line reaches half its width past these corners,
    /// which is the edge of the solid head: outlined and solid heads are the same size.
    public static func arrowheadOutlinePath(count: Int) -> [[CGPoint]] {
        arrowheadPath(count: count).map { corners in
            let a = hypot(corners[1].x - corners[2].x, corners[1].y - corners[2].y)
            let b = hypot(corners[0].x - corners[2].x, corners[0].y - corners[2].y)
            let c = hypot(corners[0].x - corners[1].x, corners[0].y - corners[1].y)
            let perimeter = a + b + c
            let centre = CGPoint(x: (a * corners[0].x + b * corners[1].x + c * corners[2].x) / perimeter,
                                 y: (a * corners[0].y + b * corners[1].y + c * corners[2].y) / perimeter)
            // The triangle's inradius is its area over half its perimeter; shrinking about the incentre by (radius - inset) / radius
            // moves every side in by `inset`.
            let area = abs((corners[1].x - corners[0].x) * (corners[2].y - corners[0].y)
                           - (corners[2].x - corners[0].x) * (corners[1].y - corners[0].y)) / 2
            let radius = area / (perimeter / 2)
            let factor = (radius - arrowheadStroke / 2) / radius
            return corners.map { CGPoint(x: centre.x + ($0.x - centre.x) * factor, y: centre.y + ($0.y - centre.y) * factor) }
        }
    }
}
