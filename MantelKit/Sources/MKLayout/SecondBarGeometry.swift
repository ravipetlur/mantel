import CoreGraphics
import MKCore

/// What the second bar is put under, in CoreGraphics global points (the origin top-left of the main display, y down).
public enum SecondBarAnchor: Sendable, Equatable {
    /// Under this frame, which is the dot that was clicked: the bar's middle is under the frame's middle.
    case under(CGRect)
    /// Under the pointer.
    case pointer(CGPoint)
    /// Against the right edge of the bar.
    case rightAligned
}

/// Where the cells of the second bar go, and how big the panel is.
public struct SecondBarLayout: Sendable, Equatable {
    /// The panel's size. At most as wide as the width it was laid out for.
    public let size: CGSize
    /// How many rows of cells there are: none for a bar with no cells.
    public let rows: Int
    /// The frame of each cell, in the order of the entries, in the panel's own points (the origin at its top-left corner). The cells of a
    /// last row that is longer than the panel are past its right edge: the view scrolls that row horizontally.
    public let cellFrames: [CGRect]

    public init(size: CGSize, rows: Int, cellFrames: [CGRect]) {
        self.size = size
        self.rows = rows
        self.cellFrames = cellFrames
    }
}

/// The second bar's measures, and the arithmetic that puts its cells in rows and its panel under the menu bar.
public enum SecondBarGeometry {
    /// How tall a cell is.
    public static let cellHeight: CGFloat = 26
    /// How narrow and how wide a cell can be: an icon's slot width is brought into this range.
    public static let minimumCellWidth: CGFloat = 30
    public static let maximumCellWidth: CGFloat = 120
    /// The gap between cells, across and down.
    public static let spacing: CGFloat = 4
    /// What a thin separator between two blocks of cells adds to the gap between them. It is drawn in the middle of that gap.
    public static let separatorWidth: CGFloat = 8
    /// The room between the cells and the panel's edge, on every side.
    public static let padding: CGFloat = 8
    /// How many rows of cells the panel has at most. Beyond that the last row goes on to the right, and scrolls.
    public static let maxRows = 4
    /// The room kept between the panel and the edges of the screen.
    public static let screenMargin: CGFloat = 8
    /// The gap between the menu bar and the panel under it.
    public static let gapBelowBar: CGFloat = 4

    /// How wide the cell for an icon is: its slot's width, brought into 30 to 120 points; 30 for one whose slot was never seen.
    public static func cellWidth(slotWidth: CGFloat?) -> CGFloat {
        min(max(slotWidth ?? minimumCellWidth, minimumCellWidth), maximumCellWidth)
    }

    /// Puts the entries' cells in rows, left to right, each at its own width.
    ///
    /// - **Between cells** there is `spacing`. A cell that starts a block adds `separatorWidth` to that gap, except at the start of a row,
    ///   where there is nothing to separate it from.
    /// - **A row wraps** when the next cell would end past `maxWidth` less the padding on both sides, as long as there are fewer than
    ///   `maxRows` rows. The last of the `maxRows` rows is never wrapped: the panel is no wider than `maxWidth`, and the row scrolls.
    /// - **The size** is the cells and `padding` on every side. A cell wider than the room is alone on its row.
    public static func layout(entries: [SecondBarEntry], maxWidth: CGFloat) -> SecondBarLayout {
        guard !entries.isEmpty else {
            return SecondBarLayout(size: CGSize(width: 2 * padding, height: 2 * padding), rows: 0, cellFrames: [])
        }
        let room = max(0, maxWidth - 2 * padding)
        var frames: [CGRect] = []
        var row = 0
        // Where the last cell of the row ends, and nil while the row has none.
        var end: CGFloat?
        var widest: CGFloat = 0
        for entry in entries {
            var start = end.map { $0 + spacing + (entry.startsBlock ? separatorWidth : 0) } ?? 0
            if end != nil, start + entry.width > room, row + 1 < maxRows {
                row += 1
                start = 0
            }
            frames.append(CGRect(x: padding + start, y: padding + CGFloat(row) * (cellHeight + spacing), width: entry.width,
                                 height: cellHeight))
            end = start + entry.width
            widest = max(widest, start + entry.width)
        }
        let rows = row + 1
        return SecondBarLayout(size: CGSize(width: min(widest, room) + 2 * padding,
                                            height: CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing + 2 * padding),
                               rows: rows, cellFrames: frames)
    }

    /// The panel's frame in CoreGraphics global points: under the bar, with `gapBelowBar` between them, under the anchor, and kept on the
    /// screen with `screenMargin` to spare (it is made smaller than that if it must be).
    ///
    /// - `.under(rect)` and `.pointer` put the panel's middle under the anchor's. `.rightAligned` puts its right edge `screenMargin` in
    ///   from the bar's.
    /// - The top is the bar's bottom edge plus `gapBelowBar` (y grows downwards).
    public static func frame(size: CGSize, anchor: SecondBarAnchor, bar: MenuBarGeometry, screen: CGRect) -> CGRect {
        let room = screen.insetBy(dx: screenMargin, dy: screenMargin)
        let width = min(size.width, room.width)
        let height = min(size.height, room.height)
        let left: CGFloat = switch anchor {
        case .under(let rect): rect.midX - width / 2
        case .pointer(let point): point.x - width / 2
        case .rightAligned: bar.rect.maxX - screenMargin - width
        }
        let top = bar.rect.maxY + gapBelowBar
        return CGRect(x: min(max(left, room.minX), room.maxX - width), y: min(max(top, room.minY), room.maxY - height),
                      width: width, height: height)
    }
}
