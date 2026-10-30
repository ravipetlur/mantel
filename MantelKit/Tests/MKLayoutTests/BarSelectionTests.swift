import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// Which cell of the second bar the keyboard has selected, and how the keys move it.
@Suite("Bar selection", .timeLimit(.minutes(1)))
struct BarSelectionTests {
    private func cell(_ x: CGFloat, _ y: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: 26)
    }

    /// Two rows. Row one holds cells 0 to 2 (middles at 23, 102 and 181); row two holds 3 and 4 (middles at 58 and 162).
    private var twoRows: SecondBarLayout {
        SecondBarLayout(size: CGSize(width: 220, height: 72), rows: 2, cellFrames: [
            cell(8, 8, width: 30), cell(42, 8, width: 120), cell(166, 8, width: 30),
            cell(8, 38, width: 100), cell(112, 38, width: 100),
        ])
    }

    private var oneRow: SecondBarLayout {
        SecondBarLayout(size: CGSize(width: 114, height: 42), rows: 1, cellFrames: [
            cell(8, 8, width: 30), cell(42, 8, width: 30), cell(76, 8, width: 30),
        ])
    }

    @Test func firstArrowSelectsFirst() {
        for key in [BarKey.left, .right, .up, .down] {
            var selection = BarSelection(layout: twoRows)
            #expect(selection.index == nil)
            #expect(selection.handle(key) == .moved(0), "\(key)")
            #expect(selection.index == 0)
        }
        // Home and End go where they say, selection or none.
        var fresh = BarSelection(layout: twoRows)
        #expect(fresh.handle(.end) == .moved(4))
        var home = BarSelection(layout: twoRows)
        #expect(home.handle(.home) == .moved(0))
    }

    @Test func arrowsDontWrap() {
        var selection = BarSelection(layout: twoRows)
        _ = selection.handle(.right)
        // The first cell: nothing is left of it, nor above it.
        #expect(selection.handle(.left) == .ignored)
        #expect(selection.handle(.up) == .ignored)
        #expect(selection.index == 0)
        // Along the row to its end, and no further: the cell after the row's last is in the next row, and isn't reached by →.
        #expect(selection.handle(.right) == .moved(1))
        #expect(selection.handle(.right) == .moved(2))
        #expect(selection.handle(.right) == .ignored)
        #expect(selection.index == 2)
        // The first cell of the second row has nothing to its left either, though cell 2 is before it.
        selection.hover(3)
        #expect(selection.handle(.left) == .ignored)
        #expect(selection.index == 3)
        // The last row has nothing under it.
        #expect(selection.handle(.down) == .ignored)
        selection.hover(4)
        #expect(selection.handle(.right) == .ignored)
        #expect(selection.handle(.down) == .ignored)
        #expect(selection.index == 4)
        // Home and End are the first and the last.
        #expect(selection.handle(.home) == .moved(0))
        #expect(selection.handle(.end) == .moved(4))
        #expect(selection.handle(.end) == .ignored)
    }

    @Test func tabWraps() {
        var selection = BarSelection(layout: oneRow)
        // With nothing selected, Tab starts at the first and ⇧Tab at the last.
        #expect(selection.handle(.tab(backwards: false)) == .moved(0))
        #expect(selection.handle(.tab(backwards: false)) == .moved(1))
        #expect(selection.handle(.tab(backwards: false)) == .moved(2))
        #expect(selection.handle(.tab(backwards: false)) == .moved(0), "after the last, the first")
        #expect(selection.handle(.tab(backwards: true)) == .moved(2), "before the first, the last")
        #expect(selection.handle(.tab(backwards: true)) == .moved(1))
        var backwards = BarSelection(layout: oneRow)
        #expect(backwards.handle(.tab(backwards: true)) == .moved(2))
        // Rows make no difference to Tab: it goes through the cells in order.
        var rows = BarSelection(layout: twoRows)
        rows.hover(2)
        #expect(rows.handle(.tab(backwards: false)) == .moved(3))
    }

    @Test func upDownGoToNearestInX() {
        var selection = BarSelection(layout: twoRows)
        // Down: from cell 0 (middle 23) the nearest middle in the second row is 58; from cell 1 (102) it is 58 again (44 against 60);
        // from cell 2 (181) it is 162.
        selection.hover(0)
        #expect(selection.handle(.down) == .moved(3))
        selection.hover(1)
        #expect(selection.handle(.down) == .moved(3))
        selection.hover(2)
        #expect(selection.handle(.down) == .moved(4))
        // Up: from cell 4 (162) the nearest above is cell 2 (181); from cell 3 (58) it is cell 0 (23, against 102).
        #expect(selection.handle(.up) == .moved(2))
        selection.hover(3)
        #expect(selection.handle(.up) == .moved(0))
        // Two that are as near: the left one.
        let tie = SecondBarLayout(size: CGSize(width: 200, height: 72), rows: 2, cellFrames: [
            cell(85, 8, width: 30), cell(45, 38, width: 30), cell(125, 38, width: 30),
        ])
        var tied = BarSelection(layout: tie)
        tied.hover(0)
        #expect(tied.handle(.down) == .moved(1))
    }

    @Test func returnKindsActivate() {
        var selection = BarSelection(layout: oneRow)
        selection.hover(1)
        // Return clicks, ⌥Return option-clicks and ⌘Return right-clicks: the kind comes with the key, and the selection stays.
        #expect(selection.handle(.returnKey(.left)) == .activate(1, .left))
        #expect(selection.handle(.returnKey(.option)) == .activate(1, .option))
        #expect(selection.handle(.returnKey(.right)) == .activate(1, .right))
        #expect(selection.index == 1)
        #expect(BarKey.forReturn(option: false, command: false) == .returnKey(.left))
        #expect(BarKey.forReturn(option: true, command: false) == .returnKey(.option))
        #expect(BarKey.forReturn(option: false, command: true) == .returnKey(.right))
        #expect(BarKey.forReturn(option: true, command: true) == .returnKey(.right))
    }

    @Test func escapeCloses() {
        var selection = BarSelection(layout: oneRow)
        #expect(selection.handle(.escape) == .close)
        selection.hover(2)
        #expect(selection.handle(.escape) == .close)
        #expect(selection.index == 2, "closing is the bar's doing, not the selection's")
        var empty = BarSelection(layout: SecondBarGeometry.layout(entries: [], maxWidth: 100))
        #expect(empty.handle(.escape) == .close)
    }

    @Test func returnWithoutSelectionIgnored() {
        var selection = BarSelection(layout: oneRow)
        for kind in ClickKind.allCases {
            #expect(selection.handle(.returnKey(kind)) == .ignored)
        }
        // A bar with nothing in it takes no movement either.
        var empty = BarSelection(layout: SecondBarGeometry.layout(entries: [], maxWidth: 100))
        for key in [BarKey.left, .right, .up, .down, .home, .end, .tab(backwards: false), .tab(backwards: true), .returnKey(.left)] {
            #expect(empty.handle(key) == .ignored, "\(key)")
        }
        #expect(empty.index == nil)
    }

    @Test func hoverSelects() {
        var selection = BarSelection(layout: twoRows)
        selection.hover(3)
        #expect(selection.index == 3)
        // The keys go on from where the pointer put the selection.
        #expect(selection.handle(.right) == .moved(4))
        selection.hover(nil)
        #expect(selection.index == nil, "the pointer left the cells")
        // A cell that isn't there is no selection.
        selection.hover(1)
        selection.hover(9)
        #expect(selection.index == nil)
        selection.hover(-1)
        #expect(selection.index == nil)
    }

    @Test func layoutFromGeometryHasItsRowsRight() {
        // Selection reads rows from the frames, so it works on what the geometry makes.
        let entries = (0..<5).map {
            SecondBarEntry(id: ItemID(bundleID: "com.example.c\($0)", key: .identifier("main")), title: "c", section: .hidden, group: nil,
                           startsBlock: false, width: 50)
        }
        let layout = SecondBarGeometry.layout(entries: entries, maxWidth: 140)
        #expect(layout.rows == 3)
        var selection = BarSelection(layout: layout)
        selection.hover(1)
        #expect(selection.handle(.right) == .ignored, "cell 1 ends its row")
        #expect(selection.handle(.down) == .moved(3))
        #expect(selection.handle(.down) == .moved(4))
        #expect(selection.handle(.up) == .moved(2), "the cell straight above")
    }
}
