import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// Mantel's two dots in the menu bar. • shows the Hidden icons and •• shows all of them; each is a filled dot while its section is on the
/// bar and an outlined one while it is put away. •• is on the bar only while something that is running is in Always Hidden.
///
/// - **A click reveals, a right click opens a menu** (`DotClickRule`). The items send their action when either button goes up. Their
///   `menu` stays nil: a status item that has one opens it on every click, and the left click is the reveal. For a right click the menu
///   is given to the item for as long as it is open (`statusItem.menu`, then a click on its button) and taken away again when it closes
///   (`menuDidClose`), so that the system puts it under the dot on whichever display the dot is on now. Nothing changes with a modifier key.
/// - **Positions are macOS's.** The dots are made • first and •• second, each with a name the system keeps its place under, so a place the
///   person gave them (by dragging, with ⌘ held) is remembered.
/// - **What the dots say** (the tooltip, the accessibility descriptions) is in `DotsCopy`.
final class DotsController: NSObject, NSMenuDelegate {
    /// What the system keeps each dot's place in the menu bar under.
    static let hiddenAutosaveName = DotsCopy.hiddenDotName
    static let alwaysAutosaveName = DotsCopy.alwaysDotName

    /// What the dots ask of the rest of the app.
    struct Actions {
        /// A left click on a dot.
        let dotClicked: (DotKind) -> Void
        let openSettings: () -> Void
        let toggleFocusMode: () -> Void
        let refresh: () -> Void
        let openDiagnostics: () -> Void
    }

    private let actions: Actions
    private let hiddenItem: NSStatusItem
    private let alwaysItem: NSStatusItem
    private let menu = NSMenu()
    private let focusModeItem: NSMenuItem
    private var look: DotAppearance?
    private var tooltip: String?
    private var isFocusModeOn = false
    /// Whether the menu has been asked for and has opened (`DotMenuOpening`).
    private var opening = DotMenuOpening()
    /// Set once the log has said the dot has no button, and once it has said the menu didn't open: each is said once a run.
    private var loggedNoButton = false
    private var loggedNotOpened = false
    /// Set once the log has said a dot's action arrived with an event that was no click on it, so that it is said once a run.
    private var loggedUnexpectedEvent = false

    init(actions: Actions) {
        self.actions = actions
        hiddenItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        alwaysItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        focusModeItem = NSMenuItem(title: DotsCopy.focusModeItem, action: #selector(focusModeChosen), keyEquivalent: "")
        super.init()

        configure(hiddenItem, autosaveName: Self.hiddenAutosaveName, action: #selector(hiddenDotClicked(_:)))
        configure(alwaysItem, autosaveName: Self.alwaysAutosaveName, action: #selector(alwaysDotClicked(_:)))
        // Until the session has said whether anything is in Always Hidden, there is nothing for •• to show.
        alwaysItem.isVisible = false
        buildMenu()
        menu.delegate = self
        update(reveal: .collapsed, alwaysHiddenHasApps: false, engine: nil)
    }

    // MARK: Drawing

    /// Draws the dots for what the reveal shows. Called whenever that, or whether Always Hidden has apps, or how icons are hidden, changes.
    func update(reveal: RevealState, alwaysHiddenHasApps: Bool, engine: EngineStatus?) {
        isFocusModeOn = reveal == .focusMode
        let new = DotAppearance(reveal: reveal, alwaysHiddenHasApps: alwaysHiddenHasApps)
        if new != look {
            look = new
            hiddenItem.button?.image = Self.image(.hidden, filled: new.hiddenDotFilled)
            alwaysItem.button?.image = Self.image(.always, filled: new.alwaysDotFilled)
            if alwaysItem.isVisible != new.alwaysDotVisible { alwaysItem.isVisible = new.alwaysDotVisible }
        }
        let text = engine.map(DotsCopy.tooltip)
        if text != tooltip {
            tooltip = text
            hiddenItem.button?.toolTip = text
            alwaysItem.button?.toolTip = text
        }
    }

    private func configure(_ item: NSStatusItem, autosaveName: String, action: Selector) {
        item.autosaveName = autosaveName
        // No `menu`: see the type's comment.
        item.menu = nil
        guard let button = item.button else { return }
        button.target = self
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The dot's picture: 18 × 18 points, drawn as a template so that the menu bar colours it. • is a circle 6 points across; •• is two
    /// of 5 points, 3 points apart. A dot that is filled is drawn solid, and one that is not is a ring 1.5 points thick that is as big.
    private static func image(_ dot: DotKind, filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let circles: [NSRect] = switch dot {
            case .hidden: [NSRect(x: 6, y: 6, width: 6, height: 6)]
            case .always: [NSRect(x: 2.5, y: 6.5, width: 5, height: 5), NSRect(x: 10.5, y: 6.5, width: 5, height: 5)]
            }
            for rect in circles {
                if filled {
                    NSBezierPath(ovalIn: rect).fill()
                } else {
                    // A stroke is centred on the path: pulled in by half of it, the ring is as big as the solid circle.
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        // `DotsCopy.isDot` finds the dots in the menu bar's Accessibility tree by this description (the tree gives status items no names):
        // changing it, or leaving it off, makes Mantel stop finding its own dots, and nothing is made room for.
        image.accessibilityDescription = dot == .hidden ? DotsCopy.hiddenDotDescription : DotsCopy.alwaysDotDescription
        return image
    }

    // MARK: Clicks

    @objc private func hiddenDotClicked(_ sender: NSStatusBarButton) {
        clicked(.hidden, from: sender)
    }

    @objc private func alwaysDotClicked(_ sender: NSStatusBarButton) {
        clicked(.always, from: sender)
    }

    /// A right click on the dot opens the menu; whatever else sent the action is a click on the dot: the left button, and also an assistive
    /// tool that presses it. A press comes with no mouse event of its own, and the app's current event is then the last one it retrieved, so
    /// a right click counts only when it was on the dot's own window (`DotClickRule`).
    private func clicked(_ dot: DotKind, from sender: NSStatusBarButton) {
        // The menu is being asked for, and the system sent the action in the middle of it: that is no click, and answering it would ask again.
        guard !opening.isAsking else { return }
        let current = NSApp.currentEvent
        let event = DotClickRule.event(isLeftMouseUp: current?.type == .leftMouseUp, isRightMouseUp: current?.type == .rightMouseUp,
                                       isOnTheDotsWindow: current?.window === sender.window)
        if !loggedUnexpectedEvent,
           let line = DotClickRule.unexpectedEventLogLine(typeCode: current.map { Int($0.type.rawValue) }, event: event) {
            loggedUnexpectedEvent = true
            Log.info("dots", line)
        }
        switch DotClickRule.action(for: event) {
        case .openMenu: openMenu(on: dot)
        case .reveal: actions.dotClicked(dot)
        }
    }

    // MARK: The menu

    private func buildMenu() {
        dispatchPrecondition(condition: .onQueue(.main))
        let settings = NSMenuItem(title: DotsCopy.settingsItem, action: #selector(settingsChosen), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        focusModeItem.target = self
        menu.addItem(focusModeItem)
        let refresh = NSMenuItem(title: DotsCopy.refreshItem, action: #selector(refreshChosen), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let diagnostics = NSMenuItem(title: DotsCopy.diagnosticsItem, action: #selector(diagnosticsChosen), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: DotsCopy.quitItem, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// Opens the menu through the dot's status item: it is given the menu and its button is clicked, and the system puts the menu under the
    /// dot, on whichever display that is on. (The menu was hung from the button's window before, from its frame, which can be missing or
    /// stale after the displays change.) The item has a menu only while it is open: `menuDidClose` takes it away, so that the left click is
    /// the reveal again. The dot is lit while the menu is open: the system does that for a menu a status item has itself. With a menu set
    /// the button doesn't send its action, so this is not entered again, and if it ever did, `opening` makes that action no click.
    ///
    /// Nothing says the menu will open. When it hasn't by the time the click returns, it is looked for again a moment later (the click may
    /// return before the menu has begun to track); when it still hasn't, the item's menu is taken away at once and the log says so, so that
    /// the left click keeps revealing.
    private func openMenu(on dot: DotKind) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let ticket = opening.beginAsking() else { return }
        defer { opening.endAsking() }
        let item = dot == .hidden ? hiddenItem : alwaysItem
        guard let button = item.button else {
            if !loggedNoButton {
                loggedNoButton = true
                Log.warning("dots", "the menu couldn't be opened: the dot has no button")
            }
            return
        }
        focusModeItem.state = isFocusModeOn ? .on : .off
        item.menu = menu
        button.performClick(nil)
        guard !opening.hasOpened(since: ticket) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + DotMenuOpening.recheckDelay) { [weak self] in
            MainActor.assumeIsolated { self?.checkThatTheMenuOpened(since: ticket) }
        }
    }

    private func checkThatTheMenuOpened(since ticket: DotMenuOpening.Ticket) {
        guard !opening.hasOpened(since: ticket) else { return }
        clearMenus()
        if !loggedNotOpened {
            loggedNotOpened = true
            Log.warning("dots", DotMenuOpening.didNotOpenLogLine)
        }
    }

    private func clearMenus() {
        hiddenItem.menu = nil
        alwaysItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        opening.menuWillOpen()
    }

    /// The items' menus are taken away on the next turn of the main queue, not here: the item that was chosen has its action sent as the menu
    /// closes, and what it does must never depend on how the status item sends it.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.clearMenus() }
        }
    }

    @objc private func settingsChosen() { actions.openSettings() }
    @objc private func focusModeChosen() { actions.toggleFocusMode() }
    @objc private func refreshChosen() { actions.refresh() }
    @objc private func diagnosticsChosen() { actions.openDiagnostics() }
}
