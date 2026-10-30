import Foundation
import MKCore

/// How a left click reaches an icon that is drawn.
public enum LeftClickMethod: String, Codable, Sendable {
    /// An Accessibility press of the item.
    case press
    /// A click posted at the slot's centre.
    case post
}

/// What a left click does for an icon that isn't drawn (it has no room on the bar, or it is hidden).
public enum NotDrawnRoute: String, Codable, Sendable {
    /// The item is pressed where it is: macOS opens its menu on screen whether or not the icon has a slot.
    case pressInPlace
    /// Shown apps are concealed, right-most first, until the icon has room to be drawn, and then it is clicked.
    case makeRoom
}

/// What was measured of how clicks reach icons on macOS 27, as values the click path goes by.
public struct ClickRouteRules: Sendable, Equatable {
    /// How long an icon that was asked for is waited for to be drawn.
    public var drawnWait: Duration
    /// How long after the last plan was applied the bar is waited on to be still, for an app that plan has just shown (it was concealed
    /// before it): longer than `drawnWait`, because the draw of an app that comes back is the slowest there is, and what an app that was
    /// concealed left behind lies in a slot until it is drawn.
    public var justShownWait: Duration
    public var leftClick: LeftClickMethod
    /// For left clicks. Right and option clicks always make room: there is nothing to press for them.
    public var whenNotDrawn: NotDrawnRoute
    /// Pressing an item that has no slot opens its menu (no silent press: when false, an icon with no room can't be pressed).
    public var pressWorksUndrawn: Bool
    /// A right click that is posted arrives as a right click.
    public var postedRightWorks: Bool
    /// A click with Option held that is posted arrives as one. (On macOS 27 it arrives as a plain left click.)
    public var postedOptionWorks: Bool
    /// Where an item is can be told, so a click can be posted at its slot.
    public var locateWorks: Bool
    /// `AXShowMenu` opens the item's menu.
    public var showMenuWorks: Bool
    /// The lowest level of a window that can be the menu an icon opened (a popover is at 25, menus at 101).
    public var menuMinimumLayer: Int
    /// The window list shows the menu an icon opened. When it doesn't, the end of the menu is the next mouse-down outside the icon.
    public var menusAreSeen: Bool

    /// How long a menu is waited for to open.
    public static let menuAppearWait: Duration = .milliseconds(1500)
    /// How often the window list is read while a menu is watched.
    public static let menuPoll: Duration = .milliseconds(200)

    public init(drawnWait: Duration, justShownWait: Duration = .milliseconds(1500), leftClick: LeftClickMethod, whenNotDrawn: NotDrawnRoute,
                pressWorksUndrawn: Bool, postedRightWorks: Bool, postedOptionWorks: Bool, locateWorks: Bool, showMenuWorks: Bool,
                menuMinimumLayer: Int, menusAreSeen: Bool) {
        self.drawnWait = drawnWait
        self.justShownWait = justShownWait
        self.leftClick = leftClick
        self.whenNotDrawn = whenNotDrawn
        self.pressWorksUndrawn = pressWorksUndrawn
        self.postedRightWorks = postedRightWorks
        self.postedOptionWorks = postedOptionWorks
        self.locateWorks = locateWorks
        self.showMenuWorks = showMenuWorks
        self.menuMinimumLayer = menuMinimumLayer
        self.menusAreSeen = menusAreSeen
    }

    /// What was measured on macOS 27: an icon is drawn within 452 ms of being asked for (95th percentile 352 ms, and 100 more); a left
    /// click is a press, also on an icon with no room (it opens its menu on screen); a posted right click works and a posted option click
    /// arrives as a left click; an item can be located and `AXShowMenu` is refused; menus are seen at level 101 and a popover at 25. An app
    /// that was just shown is waited on for 1.5 s: the slowest draw measured (part 2 of the platform check) was 1229 ms, one of 35.
    public static let measured = ClickRouteRules(
        drawnWait: .milliseconds(452), justShownWait: .milliseconds(1500), leftClick: .press, whenNotDrawn: .pressInPlace, pressWorksUndrawn: true, postedRightWorks: true,
        postedOptionWorks: false, locateWorks: true, showMenuWorks: false, menuMinimumLayer: 25, menusAreSeen: true)

    /// Whether a click of this kind that is posted arrives as that kind. A left click is always itself.
    public func postedKindWorks(_ kind: ClickKind) -> Bool {
        switch kind {
        case .left: true
        case .right: postedRightWorks
        case .option: postedOptionWorks
        }
    }
}
