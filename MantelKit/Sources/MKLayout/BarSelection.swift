import CoreGraphics
import MKCore

/// A key the second bar answers to.
public enum BarKey: Sendable, Equatable {
    case left, right, up, down, home, end
    /// Tab, or ⇧Tab for `backwards`.
    case tab(backwards: Bool)
    /// Return, with the kind of click the modifiers make of it (`forReturn(option:command:)`).
    case returnKey(ClickKind)
    case escape

    /// The key for Return with these modifiers held: Return clicks, ⌥Return option-clicks and ⌘Return right-clicks (⌘ wins when both are
    /// held).
    public static func forReturn(option: Bool, command: Bool) -> BarKey {
        .returnKey(command ? .right : option ? .option : .left)
    }
}

/// What a key did to the selection.
public enum BarKeyResult: Sendable, Equatable {
    /// The selection is now this cell.
    case moved(Int)
    /// Click this cell, in this way.
    case activate(Int, ClickKind)
    /// The bar is to close.
    case close
    /// Nothing happened: the selection is where it was, or the key isn't one the bar answers.
    case ignored
}

/// Which cell of the second bar the keyboard has selected, and how the keys move it. The bar draws the selection itself.
///
/// - **Left and right** move along the cell's row, and stop at its ends.
/// - **Up and down** move to the cell of the next row that is nearest the selected one across, and stop at the first and last rows.
/// - **The first arrow** when nothing is selected selects the first cell, whichever arrow it is.
/// - **Home and End** select the first and the last cell.
/// - **Tab and ⇧Tab** select the next and the previous cell, and wrap.
/// - **Return** clicks the selected cell, in the way the key says; with nothing selected it does nothing.
/// - **Escape** closes the bar.
public struct BarSelection: Sendable, Equatable {
    /// The cells' frames, and the row each is in.
    private let frames: [CGRect]
    private let rowOfCell: [Int]

    /// The selected cell, nil while none is.
    public private(set) var index: Int?

    public init(layout: SecondBarLayout) {
        frames = layout.cellFrames
        // A row is a distinct top edge: the cells' frames are in the order they were laid out, rows from the top.
        var tops: [CGFloat] = []
        rowOfCell = layout.cellFrames.map { frame in
            if let known = tops.firstIndex(where: { abs($0 - frame.minY) < 0.5 }) { return known }
            tops.append(frame.minY)
            return tops.count - 1
        }
    }

    /// Takes a key. The result says what the bar is to do about it.
    public mutating func handle(_ key: BarKey) -> BarKeyResult {
        switch key {
        case .escape:
            return .close
        case .returnKey(let kind):
            guard let index else { return .ignored }
            return .activate(index, kind)
        case .left, .right, .up, .down, .home, .end, .tab:
            guard !frames.isEmpty else { return .ignored }
            guard let current = index else {
                return select(firstSelection(for: key))
            }
            return select(target(from: current, for: key))
        }
    }

    /// The pointer is over a cell, or over none (nil): that cell is selected.
    public mutating func hover(_ index: Int?) {
        self.index = index.flatMap { frames.indices.contains($0) ? $0 : nil }
    }

    // MARK: Moving

    private mutating func select(_ target: Int) -> BarKeyResult {
        guard target != index else { return .ignored }
        index = target
        return .moved(target)
    }

    /// The cell a key selects when none is: the first, except for the keys that go to the end.
    private func firstSelection(for key: BarKey) -> Int {
        switch key {
        case .end, .tab(backwards: true): frames.count - 1
        default: 0
        }
    }

    private func target(from current: Int, for key: BarKey) -> Int {
        switch key {
        case .home: 0
        case .end: frames.count - 1
        case .tab(let backwards): backwards ? (current + frames.count - 1) % frames.count : (current + 1) % frames.count
        case .left: current > 0 && rowOfCell[current - 1] == rowOfCell[current] ? current - 1 : current
        case .right: current + 1 < frames.count && rowOfCell[current + 1] == rowOfCell[current] ? current + 1 : current
        case .up: nearest(inRow: rowOfCell[current] - 1, to: current) ?? current
        case .down: nearest(inRow: rowOfCell[current] + 1, to: current) ?? current
        case .returnKey, .escape: current
        }
    }

    /// The cell of a row whose middle is nearest the middle of `cell`: the left-most of two that are as near. Nil for a row there isn't.
    private func nearest(inRow row: Int, to cell: Int) -> Int? {
        let middle = frames[cell].midX
        var best: Int?
        for index in frames.indices where rowOfCell[index] == row {
            guard let held = best else {
                best = index
                continue
            }
            if abs(frames[index].midX - middle) < abs(frames[held].midX - middle) { best = index }
        }
        return best
    }
}
