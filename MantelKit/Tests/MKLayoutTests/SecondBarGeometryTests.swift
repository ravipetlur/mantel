import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// The second bar's cells in rows, and its panel under the menu bar.
@Suite("Second bar geometry", .timeLimit(.minutes(1)))
struct SecondBarGeometryTests {
    private func entry(_ name: String, width: CGFloat = 30, startsBlock: Bool = false) -> SecondBarEntry {
        SecondBarEntry(id: ItemID(bundleID: "com.example.\(name)", key: .identifier("main")), title: name, section: .hidden, group: nil,
                       startsBlock: startsBlock, width: width)
    }

    /// The main display of a desk: 3360 points wide, with a 30-point bar.
    private let deskBar = MenuBarGeometry(displayUUID: "desk", rect: CGRect(x: 0, y: 0, width: 3360, height: 30), notch: nil)
    private let deskScreen = CGRect(x: 0, y: 0, width: 3360, height: 1890)
    /// A laptop's notched display: 1728 points wide, with a 33-point bar.
    private let laptopBar = MenuBarGeometry(displayUUID: "laptop", rect: CGRect(x: 0, y: 0, width: 1728, height: 33),
                                            notch: CGRect(x: 771.5, y: 0, width: 185, height: 32))
    private let laptopScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    // MARK: Cells in rows

    @Test func singleRowSize() {
        let layout = SecondBarGeometry.layout(entries: [entry("a"), entry("b"), entry("c")], maxWidth: 1000)
        #expect(layout.rows == 1)
        // Three cells of 30 with 4 between them, and 8 of padding all round; a cell is 26 tall.
        #expect(layout.size == CGSize(width: 114, height: 42))
        #expect(layout.cellFrames == [CGRect(x: 8, y: 8, width: 30, height: 26), CGRect(x: 42, y: 8, width: 30, height: 26),
                                      CGRect(x: 76, y: 8, width: 30, height: 26)])
        // Nothing to lay out is a panel of padding alone.
        let empty = SecondBarGeometry.layout(entries: [], maxWidth: 1000)
        #expect(empty.rows == 0 && empty.cellFrames.isEmpty)
        #expect(empty.size == CGSize(width: 16, height: 16))
    }

    @Test func perEntryWidths() {
        let layout = SecondBarGeometry.layout(entries: [entry("a", width: 30), entry("b", width: 75), entry("c", width: 120)], maxWidth: 1000)
        #expect(layout.cellFrames.map(\.width) == [30, 75, 120])
        #expect(layout.cellFrames.map(\.minX) == [8, 42, 121])
        #expect(layout.size == CGSize(width: 8 + 30 + 4 + 75 + 4 + 120 + 8, height: 42))
    }

    @Test func wrapsAtMaxWidth() {
        let five = (0..<5).map { entry("c\($0)", width: 50) }
        // Room for 124 points of cells (140 less the padding): two cells of 50 and the gap make 104, and a third would end at 158.
        let layout = SecondBarGeometry.layout(entries: five, maxWidth: 140)
        #expect(layout.rows == 3)
        #expect(layout.cellFrames.map(\.minX) == [8, 62, 8, 62, 8])
        #expect(layout.cellFrames.map(\.minY) == [8, 8, 38, 38, 68])
        #expect(layout.size == CGSize(width: 104 + 16, height: 3 * 26 + 2 * 4 + 16))
        // A cell that just fits stays: three of 30 and the gaps make exactly 98.
        let fits = SecondBarGeometry.layout(entries: [entry("a"), entry("b"), entry("c")], maxWidth: 98 + 16)
        #expect(fits.rows == 1)
        #expect(SecondBarGeometry.layout(entries: [entry("a"), entry("b"), entry("c")], maxWidth: 97 + 16).rows == 2)
    }

    @Test func atMostFourRowsTheLastOneScrolls() {
        let many = (0..<12).map { entry("c\($0)", width: 50) }
        let layout = SecondBarGeometry.layout(entries: many, maxWidth: 140)
        #expect(SecondBarGeometry.maxRows == 4)
        // Two cells to a row for three rows, and the rest on the fourth, past the panel's right edge: the view scrolls that row.
        #expect(layout.rows == 4)
        #expect(layout.cellFrames.prefix(6).map(\.minX) == [8, 62, 8, 62, 8, 62])
        #expect(layout.cellFrames.suffix(6).map(\.minY) == Array(repeating: 8 + 3 * 30, count: 6))
        #expect(layout.cellFrames.suffix(6).map(\.minX) == [8, 62, 116, 170, 224, 278])
        // The panel is no wider than it was given room for.
        #expect(layout.size == CGSize(width: 140, height: 4 * 26 + 3 * 4 + 16))
    }

    @Test func separatorAddsWidth() {
        // A cell that starts a block is 8 points further on than it would be.
        let apart = SecondBarGeometry.layout(entries: [entry("a"), entry("b", startsBlock: true), entry("c")], maxWidth: 1000)
        #expect(apart.cellFrames.map(\.minX) == [8, 50, 84])
        #expect(apart.size.width == CGFloat(8 + 106 + 8))
        #expect(SecondBarGeometry.separatorWidth == 8)
        // The first cell has nothing to be apart from, and so has one that begins a row.
        let first = SecondBarGeometry.layout(entries: [entry("a", startsBlock: true), entry("b")], maxWidth: 1000)
        #expect(first.cellFrames.map(\.minX) == [8, 42])
        let wrapped = SecondBarGeometry.layout(entries: [entry("a"), entry("b"), entry("c", startsBlock: true)], maxWidth: 16 + 70)
        #expect(wrapped.rows == 2)
        #expect(wrapped.cellFrames.map(\.minX) == [8, 42, 8])
    }

    // MARK: The panel

    private let size = CGSize(width: 200, height: 42)

    @Test func underAnchorCentres() {
        // Under a dot at x 1000 to 1020, the panel's middle is under the dot's.
        let frame = SecondBarGeometry.frame(size: size, anchor: .under(CGRect(x: 1000, y: 0, width: 20, height: 30)), bar: deskBar, screen: deskScreen)
        #expect(frame == CGRect(x: 910, y: 34, width: 200, height: 42))
        // And under the pointer, the same.
        let pointer = SecondBarGeometry.frame(size: size, anchor: .pointer(CGPoint(x: 1500, y: 700)), bar: deskBar, screen: deskScreen)
        #expect(pointer == CGRect(x: 1400, y: 34, width: 200, height: 42))
    }

    @Test func rightAlignedUsesBarEdge() {
        // The right edge is 8 points in from the bar's.
        let frame = SecondBarGeometry.frame(size: size, anchor: .rightAligned, bar: deskBar, screen: deskScreen)
        #expect(frame == CGRect(x: 3360 - 8 - 200, y: 34, width: 200, height: 42))
        // On a display that is not at the origin it is the bar's edge, not the origin's.
        let other = MenuBarGeometry(displayUUID: "other", rect: CGRect(x: 3360, y: 0, width: 1728, height: 33), notch: nil)
        let beside = SecondBarGeometry.frame(size: size, anchor: .rightAligned, bar: other, screen: CGRect(x: 3360, y: 0, width: 1728, height: 1117))
        #expect(beside == CGRect(x: 3360 + 1728 - 8 - 200, y: 37, width: 200, height: 42))
    }

    @Test func clampedToScreen() {
        // A dot near the left edge: the panel is kept 8 points inside it.
        let left = SecondBarGeometry.frame(size: size, anchor: .under(CGRect(x: 10, y: 0, width: 20, height: 30)), bar: deskBar, screen: deskScreen)
        #expect(left.minX == 8)
        // And near the right.
        let right = SecondBarGeometry.frame(size: size, anchor: .pointer(CGPoint(x: 3355, y: 100)), bar: deskBar, screen: deskScreen)
        #expect(right.maxX == CGFloat(3360 - 8))
        // On a display that is not at the origin the margin is from its own edges.
        let beside = CGRect(x: 3360, y: 0, width: 1728, height: 1117)
        let other = MenuBarGeometry(displayUUID: "other", rect: CGRect(x: 3360, y: 0, width: 1728, height: 33), notch: nil)
        #expect(SecondBarGeometry.frame(size: size, anchor: .pointer(CGPoint(x: 3361, y: 0)), bar: other, screen: beside).minX == 3368)
        // A panel that is taller than the room under the bar is moved up and made no taller than the screen allows.
        let short = CGRect(x: 0, y: 0, width: 1728, height: 50)
        let low = SecondBarGeometry.frame(size: size, anchor: .rightAligned, bar: laptopBar, screen: short)
        #expect(low == CGRect(x: 1728 - 8 - 200, y: 8, width: 200, height: 34))
        // A panel that is wider than the screen is made as wide as the room there is.
        let wide = SecondBarGeometry.frame(size: CGSize(width: 5000, height: 42), anchor: .rightAligned, bar: deskBar, screen: deskScreen)
        #expect(wide == CGRect(x: 8, y: 34, width: 3344, height: 42))
    }

    @Test func topBelowBar() {
        // 30 points of bar and a gap of 4 on the desk's display; 33 and 4 on the notched one.
        let desk = SecondBarGeometry.frame(size: size, anchor: .rightAligned, bar: deskBar, screen: deskScreen)
        #expect(desk.minY == 34)
        let laptop = SecondBarGeometry.frame(size: size, anchor: .rightAligned, bar: laptopBar, screen: laptopScreen)
        #expect(laptop == CGRect(x: 1728 - 8 - 200, y: 37, width: 200, height: 42))
        // Whatever the anchor, the top is the same.
        let under = SecondBarGeometry.frame(size: size, anchor: .under(CGRect(x: 900, y: 0, width: 20, height: 33)), bar: laptopBar, screen: laptopScreen)
        #expect(under.minY == 37)
        #expect(SecondBarGeometry.gapBelowBar == 4 && SecondBarGeometry.screenMargin == 8)
        #expect(SecondBarGeometry.cellHeight == 26 && SecondBarGeometry.spacing == 4 && SecondBarGeometry.padding == 8)
    }
}
