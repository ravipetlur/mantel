import AppKit
import MKCommands
import MKCore

/// The one place that sets Mantel's activation policy, and with it whether Mantel has a Dock icon, a place in ⌘-Tab and a menu bar of its
/// own. Nothing else in the app calls `setActivationPolicy`.
///
/// Mantel is a menu bar app (an accessory app: no Dock icon, not in ⌘-Tab) except while it has a reason to be an ordinary one, and any
/// reason is enough (`ActivationPolicyReasons` decides, and is tested):
/// - **A window of Mantel's is open** (Settings, which holds Diagnostics, or onboarding): the person who switches to another app then has
///   the Dock and ⌘-Tab to come back by. The Dock icon is the app's own icon.
/// - **The menu bar is taken over** to make room for revealed icons (`MenuBarTakeover`).
///
/// The owner only feeds the decision and does what it says. An ordinary app has a menu bar of its own, and the reasons say how much of
/// one (`MainMenuKind`, drawn from `MainMenuSpec`): the full Mantel, Edit and Window menus while a window is open (so that ⌘C, ⌘V, ⌘W and
/// the rest work in it), the Mantel menu alone for a takeover with no window (short, to leave the room on the bar), none for a menu bar
/// app. The menu is made again whenever its kind changes, also when the policy doesn't (Settings opening during a takeover).
///
/// While a takeover lasts it also watches for the person using a window of Mantel's (a click or a key in one), which is what decides
/// whether the focus goes back to the app the takeover came from.
///
/// The windows come to the front through `show(_:as:)`, which is the one sequence for them all (`WindowShowing`).
final class ActivationPolicyOwner: NSObject {
    private var reasons = ActivationPolicyReasons()
    private var appliedPolicy: ActivationPolicyKind?
    private var appliedMenu: MainMenuKind = .none
    /// The windows `show` has been given, to tell a click or a key in one of them from one anywhere else.
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var inputMonitor: Any?

    /// Opens Settings, on a page or where it was left: what About Mantel and Settings… in the main menu do. Set by the coordinator.
    var openSettings: (SettingsPage?) -> Void = { _ in }

    // MARK: Launch

    /// Mantel starts as a menu bar app, so that no Dock icon flashes at launch (`LSUIElement` in Info.plist says the same from the first
    /// moment). A window that is opened at launch, onboarding, is what changes that.
    func launch() {
        synchronize(forcingPolicy: true)
    }

    // MARK: Windows

    /// Shows one of Mantel's windows and brings it to the front: Mantel becomes an ordinary app (this window is a reason to be one), and
    /// then, on the next turn of the main queue, which for a request that came from a menu is after the menu has finished tracking,
    /// Mantel is asked to become the active app and the window is made key and ordered front, regardless if Mantel still isn't active.
    func show(_ window: NSWindow, as kind: ActivationPolicyReasons.Window) {
        windows.add(window)
        WindowShowing(
            becomeRegular: { [self] in windowOpened(kind) },
            later: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
            activate: { NSApp.activate() },
            isActive: { NSApp.isActive },
            makeKeyAndOrderFront: {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            },
            orderFrontRegardless: { window.orderFrontRegardless() }
        ).show()
    }

    /// Shows one of Mantel's windows in front of the others without taking the keys from the app the person is using: Mantel becomes an
    /// ordinary app, as for `show`, and the window is ordered front, but Mantel isn't activated and the window isn't made key. For a window
    /// nobody asked for (an update the daily check found), which must not take what the person is typing in another app. The window is
    /// still shown the usual way when the person turns to it (a click in it, or Mantel's Dock icon).
    func showWithoutActivating(_ window: NSWindow, as kind: ActivationPolicyReasons.Window) {
        windows.add(window)
        windowOpened(kind)
        window.orderFrontRegardless()
    }

    /// A window of Mantel's was closed. When it was the last reason to be an ordinary app and the person was using it, the next app gets the
    /// focus, as it would after the window of any app that isn't the last one it has.
    func windowClosed(_ window: ActivationPolicyReasons.Window) {
        let change = reasons.windowClosed(window)
        // Before the policy changes: an app that is no longer an ordinary one has no next app to hand the focus to.
        if ActivationPolicyReasons.closingHandsBackFocus(policyChange: change, mantelIsActive: NSApp.isActive) {
            NSApp.deactivate()
        }
        synchronize()
    }

    private func windowOpened(_ window: ActivationPolicyReasons.Window) {
        reasons.windowOpened(window)
        synchronize()
    }

    // MARK: The menu bar takeover

    func takeoverBegan() {
        reasons.takeoverBegan()
        watchForUseOfAWindow()
        synchronize()
    }

    /// The takeover is over. Says what happens to the focus (`ActivationPolicyReasons.FocusAfterTakeover`), and for the one that is
    /// Mantel's to do, does it here:
    /// - **`handBack`**: the caller gives the focus to the app the takeover came from. It does when `reactivate` says so and there is one
    ///   (`hasAppToHandBackTo`), unless the person used a window of Mantel's meanwhile that is still open.
    /// - **`deactivate`**: nothing is handed back, no window is open, and Mantel is still the active app, which would leave a menu bar app
    ///   with the focus and nowhere for a key to go. Mantel steps back, so that the next app has it. (Mantel was in front when the takeover
    ///   began, or the app it came from is gone, or the person closed the window they were using.)
    /// - **`keep`**: another app has the focus already, or a window of Mantel's is open and is where the person is.
    func takeoverEnded(reactivate: Bool, hasAppToHandBackTo: Bool) -> ActivationPolicyReasons.FocusAfterTakeover {
        let used = reasons.personUsedAWindowDuringTakeover
        stopWatching()
        reasons.takeoverEnded()
        let focus = ActivationPolicyReasons.focusAfterTakeover(
            requested: reactivate, personUsedAMantelWindow: used, aWindowIsOpen: reasons.hasOpenWindow,
            hasAppToHandBackTo: hasAppToHandBackTo, mantelIsActive: NSApp.isActive)
        // Before the policy changes, as when the last window closes: an app that is no longer an ordinary one has no next app to hand the
        // focus to.
        if focus == .deactivate { NSApp.deactivate() }
        synchronize()
        return focus
    }

    /// Between the takeover's beginning and its end, a click or a key in one of Mantel's windows is the person using it. The takeover
    /// itself can't make one: it brings Mantel forward, and a window that was open comes with it, key, without anyone touching it.
    private func watchForUseOfAWindow() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            // Events are delivered on the main thread. Nothing is taken: the event goes on.
            MainActor.assumeIsolated { self?.noticeInput(in: event.window) }
            return event
        }
    }

    private func stopWatching() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func noticeInput(in window: NSWindow?) {
        guard let window, windows.contains(window) else { return }
        reasons.personUsedAMantelWindow()
    }

    // MARK: The policy and the menu

    /// Makes the policy and the main menu what the reasons say, changing only what is different.
    private func synchronize(forcingPolicy: Bool = false) {
        // The menus are AppKit's, for the main thread. Nothing here is called from anywhere else, and this says so if that is ever not true.
        dispatchPrecondition(condition: .onQueue(.main))
        let policy = reasons.policy
        let menu = reasons.menuKind
        switch policy {
        case .regular:
            if menu != appliedMenu { setMainMenu(menu) }
            if forcingPolicy || appliedPolicy != .regular { NSApp.setActivationPolicy(.regular) }
        case .accessory:
            if forcingPolicy || appliedPolicy != .accessory { NSApp.setActivationPolicy(.accessory) }
            if menu != appliedMenu { setMainMenu(menu) }
        }
        appliedPolicy = policy
    }

    private func setMainMenu(_ kind: MainMenuKind) {
        dispatchPrecondition(condition: .onQueue(.main))
        appliedMenu = kind
        let wanted = MainMenuSpec.menus(for: kind)
        guard !wanted.menus.isEmpty else {
            NSApp.mainMenu = nil
            NSApp.windowsMenu = nil
            return
        }
        let main = NSMenu(title: "Mantel")
        var windowsMenu: NSMenu?
        for described in wanted.menus {
            let menu = NSMenu(title: described.title)
            for (index, group) in described.groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                for item in group { menu.addItem(makeItem(item)) }
            }
            let entry = NSMenuItem(title: described.title, action: nil, keyEquivalent: "")
            entry.submenu = menu
            main.addItem(entry)
            if described.isWindowsMenu { windowsMenu = menu }
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowsMenu
    }

    private func makeItem(_ described: MainMenuSpec.Item) -> NSMenuItem {
        let (selector, target) = action(for: described.action)
        let item = NSMenuItem(title: described.title, action: selector, keyEquivalent: described.key)
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: described.modifiers.cocoaFlags)
        item.target = target
        return item
    }

    /// What an item sends, and to whom. The ones for text and windows have no target: they go to whatever has the focus (the field being
    /// edited, the window that is key), as the standard menus' do.
    private func action(for action: MainMenuSpec.Action) -> (Selector, AnyObject?) {
        switch action {
        case .about: (#selector(aboutChosen), self)
        case .settings: (#selector(settingsChosen), self)
        case .hide: (#selector(NSApplication.hide(_:)), NSApp)
        case .hideOthers: (#selector(NSApplication.hideOtherApplications(_:)), NSApp)
        case .showAll: (#selector(NSApplication.unhideAllApplications(_:)), NSApp)
        case .quit: (#selector(NSApplication.terminate(_:)), NSApp)
        case .undo: (Selector(("undo:")), nil)
        case .redo: (Selector(("redo:")), nil)
        case .cut: (#selector(NSText.cut(_:)), nil)
        case .copy: (#selector(NSText.copy(_:)), nil)
        case .paste: (#selector(NSText.paste(_:)), nil)
        case .selectAll: (#selector(NSText.selectAll(_:)), nil)
        case .minimize: (#selector(NSWindow.performMiniaturize(_:)), nil)
        case .close: (#selector(NSWindow.performClose(_:)), nil)
        }
    }

    @objc private func aboutChosen() {
        openSettings(.about)
    }

    @objc private func settingsChosen() {
        openSettings(nil)
    }
}
