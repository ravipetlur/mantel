import AppKit
import MKCore
import MKLayout
import Observation
import SwiftUI

/// What the second bar and a group panel show and where the keyboard and the pointer are in it. The view draws it and the container view
/// (`BarContainerView`) changes it; the decisions are the package's (`SecondBarGeometry`, `BarSelection`, `PanelMath`).
@MainActor
@Observable
final class IconBarModel {
    private(set) var entries: [SecondBarEntry] = []
    private(set) var layout = SecondBarLayout(size: .zero, rows: 0, cellFrames: [])
    /// How far the last row, when it runs past the panel's right edge, is scrolled to the left.
    private(set) var scroll: CGFloat = 0
    /// The cell the pointer is over.
    var hovered: Int?
    /// The cell the keyboard has selected; nil until a key picks one.
    private(set) var selected: Int?
    @ObservationIgnored private var selection = BarSelection(layout: SecondBarLayout(size: .zero, rows: 0, cellFrames: []))
    var style = PanelStyle()

    /// Shows these cells. The keyboard's selection stays on its icon (found by its ID) while that icon is still listed, and so does the
    /// scroll while the list is the same: a read that only changes a width must not take the selection away in the middle of arrowing.
    func set(entries: [SecondBarEntry], layout: SecondBarLayout) {
        guard entries != self.entries || layout != self.layout else { return }
        let keptID = selected.flatMap { self.entries[safe: $0]?.id }
        let sameList = entries.map(\.id) == self.entries.map(\.id)
        let keptScroll = scroll
        self.entries = entries
        self.layout = layout
        selection = BarSelection(layout: layout)
        if let keptID, let place = entries.firstIndex(where: { $0.id == keptID }) {
            selection.hover(place)
        }
        selected = selection.index
        hovered = nil
        scroll = sameList ? min(keptScroll, overflow) : 0
    }

    /// How far the last row runs past the room it has: 0 when every row fits.
    private var overflow: CGFloat {
        guard let last = lastRowCells.max(by: { layout.cellFrames[$0].maxX < layout.cellFrames[$1].maxX }) else { return 0 }
        return max(0, layout.cellFrames[last].maxX + SecondBarGeometry.padding - layout.size.width)
    }

    private var lastRowCells: [Int] {
        guard let top = layout.cellFrames.map(\.minY).max() else { return [] }
        return layout.cellFrames.indices.filter { abs(layout.cellFrames[$0].minY - top) < 0.5 }
    }

    /// The cells as they are drawn: the last row moved by the scroll.
    var shownLayout: SecondBarLayout {
        guard scroll > 0 else { return layout }
        let row = Set(lastRowCells)
        let frames = layout.cellFrames.enumerated().map { place, frame in row.contains(place) ? frame.offsetBy(dx: -scroll, dy: 0) : frame }
        return SecondBarLayout(size: layout.size, rows: layout.rows, cellFrames: frames)
    }

    /// Scrolls the last row by `delta` points (positive moves it to the left), within what it runs past.
    func scrollBy(_ delta: CGFloat) {
        scroll = min(max(0, scroll + delta), overflow)
    }

    func handle(_ key: BarKey) -> BarKeyResult {
        let result = selection.handle(key)
        selected = selection.index
        if case .moved(let cell) = result { bringIntoView(cell) }
        return result
    }

    /// Scrolls the last row so that a cell the keyboard selected in it is on the panel.
    private func bringIntoView(_ cell: Int) {
        guard lastRowCells.contains(cell) else { return }
        let frame = layout.cellFrames[cell]
        let padding = SecondBarGeometry.padding
        if frame.maxX - scroll > layout.size.width - padding {
            scrollBy(frame.maxX - scroll - (layout.size.width - padding))
        } else if frame.minX - scroll < padding {
            scrollBy(frame.minX - scroll - padding)
        }
    }
}

/// The cells of the second bar or a group's panel on the panel's background: each entry's picture centred in a cell of its own width, a
/// thin line between blocks, a fill under the pointer and an accent-coloured outline round the cell the keyboard has selected.
///
/// It only draws. Clicks, the pointer, scrolling and keys are the container's (`BarContainerView`), which asks `PanelMath` which cell
/// they are on. Each cell is a button for VoiceOver, named by its title, and answers its press.
struct IconBarView: View {
    static let cellRadius: CGFloat = 6

    let model: IconBarModel
    let images: ItemImages
    let activate: (Int, ClickKind) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = model.shownLayout
        ZStack(alignment: .topLeading) {
            PanelBackgroundView(style: model.style)
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { place, entry in
                let frame = shown.cellFrames[place]
                cell(entry, place: place, frame: frame)
                if entry.startsBlock, let line = separator(before: place, in: shown) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: SecondBarGeometry.cellHeight - 8)
                        .offset(x: line.x - 0.5, y: line.y + 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: model.layout.size.width, height: model.layout.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: PanelBackgroundView.cornerRadius, style: .continuous))
    }

    private func cell(_ entry: SecondBarEntry, place: Int, frame: CGRect) -> some View {
        let image = images.image(for: entry.id, appearance: colorScheme == .dark ? .dark : .light)
        let size = PanelMath.imageSize(natural: image.size, in: frame.size)
        return ZStack {
            if model.hovered == place {
                RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor))
            }
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
            if model.selected == place {
                RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(place, .left) }
    }

    /// Where the line between two blocks goes: the middle of the gap before the cell, on its row; none at the start of a row.
    private func separator(before place: Int, in layout: SecondBarLayout) -> CGPoint? {
        guard place > 0 else { return nil }
        let previous = layout.cellFrames[place - 1], frame = layout.cellFrames[place]
        guard abs(previous.minY - frame.minY) < 0.5 else { return nil }
        return CGPoint(x: (previous.maxX + frame.minX) / 2, y: frame.minY)
    }
}

/// The view a panel's content is: it takes every click, the pointer's movement, scrolling and key presses that fall on the panel, and
/// puts the cells (a SwiftUI view, which only draws) inside itself.
///
/// - **A click** is on the cell `PanelMath.cell(at:in:)` says: a plain click is a left click, ⌥ makes it an option click, and a right
///   click (or ⌃-click) a right one. A first click on a panel that isn't key still works (`acceptsFirstMouse`).
/// - **Keys** go through `BarKey.forKeyCode`; the ones the bar doesn't answer to are passed on (`super`).
/// - **The tooltip** of a cell is its entry's title.
final class BarContainerView: NSView {
    private let model: IconBarModel
    private let hosting: NSHostingView<IconBarView>
    private let activate: (Int, ClickKind) -> Void
    private let close: () -> Void
    private var tracking: NSTrackingArea?

    init(model: IconBarModel, images: ItemImages, activate: @escaping (Int, ClickKind) -> Void, close: @escaping () -> Void) {
        self.model = model
        self.activate = activate
        self.close = close
        hosting = NSHostingView(rootView: IconBarView(model: model, images: images, activate: activate))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PanelBackgroundView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The cells are drawn by the hosting view below; every event is this view's.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        model.hovered = cell(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        model.hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        // The second press of a double-click is not another click.
        guard event.clickCount <= 1, let cell = cell(at: event) else { return }
        let kind: ClickKind = event.modifierFlags.contains(.control) ? .right : event.modifierFlags.contains(.option) ? .option : .left
        activate(cell, kind)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard event.clickCount <= 1, let cell = cell(at: event) else { return }
        activate(cell, .right)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        model.scrollBy(delta)
        model.hovered = cell(at: event)
        refreshToolTips()
    }

    private func cell(at event: NSEvent) -> Int? {
        PanelMath.cell(at: convert(event.locationInWindow, from: nil), in: model.shownLayout)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        guard let key = BarKey.forKeyCode(event.keyCode, shift: flags.contains(.shift), option: flags.contains(.option),
                                          command: flags.contains(.command)) else {
            super.keyDown(with: event)
            return
        }
        switch model.handle(key) {
        case .activate(let cell, let kind):
            // A held Return repeats; one press is one click.
            if !event.isARepeat { activate(cell, kind) }
        case .close: close()
        case .moved, .ignored: break
        }
    }

    // MARK: Tooltips

    /// Gives each cell its title as a tooltip. Called when the cells change.
    func refreshToolTips() {
        removeAllToolTips()
        for frame in model.shownLayout.cellFrames { addToolTip(frame, owner: self, userData: nil) }
    }
}

extension BarContainerView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        PanelMath.cell(at: point, in: model.shownLayout).map { model.entries[$0].title } ?? ""
    }
}
