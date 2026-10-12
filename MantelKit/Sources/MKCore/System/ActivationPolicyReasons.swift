import Foundation

/// Whether Mantel is an ordinary app (a Dock icon, a place in ⌘-Tab, a menu bar of its own) or a menu bar app that has none of them.
public enum ActivationPolicyKind: Sendable, Equatable {
    case regular
    case accessory
}

/// Why Mantel is an ordinary app, kept in one place so that the reasons can't undo each other: it is one while any of them holds.
///
/// - **A window of Mantel's is open** (Settings, which holds Diagnostics, or onboarding). The person who switches to another app with a
///   window open has the Dock and ⌘-Tab to come back by. Alerts and menus aren't windows in this sense.
/// - **Mantel has taken the menu bar over** to make room for revealed icons (`MenuBarTakeover`): it needs a menu bar of its own for as
///   long as that lasts.
///
/// A window is open or it isn't: the same window opened twice is one reason, and one close ends it. A takeover ending while Settings is
/// open leaves Mantel as it is, and so does Settings closing during a takeover; the last reason to go is the one that makes Mantel a menu
/// bar app again.
///
/// Every change says what the policy has become, or nil when it is what it was, so that the app side sets the policy only when it
/// changes and in one place only.
///
/// **The main menu follows the reasons too** (`menuKind`): none for a menu bar app; the Mantel menu alone while the only reason is a
/// takeover (a short menu is what frees room on the bar); the full set, with Edit and Window, while a window is open, because a window
/// has text to copy and paste and a window to close.
///
/// **Whether the person used a window during a takeover** is evidence the takeover can't produce itself: it brings Mantel forward, and a
/// window that was open comes forward with it. So it is noted only from what the person did: a click or a key in one of Mantel's windows
/// (`personUsedAMantelWindow()`), or asking for a window (`windowOpened`) while the takeover lasts.
public struct ActivationPolicyReasons: Sendable, Equatable {
    /// The windows that make Mantel an ordinary app.
    public enum Window: Sendable, Hashable, CaseIterable {
        case settings
        case onboarding
    }

    public private(set) var openWindows: Set<Window> = []
    public private(set) var takeoverIsActive = false
    /// Whether the person clicked or typed in a window of Mantel's, or asked for one, since the takeover began. False outside one.
    public private(set) var personUsedAWindowDuringTakeover = false

    public init() {}

    /// The main menu Mantel has now.
    public var menuKind: MainMenuKind {
        if openWindows.isEmpty { takeoverIsActive ? .appOnly : .none } else { .full }
    }

    /// Mantel is an ordinary app while any reason holds.
    public var policy: ActivationPolicyKind {
        openWindows.isEmpty && !takeoverIsActive ? .accessory : .regular
    }

    /// Whether a window of Mantel's is open.
    public var hasOpenWindow: Bool {
        !openWindows.isEmpty
    }

    // MARK: Changes

    @discardableResult
    public mutating func windowOpened(_ window: Window) -> ActivationPolicyKind? {
        changing {
            $0.openWindows.insert(window)
            // Asked for during a takeover: the person is using it.
            if $0.takeoverIsActive { $0.personUsedAWindowDuringTakeover = true }
        }
    }

    @discardableResult
    public mutating func windowClosed(_ window: Window) -> ActivationPolicyKind? {
        changing { $0.openWindows.remove(window) }
    }

    @discardableResult
    public mutating func takeoverBegan() -> ActivationPolicyKind? {
        changing {
            // A takeover that is begun again while it lasts is the same one.
            if !$0.takeoverIsActive { $0.personUsedAWindowDuringTakeover = false }
            $0.takeoverIsActive = true
        }
    }

    /// The person clicked or typed in a window of Mantel's. Counts only during a takeover.
    public mutating func personUsedAMantelWindow() {
        if takeoverIsActive { personUsedAWindowDuringTakeover = true }
    }

    @discardableResult
    public mutating func takeoverEnded() -> ActivationPolicyKind? {
        changing { $0.takeoverIsActive = false }
    }

    private mutating func changing(_ change: (inout Self) -> Void) -> ActivationPolicyKind? {
        let before = policy
        change(&self)
        return policy == before ? nil : policy
    }

    // MARK: Giving the focus back

    /// Whether a takeover that ends gives the focus back to the app it was taken from.
    ///
    /// - `requested`: the caller wants it. A takeover that ends because another app came to the front doesn't: the focus is where the
    ///   person put it.
    /// - It doesn't when the person used a window of Mantel's during the takeover (`personUsedAWindowDuringTakeover`) **and that window is
    ///   still open** (`aWindowIsOpen`): that is where they are, and a reveal being put away isn't a reason to take them out of it. A
    ///   window that is merely key (the takeover brought Mantel forward, and with it a Settings window that was open behind another app)
    ///   is not use. A window used and then closed leaves nowhere to be in: the person is let go of Mantel, which has no window to type
    ///   in, and the focus goes back.
    public static func takeoverHandsBackFocus(requested: Bool, personUsedAMantelWindow: Bool, aWindowIsOpen: Bool) -> Bool {
        requested && !(personUsedAMantelWindow && aWindowIsOpen)
    }

    /// What the end of a takeover does about the focus.
    public enum FocusAfterTakeover: Sendable, Equatable {
        /// The app the takeover came from has the focus again.
        case handBack
        /// Mantel is a menu bar app again, and would still be the active app with no window to type in, so it steps back and the next app
        /// has the focus. (An accessory app that stays active is one whose keys go nowhere.)
        case deactivate
        /// Nothing to do: another app has the focus already, or a window of Mantel's is open and that is where the person is.
        case keep
    }

    /// What the end of a takeover does about the focus, by `takeoverHandsBackFocus` and then, when nothing is handed back, by whether Mantel
    /// would be left as the active app with no window.
    ///
    /// - `hasAppToHandBackTo`: there is an app to give the focus to. There isn't one when Mantel was in front when the takeover began, or
    ///   when that app has quit since.
    /// - `mantelIsActive`: Mantel is the active app as the takeover ends.
    public static func focusAfterTakeover(requested: Bool, personUsedAMantelWindow: Bool, aWindowIsOpen: Bool,
                                          hasAppToHandBackTo: Bool, mantelIsActive: Bool) -> FocusAfterTakeover {
        if hasAppToHandBackTo,
           takeoverHandsBackFocus(requested: requested, personUsedAMantelWindow: personUsedAMantelWindow, aWindowIsOpen: aWindowIsOpen) {
            return .handBack
        }
        // With a window open Mantel stays an ordinary app, and the focus is where the person left it.
        if aWindowIsOpen || !mantelIsActive { return .keep }
        return .deactivate
    }

    /// Whether closing a window lets the next app have the focus: when it was the last reason (`policyChange` is `.accessory`, so Mantel
    /// is a menu bar app again) and Mantel still has the focus, the window having been closed by a person who was using it. A close that
    /// leaves Mantel an ordinary app, or one made while another app has the focus, changes no one's focus.
    public static func closingHandsBackFocus(policyChange: ActivationPolicyKind?, mantelIsActive: Bool) -> Bool {
        policyChange == .accessory && mantelIsActive
    }
}
