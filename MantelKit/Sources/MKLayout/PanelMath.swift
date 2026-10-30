import CoreGraphics
import Foundation
import MKCore

/// One of Mantel's panels that floats over the screen. Only one of them is open at a time.
public enum MantelPanel: Hashable, Sendable {
    case secondBar
    case group(GroupID)
    case commandBar
}

/// Why a panel closed.
public enum PanelCloseReason: String, Sendable {
    case escape, outsideClick, dotClick, iconClick, displayChange, appSwitch, otherPanel, quitting
    /// A group's panel that opened for the pointer closed because the pointer left it.
    case hoverEnded
    /// The second-bar hotkey closed it.
    case hotkey
    /// The reveal ended by itself (a collapse, Focus Mode, the rehide timer, a command), so there is nothing left for the panel to show.
    case revealEnded

    /// Whether closing the panel for this reason also puts the reveal away again.
    ///
    /// A panel closed by the person (Esc, a click outside it, the hotkey), by the person switching to another app, by a change of
    /// displays or by another panel taking its place ends the reveal it was showing. Not an icon clicked in it: that click is sent first
    /// and the reveal collapses after it, so the icons the click needs stay where they are meanwhile. Nor a click on a dot (the machine has already moved on), a reveal that ended by itself, or quitting (everything is
    /// put back anyway).
    public var collapsesReveal: Bool {
        switch self {
        case .escape, .outsideClick, .displayChange, .appSwitch, .otherPanel, .hotkey: true
        case .dotClick, .iconClick, .revealEnded, .quitting, .hoverEnded: false
        }
    }
}

/// What the hotkey for the second bar does.
public enum SecondBarHotkeyAction: Sendable, Equatable {
    /// The bar is open: it closes (and the reveal with it).
    case close
    /// Hidden is showing on the menu bar already, so the machine has no change to make: the bar opens for the state that is there, and the
    /// state is applied again for the bar.
    case openForTheCurrentState
    /// Hidden is shown, which is a change of state; the bar opens for it, whatever the setting is.
    case showHidden
}

/// The arithmetic of Mantel's floating panels: where a gradient runs, where a toast goes, which cell is under a point, and which clicks
/// and switches close a panel.
public enum PanelMath {
    /// The room kept between a toast and the edges of the screen.
    public static let toastScreenMargin: CGFloat = 8
    /// How far below and to the right of the pointer a toast starts.
    public static let toastOffset: CGFloat = 12

    /// The gradient's start and end in a unit square (0…1, y down) for an angle in degrees: 0 runs left to right, clockwise (90 runs top to
    /// bottom). The line goes from edge to edge of the square through its middle, so a diagonal runs corner to corner. An angle outside 0
    /// to 359 is wrapped into it.
    public static func gradientPoints(angle: Int) -> (start: CGPoint, end: CGPoint) {
        let wrapped = ((angle % 360) + 360) % 360
        let radians = Double(wrapped) * .pi / 180
        // The exact value for the angles that point along an axis, where the cosine of a right angle is not quite 0.
        let (dx, dy): (Double, Double) = switch wrapped {
        case 0: (1, 0)
        case 90: (0, 1)
        case 180: (-1, 0)
        case 270: (0, -1)
        default: (cos(radians), sin(radians))
        }
        let scale = 0.5 / max(abs(dx), abs(dy))
        return (start: CGPoint(x: 0.5 - dx * scale, y: 0.5 - dy * scale), end: CGPoint(x: 0.5 + dx * scale, y: 0.5 + dy * scale))
    }

    /// The toast's frame (CoreGraphics global points): `toastOffset` below and right of the pointer, kept inside the screen less
    /// `toastScreenMargin` (a toast that is bigger than that is put at the corner).
    public static func toastFrame(size: CGSize, pointer: CGPoint, screen: CGRect) -> CGRect {
        let room = screen.insetBy(dx: toastScreenMargin, dy: toastScreenMargin)
        let x = min(max(pointer.x + toastOffset, room.minX), max(room.minX, room.maxX - size.width))
        let y = min(max(pointer.y + toastOffset, room.minY), max(room.minY, room.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The cell under a point in the panel (the origin at its top-left corner), or nil between cells.
    public static func cell(at point: CGPoint, in layout: SecondBarLayout) -> Int? {
        layout.cellFrames.firstIndex { $0.contains(point) }
    }

    // MARK: The command bar

    /// How wide the command bar is.
    public static let commandBarWidth: CGFloat = 560
    /// How far down the screen the command bar's top edge is, as a share of the screen's height.
    public static let commandBarTopShare: CGFloat = 0.22
    /// The height of the search field's row.
    public static let commandBarFieldHeight: CGFloat = 52
    /// The height of one result.
    public static let commandBarRowHeight: CGFloat = 36
    /// How many results show without scrolling.
    public static let commandBarVisibleRows = 8
    /// The height of the line of hints under the results.
    public static let commandBarFooterHeight: CGFloat = 28
    /// The height of the divider between the search field and the results.
    public static let commandBarDividerHeight: CGFloat = 1

    /// The command bar's panel, as tall as it is with the most results showing (CoreGraphics global points): 560 wide, centred on the
    /// screen, its top edge 22 % of the screen's height down from the screen's top.
    public static func commandBarFrame(screen: CGRect) -> CGRect {
        commandBarFrame(screen: screen, results: commandBarVisibleRows)
    }

    /// The command bar's panel for this many results: the same top edge and width, as tall as the field, the divider, the rows (at most eight
    /// show, the rest scroll) and the footer need. With no results it is the field alone.
    public static func commandBarFrame(screen: CGRect, results: Int) -> CGRect {
        let rows = max(0, min(results, commandBarVisibleRows))
        let height = commandBarFieldHeight + (rows > 0 ? commandBarDividerHeight + CGFloat(rows) * commandBarRowHeight + commandBarFooterHeight : 0)
        return CGRect(x: screen.midX - commandBarWidth / 2, y: screen.minY + screen.height * commandBarTopShare,
                      width: commandBarWidth, height: height)
    }

    /// Which of Mantel's panels close when `opening` opens: every other one that is open.
    public static func closes(when opening: MantelPanel, open: Set<MantelPanel>) -> Set<MantelPanel> {
        open.subtracting([opening])
    }

    /// Whether the pointer (a hover, a scroll) opens a panel: not while the command bar is open, since the panel that replaced it would
    /// not take the keyboard and what the person is typing would go to the front app.
    public static func pointerOpensPanels(open: Set<MantelPanel>) -> Bool {
        !open.contains(.commandBar)
    }

    /// Whether a mouse-down closes a panel: it is outside the panel and outside every one of Mantel's own status items. A click on a
    /// status item of Mantel's is that item's own business (a dot's action decides what the open bar does).
    public static func isOutsideClick(_ point: CGPoint, panel: CGRect, ownItemFrames: [CGRect]) -> Bool {
        !panel.contains(point) && !ownItemFrames.contains { $0.contains(point) }
    }

    /// What the hotkey for the second bar does, the bar being open or not and the reveal being in this state.
    public static func secondBarHotkey(isOpen: Bool, state: RevealState) -> SecondBarHotkeyAction {
        if isOpen { return .close }
        return state == .hiddenShown ? .openForTheCurrentState : .showHidden
    }

    /// Whether a panel's closing puts the reveal away: only the second bar's does, and only for a reason that is the person's. A group
    /// panel can be open while Hidden is shown inline, and closing it must leave that alone.
    public static func collapsesReveal(closed panel: MantelPanel, reason: PanelCloseReason) -> Bool {
        panel == .secondBar && reason.collapsesReveal
    }

    /// Whether the panel closes when another app becomes active: yes, unless a click from the panel is in flight (the click's own app is
    /// about to come to the front).
    public static func closesOnAppSwitch(clickInFlight: Bool) -> Bool {
        !clickInFlight
    }

    /// How long, in seconds, the panel waits for the activation a takeover's end causes. Long enough for a busy Mac; the first activation
    /// of an app other than Mantel uses the wait up, so a long one costs nothing.
    public static let expectedActivationWait: TimeInterval = 3

    /// Whether an app coming to the front is the one the end of a takeover of the menu bar was to bring there, and not the person leaving.
    /// It is, when it comes within the wait (`until`) and is the app the focus was handed to, or, when Mantel stepped back, any app.
    public static func isExpectedActivation(_ expected: ExpectedActivation, activated: pid_t, now: Date, until: Date) -> Bool {
        guard now < until else { return false }
        switch expected {
        case .app(let pid): return pid == activated
        case .nextApp: return true
        }
    }
}

/// The app the end of a takeover of the menu bar brings to the front, by what Mantel did with the focus.
public enum ExpectedActivation: Sendable, Equatable {
    /// The focus was handed to this app.
    case app(pid_t)
    /// Mantel stepped back (there was no app to hand the focus to), and whichever app is next in line comes forward.
    case nextApp
}
