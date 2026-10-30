import AppKit
import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Dot glyphs", .timeLimit(.minutes(1)))
struct DotGlyphTests {
    private let symbols = DotGlyphStyle.symbol(hidden: "star", always: "moon")
    private let pictures = DotGlyphStyle.image(hiddenLight: "aaaaaaaa.png", hiddenDark: "bbbbbbbb.png",
                                               alwaysLight: "cccccccc.pdf", alwaysDark: "dddddddd.pdf")

    private func glyph(_ dot: DotKind, open: Bool, _ style: DotGlyphStyle, darkBar: Bool = false,
                       existing: Set<String> = []) -> DotGlyph {
        DotGlyphs.glyph(dot, open: open, style: style, darkBar: darkBar, symbolExists: { existing.contains($0) })
    }

    // MARK: Dots

    @Test func dotsMatchTheCircleGeometry() {
        // • is a circle 6 points across in the middle of the 18-point box; •• is two of 5 points, 3 points apart.
        let hidden = [CGRect(x: 6, y: 6, width: 6, height: 6)]
        let always = [CGRect(x: 2.5, y: 6.5, width: 5, height: 5), CGRect(x: 10.5, y: 6.5, width: 5, height: 5)]
        #expect(glyph(.hidden, open: true, .dots) == .circles(rects: hidden, filled: true))
        #expect(glyph(.hidden, open: false, .dots) == .circles(rects: hidden, filled: false))
        #expect(glyph(.always, open: true, .dots) == .circles(rects: always, filled: true))
        #expect(glyph(.always, open: false, .dots) == .circles(rects: always, filled: false))
        // The gap between the two circles of ••, and that each is inside the box.
        #expect(always[1].minX - always[0].maxX == 3)
        for rect in hidden + always {
            #expect(CGRect(x: 0, y: 0, width: 18, height: 18).contains(rect))
        }
        // The dots never look at the bar's colour or at symbols.
        #expect(glyph(.hidden, open: true, .dots, darkBar: true) == glyph(.hidden, open: true, .dots, darkBar: false))
    }

    // MARK: Chevrons

    @Test func chevronsCountAndFill() {
        #expect(glyph(.hidden, open: true, .chevrons) == .arrowheads(count: 1, filled: true))
        #expect(glyph(.hidden, open: false, .chevrons) == .arrowheads(count: 1, filled: false))
        #expect(glyph(.always, open: true, .chevrons) == .arrowheads(count: 2, filled: true))
        #expect(glyph(.always, open: false, .chevrons) == .arrowheads(count: 2, filled: false))
    }

    @Test func arrowheadPolygonsInBox() {
        let box = CGRect(x: 0, y: 0, width: 18, height: 18)
        for count in [1, 2] {
            let polygons = DotGlyphs.arrowheadPath(count: count)
            #expect(polygons.count == count)
            for polygon in polygons {
                #expect(polygon.count == 3)
                for point in polygon {
                    #expect(box.contains(point), "\(point) is in the box")
                }
            }
            // Each head is 6 points wide and 8 tall, pointing left: the tip is the first corner, on the middle line, and the other two
            // are on the same vertical edge at its right.
            for polygon in polygons {
                let xs = polygon.map(\.x), ys = polygon.map(\.y)
                #expect(xs.max()! - xs.min()! == 6)
                #expect(ys.max()! - ys.min()! == 8)
                #expect(polygon[0].x == xs.min()! && polygon[0].y == 9)
                #expect(polygon[1].x == polygon[2].x && polygon[1].x == xs.max()!)
                #expect(polygon[1].y != polygon[2].y)
            }
            // Together they are centred in the box, both ways.
            let all = polygons.flatMap { $0 }
            #expect((all.map(\.x).min()! + all.map(\.x).max()!) / 2 == 9)
            #expect((all.map(\.y).min()! + all.map(\.y).max()!) / 2 == 9)
        }
        // Two heads are 4 points apart: the right edge of the first to the tip of the second.
        let two = DotGlyphs.arrowheadPath(count: 2)
        #expect(two[1][0].x - two[0][1].x == 4)
        // One head's tip and its right edge are 6 points apart, and it is centred: 6 to 12.
        #expect(DotGlyphs.arrowheadPath(count: 1)[0][0].x == 6)
        #expect(DotGlyphs.arrowheadPath(count: 1)[0][1].x == 12)
        // A count that doesn't fit the box is the most that does, and none is none.
        #expect(DotGlyphs.arrowheadPath(count: 5).count == 2)
        #expect(DotGlyphs.arrowheadPath(count: 0).isEmpty)
        #expect(DotGlyphs.arrowheadPath(count: -1).isEmpty)
    }

    @Test func outlinedArrowheadsAreTheSizeOfSolidOnes() {
        // The stroke reaches half its width past the outline's corners (round joins), so the outline's tips plus that are the solid ones.
        let half = DotGlyphs.arrowheadStroke / 2
        for count in [1, 2] {
            let solid = DotGlyphs.arrowheadPath(count: count)
            let outline = DotGlyphs.arrowheadOutlinePath(count: count)
            #expect(outline.count == solid.count)
            for (s, o) in zip(solid, outline) {
                // Every corner moved inward, and every side of the outline is `half` inside the same side of the solid head.
                for index in 0..<3 {
                    let next = (index + 1) % 3
                    let (p, q) = (s[index], s[next]), (u, v) = (o[index], o[next])
                    let length = hypot(q.x - p.x, q.y - p.y)
                    let distance = abs((q.x - p.x) * (p.y - u.y) - (p.x - u.x) * (q.y - p.y)) / length
                    let distanceV = abs((q.x - p.x) * (p.y - v.y) - (p.x - v.x) * (q.y - p.y)) / length
                    #expect(abs(distance - half) < 1e-9 && abs(distanceV - half) < 1e-9)
                }
            }
        }
    }

    // MARK: Symbols

    @Test func symbolUsesFillWhenExists() {
        // Open: the filled form of the name, when the system has one, at full strength.
        #expect(glyph(.hidden, open: true, symbols, existing: ["star.fill"]) == .symbol(name: "star.fill", opacity: 1))
        #expect(glyph(.always, open: true, symbols, existing: ["star.fill", "moon.fill"]) == .symbol(name: "moon.fill", opacity: 1))
        // Closed: the plain name, dimmed, even when there is a filled form.
        #expect(glyph(.hidden, open: false, symbols, existing: ["star.fill"]) == .symbol(name: "star", opacity: DotGlyphs.closedOpacity))
        #expect(glyph(.always, open: false, symbols, existing: ["moon.fill"]) == .symbol(name: "moon", opacity: DotGlyphs.closedOpacity))
    }

    @Test func symbolWithoutFillUsesOpacity() {
        #expect(DotGlyphs.closedOpacity == 0.55)
        // No filled form: open is the name at full strength, closed the name at 55 %.
        #expect(glyph(.hidden, open: true, symbols) == .symbol(name: "star", opacity: 1))
        #expect(glyph(.always, open: true, symbols) == .symbol(name: "moon", opacity: 1))
        #expect(glyph(.hidden, open: false, symbols) == .symbol(name: "star", opacity: 0.55))
        #expect(glyph(.always, open: false, symbols) == .symbol(name: "moon", opacity: 0.55))
        // A filled form of the other dot's symbol doesn't count.
        #expect(glyph(.hidden, open: true, symbols, existing: ["moon.fill"]) == .symbol(name: "star", opacity: 1))
    }

    @Test func theBarsColourDoesNotChangeASymbol() {
        #expect(glyph(.hidden, open: false, symbols, darkBar: true) == glyph(.hidden, open: false, symbols, darkBar: false))
    }

    // MARK: Pictures

    @Test func imageUsesDarkOnDarkBar() {
        #expect(glyph(.hidden, open: true, pictures, darkBar: true) == .image(fileName: "bbbbbbbb.png", opacity: 1))
        #expect(glyph(.always, open: true, pictures, darkBar: true) == .image(fileName: "dddddddd.pdf", opacity: 1))
        #expect(glyph(.hidden, open: false, pictures, darkBar: true) == .image(fileName: "bbbbbbbb.png", opacity: 0.55))
        #expect(glyph(.always, open: false, pictures, darkBar: true) == .image(fileName: "dddddddd.pdf", opacity: 0.55))
        // On a light bar it is the light one.
        #expect(glyph(.hidden, open: true, pictures, darkBar: false) == .image(fileName: "aaaaaaaa.png", opacity: 1))
        #expect(glyph(.always, open: false, pictures, darkBar: false) == .image(fileName: "cccccccc.pdf", opacity: 0.55))
    }

    @Test func imageFallsBackToLight() {
        // No dark file: the light one is used on a dark bar too.
        let lightOnly = DotGlyphStyle.image(hiddenLight: "aaaaaaaa.png", hiddenDark: nil, alwaysLight: "cccccccc.png", alwaysDark: nil)
        #expect(glyph(.hidden, open: true, lightOnly, darkBar: true) == .image(fileName: "aaaaaaaa.png", opacity: 1))
        #expect(glyph(.always, open: false, lightOnly, darkBar: true) == .image(fileName: "cccccccc.png", opacity: 0.55))
        // A dark file for one dot only is used for that dot only.
        let oneDark = DotGlyphStyle.image(hiddenLight: "aaaaaaaa.png", hiddenDark: "bbbbbbbb.png", alwaysLight: "cccccccc.png", alwaysDark: nil)
        #expect(glyph(.hidden, open: true, oneDark, darkBar: true) == .image(fileName: "bbbbbbbb.png", opacity: 1))
        #expect(glyph(.always, open: true, oneDark, darkBar: true) == .image(fileName: "cccccccc.png", opacity: 1))
        // A dark file with no name is no dark file.
        let blank = DotGlyphStyle.image(hiddenLight: "aaaaaaaa.png", hiddenDark: "", alwaysLight: "cccccccc.png", alwaysDark: "")
        #expect(glyph(.hidden, open: true, blank, darkBar: true) == .image(fileName: "aaaaaaaa.png", opacity: 1))
    }

    // MARK: Groups

    @Test func groupSymbolNameExists() {
        // The look a group has until the person chooses another is a symbol the system has.
        #expect(GroupLook.standard == .symbol("square.grid.2x2"))
        #expect(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) != nil)
    }
}
