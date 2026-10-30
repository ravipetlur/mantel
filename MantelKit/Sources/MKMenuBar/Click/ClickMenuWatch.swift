import CoreGraphics
import Foundation

/// Where a click's menu is in its life, from what the window list says: pure, so that what holds an icon on the bar is decided without a
/// window list.
///
/// The watch starts when the click is sent. It sees the menu open when a window of the item's app is at a menu's level (`menuOfApp`), holds
/// while it is open, and ends when no menu is, with no menu open anywhere and the pointer out of the bar. It ends at the timeout when
/// nothing opened. **A menu that isn't the item's but is open when the timeout comes** (a helper process draws some apps' menus, which the
/// owner rule doesn't see) **is taken for it:** the icon stays on the bar for as long as it is open.
///
/// Where menus aren't seen at all (`menusAreSeen` false) a menu is taken to be open from the start, and it ends with the next mouse-down
/// outside the icon (or the timeout, which the caller sends as its cap).
public struct ClickMenuWatch: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// One look at the window list: whether a window of the item's app is a menu, whether any menu is open (`WindowRules.isMenuOpen`),
        /// and whether the pointer is in a bar.
        case poll(menuOfApp: Bool, anyMenuOpen: Bool, pointerInBar: Bool, at: Date)
        /// A mouse-down outside the icon's frame. It ends a menu that isn't seen, and a wait for one that hasn't opened (a click elsewhere).
        case mouseDownOutsideIcon(at: Date)
        /// The wait for the menu is over (or, where menus aren't seen, the cap on the watch).
        case timeout(at: Date)
    }

    public enum Phase: Sendable, Equatable {
        case waitingForMenu
        case menuOpen
        /// The watch is over, whether or not a menu opened.
        case menuClosed(at: Date)
    }

    public let startedAt: Date
    public let menusAreSeen: Bool
    public private(set) var phase: Phase
    /// The last look held (a menu of anything was open or the pointer was in the bar).
    private var lastLookHeld = false

    public init(startedAt: Date, menusAreSeen: Bool) {
        self.startedAt = startedAt
        self.menusAreSeen = menusAreSeen
        phase = menusAreSeen ? .waitingForMenu : .menuOpen
    }

    /// Takes in what happened and says where the menu is now. Once it is closed it stays so.
    @discardableResult
    public mutating func handle(_ event: Event) -> Phase {
        if case .menuClosed = phase { return phase }
        switch event {
        case .poll(let menuOfApp, let anyMenuOpen, let pointerInBar, let at):
            guard menusAreSeen else { return phase }
            lastLookHeld = anyMenuOpen || pointerInBar
            switch phase {
            case .waitingForMenu:
                if menuOfApp { phase = .menuOpen }
            case .menuOpen:
                if !menuOfApp && !lastLookHeld { phase = .menuClosed(at: at) }
            case .menuClosed:
                break
            }
        case .mouseDownOutsideIcon(let at):
            if !menusAreSeen || phase == .waitingForMenu { phase = .menuClosed(at: at) }
        case .timeout(let at):
            if phase == .waitingForMenu, menusAreSeen, lastLookHeld {
                phase = .menuOpen
            } else if phase == .waitingForMenu || !menusAreSeen {
                phase = .menuClosed(at: at)
            }
        }
        return phase
    }
}

/// Which window is a menu that an icon opened, by where it is.
public enum ClickMenuRules {
    /// macOS 27 opens a menu this far below the bar's bottom, at most (it measured 10).
    public static let belowTheBar: CGFloat = 12
    /// How far a menu's left may be from the slot's left to be the icon's (it measured within 5).
    public static let besideTheSlot: CGFloat = 5

    /// Whether a window is near the slot as a menu of the icon is: its left within 5 points of the slot's, its top no more than 12 below the
    /// slot's bottom (which is the bar's) and no more than 2 above it.
    public static func isNearItem(_ window: CGRect, slot: CGRect) -> Bool {
        abs(window.minX - slot.minX) <= besideTheSlot && window.minY >= slot.maxY - 2 && window.minY - slot.maxY <= belowTheBar
    }
}
