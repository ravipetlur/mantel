import CoreGraphics
import Foundation
import MKCore

/// Where Mantel's menu opens when a dot is right-clicked.
///
/// macOS draws a status item on every display's bar, but the item's button has one window, on one display, and a menu the item opens
/// goes under that window. A right click on the dot on any other display would open the menu on the wrong display. So when the click was
/// on a display the button's window isn't on, the menu is popped up at a point of its own: left-aligned with the dot's slot on the bar
/// that was clicked and just below the bar, as a status item's own menu is, or, when that slot isn't known, under the bar at the click.
public enum DotMenuPlacement {
    /// How the menu is opened.
    public enum Decision: Sendable, Equatable {
        /// By the dot's status item, which puts it under its own button: the click was on the display that button is on, or there is no
        /// telling which display was clicked.
        case statusItem
        /// Popped up with its top-left corner at the point (AppKit global points).
        case popUp(at: CGPoint, under: Anchor)
    }

    /// What the point is of.
    public enum Anchor: Sendable, Equatable {
        /// The left edge of the dot's slot on the bar that was clicked.
        case slot
        /// The click's own place along the bar: the dot's slot there isn't known (the dots hidden, •• not on the bar, the dot in « or
        /// behind the notch, a read older than the last change of displays, a pointer that isn't on the slot).
        case click
    }

    /// What the menu bar's height is at least, in points, whichever display: the system's own (`NSStatusBar.system.thickness`), for a
    /// display whose frame and visible frame say nothing of a bar (it hides itself) and the read has none.
    public static let fallbackBarHeight: CGFloat = 24

    /// How far the pointer may be outside the dot's slot and still be taken to have clicked the dot, in points.
    public static let slotSlack: CGFloat = 4

    /// The menu bar's height on a display the read found no bar for.
    ///
    /// It is the display's own, from what AppKit says of it: the frame's top above the visible frame's top while the bar is shown, and on
    /// a notched display not less than the notch's depth (its safe-area top). It isn't `NSStatusBar.system.thickness`, which is one number
    /// for every display (24 or so) where the bars here are 39, 30 and 30 high. The visible frame is only a rough guide (see
    /// `DisplayInfo`): it reaches the frame's top while the bar hides, so `minimum` stands in then. (A Dock along the top would make the
    /// gap too tall, and the menu would sit a little low.)
    public static func barHeight(on display: DisplayInfo, minimum: CGFloat = fallbackBarHeight) -> CGFloat {
        max(minimum, display.frame.maxY - display.visibleFrame.maxY, display.notch?.height ?? 0)
    }

    /// - Parameters:
    ///   - pointer: where the pointer was at the click (AppKit global points); it says which display's bar was clicked.
    ///   - buttonFrame: the frame of the dot's status item's button window (AppKit global points), nil when it has none.
    ///   - inventory: the last read of the menu bar, nil before there is one.
    ///   - displaysChangedAt: when the displays last changed. A read taken before it gives neither a slot nor a bar (`PanelAnchors`).
    ///   - barHeight: the least a bar is high where the read has none for the display (`barHeight(on:minimum:)`).
    public static func decide(dot: DotKind, pointer: CGPoint, buttonFrame: CGRect?, displays: DisplayLayout, inventory: Inventory?,
                              displaysChangedAt: Date? = nil, barHeight: CGFloat = fallbackBarHeight) -> Decision {
        guard let clicked = displays.display(containing: pointer) else { return .statusItem }
        if let buttonFrame, !buttonFrame.isEmpty,
           displays.display(containing: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY))?.uuid == clicked.uuid {
            return .statusItem
        }
        // What the read says is used only where it lies at the top of the clicked display, and was taken since the displays last changed:
        // after docking, a resolution change or a rearrangement the read's windows can be where the display used to be, and the menu
        // would go to whatever display is there now.
        let screen = displays.cgRect(fromAppKit: clicked.frame)
        var current = inventory
        if let displaysChangedAt, let read = inventory, read.capturedAt < displaysChangedAt { current = nil }
        func atTheTop(_ rect: CGRect) -> Bool {
            abs(rect.minY - screen.minY) <= 1 && rect.minX >= screen.minX - 1 && rect.maxX <= screen.maxX + 1
        }
        let owned: OwnItemKind = dot == .always ? .alwaysDot : .hiddenDot
        // The dot's slot, when the pointer is on it. A pointer that isn't means the dot has moved since the read (a reveal, an icon coming
        // or going beside it, a drag), and the click is the better guide.
        let slot = current.flatMap { PanelAnchors.slotFrame(of: owned, on: clicked.uuid, in: $0, displaysChangedAt: displaysChangedAt) }
            .flatMap { atTheTop($0) && pointer.x >= $0.minX - slotSlack && pointer.x <= $0.maxX + slotSlack ? $0 : nil }
        // Below the bar: the bar's own bottom edge when the read found it, else the top of the display and the bar's height there.
        let bar = current?.bars.first { $0.displayUUID == clicked.uuid && atTheTop($0.rect) }
        let barBottom = bar?.rect.maxY ?? screen.minY + Self.barHeight(on: clicked, minimum: barHeight)
        let anchor: Anchor = slot == nil ? .click : .slot
        let x = slot?.minX ?? pointer.x
        var point = displays.appKitPoint(fromCG: CGPoint(x: x, y: barBottom))
        // No higher than the display's visible frame: the bar's own window ends a point above where AppKit's visible frame begins (on the
        // laptop 39 against 40), and a menu opened with its top above the area AppKit lays menus out in isn't opened whole: it comes with a
        // scroll arrow at its top and its first items out of sight. While the bar hides, the visible frame reaches the frame's top and
        // this changes nothing.
        point.y = min(point.y, clicked.visibleFrame.maxY)
        return .popUp(at: point, under: anchor)
    }

    /// The log's line for a menu that is popped up: where, under what, and on which display with the top of its visible frame, so that a
    /// menu that opens wrong (a scroll arrow at its top) can be told from the log. The point is on the top edge of a display's visible
    /// frame, so the display is the one whose frame holds the point just under it.
    public static func popUpLogLine(at point: CGPoint, under anchor: Anchor, displays: DisplayLayout) -> String {
        let under = anchor == .slot ? "the dot's slot" : "the click"
        let display = displays.displays.first { $0.frame.contains(CGPoint(x: point.x, y: point.y - 1)) }
        let on = display.map { "on \($0.uuid.prefix(8)), whose visible frame's top is \(Double($0.visibleFrame.maxY))" } ?? "on no display"
        return "the menu is popped up at (\(Double(point.x)), \(Double(point.y))) under \(under) \(on)"
    }
}
