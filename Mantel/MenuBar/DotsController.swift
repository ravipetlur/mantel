import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// Mantel's two dots in the menu bar. • shows the Hidden icons and •• shows all of them; each is a filled dot while its section is on the
/// bar and an outlined one while it is put away. Which dots are on the bar is `OwnItemsVisibility`'s decision (`OwnItemsShown`): •• is
/// there while something that is running is in Always Hidden, or when the person set it to always.
///
/// - **A click reveals, a right click opens a menu** (`DotClickRule`). The items send their action when either button goes up. Their
///   `menu` stays nil: a status item that has one opens it on every click, and the left click is the reveal. For a right click the menu
///   is given to the item for as long as it is open (`statusItem.menu`, then a click on its button) and taken away again when it closes
///   (`menuDidClose`), so that the system puts it under the dot; that is only right on the display the button's window is on, so a click on
///   another display's bar pops the menu up under the dot there instead (`DotMenuPlacement`). Nothing changes with a modifier key.
/// - **Positions are macOS's.** The dots are made • first and •• second, each with a name the system keeps its place under, so a place the
///   person gave them (by dragging, with ⌘ held) is remembered.
/// - **What the dots say** (the tooltip, the accessibility descriptions) is in `DotsCopy`.
/// - **How a dot looks** is `DotGlyphs`' decision, for the person's style (`DotSettings`), whether the dot's section is on the bar and
///   whether the bar is dark behind it. Dots, arrowheads and symbols are drawn as template images, which the menu bar colours; a picture
///   is drawn as it is. A picture or a symbol that can't be loaded draws the dots instead, and says so in the log once.
/// - **A dot can be taken off the bar** (both, when the person hid them: `DotSettings.hideBothDots`), the way `OwnItemHiding` says, and
///   nothing is written to the order of the menu bar. Mantel's menu is then reached with its shortcut (`popUpMenuAtPointer`).
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
    /// What "Command Bar…" does. Set by whoever owns the command bar, once it is made.
    var openCommandBar: () -> Void = {}
    /// How the menu opens for a click at this place (AppKit global points), given the dot's button's frame (`DotMenuPlacement`). Set by
    /// whoever knows the displays and the last read of the menu bar; until it is, the status item opens the menu.
    var menuPlacement: (DotKind, CGPoint, CGRect?) -> DotMenuPlacement.Decision = { _, _, _ in .statusItem }
    private let hiddenItem: NSStatusItem
    private let alwaysItem: NSStatusItem
    private let menu = NSMenu()
    private let focusModeItem: NSMenuItem
    private var look: DotAppearance?
    private var tooltip: String?
    private var isFocusModeOn = false
    /// How the dots are drawn, and when they are on the bar.
    private var settings: DotSettings
    /// The folder the pictures a dot can be drawn as are in.
    private let imageFolder: URL
    /// How a dot is taken off the bar.
    private let hiding: OwnItemHiding
    /// Whether each dot is on the bar as things stand (`OwnItemsShown`).
    private var isOnBar: [DotKind: Bool] = [.hidden: true, .always: false]
    /// What each dot was last drawn as, so that a dot is drawn again only when what it is drawn as has changed.
    private var drawn: [DotKind: DotGlyph] = [:]
    /// Watches the bar's colour behind each dot, which a picture with a dark file follows.
    private var appearanceObservations: [NSKeyValueObservation] = []
    /// Set once the log has said a dot's picture or symbol couldn't be loaded, so that it is said once a run.
    private var loggedMissingGlyph = false
    /// Whether the menu has been asked for and has opened (`DotMenuOpening`).
    private var opening = DotMenuOpening()
    /// Set once the log has said the dot has no button, and once it has said the menu didn't open: each is said once a run.
    private var loggedNoButton = false
    private var loggedNotOpened = false
    /// Set once the log has said a dot's action arrived with an event that was no click on it, so that it is said once a run.
    private var loggedUnexpectedEvent = false

    /// - Parameters:
    ///   - settings: how the dots are drawn, and whether they are on the bar at all.
    ///   - imageFolder: where the pictures the person chose for the dots are (`MantelPaths.ownImages`).
    ///   - hiding: how a dot is taken off the bar.
    init(actions: Actions, settings: DotSettings, imageFolder: URL, hiding: OwnItemHiding = .current) {
        self.actions = actions
        self.settings = settings
        self.imageFolder = imageFolder
        self.hiding = hiding
        hiddenItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        alwaysItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        focusModeItem = NSMenuItem(title: DotsCopy.focusModeItem, action: #selector(focusModeChosen), keyEquivalent: "")
        super.init()

        configure(hiddenItem, autosaveName: Self.hiddenAutosaveName, action: #selector(hiddenDotClicked(_:)))
        configure(alwaysItem, autosaveName: Self.alwaysAutosaveName, action: #selector(alwaysDotClicked(_:)))
        // Until the session has said whether anything is in Always Hidden, there is nothing for •• to show.
        place(.always, onBar: false)
        observeBarColour()
        buildMenu()
        menu.delegate = self
        update(reveal: .collapsed, shown: OwnItemsVisibility.beforeTheFirstRead(dots: settings), engine: nil)
    }

    // MARK: Where the dots are

    /// Where each dot's button is, in AppKit's global points, by the name the system keeps the dot's place under. A dot that isn't on the bar
    /// (•• while nothing is in Always Hidden, and both when the person hid them) isn't listed.
    func buttonFrames() -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (dot, name, item) in [(DotKind.hidden, Self.hiddenAutosaveName, hiddenItem), (.always, Self.alwaysAutosaveName, alwaysItem)] {
            guard isOnBar[dot] == true, let window = item.button?.window else { continue }
            frames[name] = window.frame
        }
        return frames
    }

    /// How the menu bar looks behind the dots (light or dark), for a panel that follows the bar. Nil before the dot has a button.
    var barAppearance: NSAppearance? {
        hiddenItem.button?.effectiveAppearance
    }

    // MARK: Drawing

    /// Draws the dots for what the reveal shows, and puts each on the bar or takes it off as `shown` says. Called whenever that, or what is
    /// on the bar, or how icons are hidden, changes.
    func update(reveal: RevealState, shown: OwnItemsShown, engine: EngineStatus?) {
        isFocusModeOn = reveal == .focusMode
        let new = DotAppearance(reveal: reveal, shown: shown)
        if new != look {
            look = new
            redraw()
        }
        let text = engine.map(DotsCopy.tooltip)
        if text != tooltip {
            tooltip = text
            hiddenItem.button?.toolTip = text
            alwaysItem.button?.toolTip = text
        }
    }

    /// The person changed how the dots are drawn. (Hiding them or bringing them back arrives with `update`, in what is shown.)
    func setSettings(_ new: DotSettings) {
        guard new != settings else { return }
        settings = new
        redraw()
    }

    /// Draws both dots as the style and the reveal say, and puts each on the bar or takes it off. Only what has changed is touched: a
    /// status item's visibility is kept by the system, and a picture is read from its file when it is drawn.
    private func redraw() {
        guard let look else { return }
        draw(.hidden, open: look.hiddenDotFilled)
        draw(.always, open: look.alwaysDotFilled)
        place(.hidden, onBar: look.hiddenDotVisible)
        place(.always, onBar: look.alwaysDotVisible)
    }

    /// Puts a dot on the bar or takes it off, the way `OwnItemHiding` says: only what is different from how the item is now is set.
    private func place(_ dot: DotKind, onBar: Bool) {
        isOnBar[dot] = onBar
        let item = statusItem(for: dot)
        let presentation = hiding.presentation(onBar: onBar)
        if item.isVisible != presentation.isVisible { item.isVisible = presentation.isVisible }
        let length = presentation.isCollapsed ? 0 : NSStatusItem.squareLength
        if item.length != length { item.length = length }
        if let button = item.button, button.isHidden != presentation.isCollapsed { button.isHidden = presentation.isCollapsed }
    }

    private func statusItem(for dot: DotKind) -> NSStatusItem {
        dot == .hidden ? hiddenItem : alwaysItem
    }

    private func draw(_ dot: DotKind, open: Bool) {
        let item = statusItem(for: dot)
        guard let button = item.button else { return }
        let glyph = DotGlyphs.glyph(dot, open: open, style: settings.style, darkBar: Self.isDark(button.effectiveAppearance),
                                    symbolExists: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        guard glyph != drawn[dot] else { return }
        drawn[dot] = glyph
        button.image = image(for: glyph, dot: dot) ?? fallbackImage(for: dot, open: open)
    }

    /// The dots, for a glyph that couldn't be drawn as it is (a picture whose file is gone, a symbol with no such name): the log says so
    /// once, and the person still has dots to click.
    private func fallbackImage(for dot: DotKind, open: Bool) -> NSImage {
        if !loggedMissingGlyph {
            loggedMissingGlyph = true
            Log.warning("dots", "a dot's picture or symbol couldn't be loaded, so the dots are drawn instead")
        }
        let glyph = DotGlyphs.glyph(dot, open: open, style: .dots, darkBar: false, symbolExists: { _ in false })
        return image(for: glyph, dot: dot) ?? NSImage(size: NSSize(width: DotGlyphs.boxSide, height: DotGlyphs.boxSide))
    }

    /// Whether the bar the button is on is dark.
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// A picture drawn in the bar's own colours follows the bar, which changes with the wallpaper and the appearance.
    private func observeBarColour() {
        for item in [hiddenItem, alwaysItem] {
            guard let button = item.button else { continue }
            appearanceObservations.append(button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.barColourChanged() }
            })
        }
    }

    private func barColourChanged() {
        guard case .image = settings.style else { return }
        redraw()
    }

    /// The dot's picture: 18 × 18 points. A glyph that is a dot, an arrowhead or a symbol is drawn as a template, so that the menu bar
    /// colours it; a picture is drawn as it is. Nil when a symbol or a picture can't be loaded.
    private func image(for glyph: DotGlyph, dot: DotKind) -> NSImage? {
        let image: NSImage
        switch glyph {
        case .circles(let rects, let filled):
            image = Self.template { _ in
                for rect in rects {
                    if filled {
                        NSBezierPath(ovalIn: rect).fill()
                    } else {
                        // A stroke is centred on the path: pulled in by half of it, the ring is as big as the solid circle.
                        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                        ring.lineWidth = 1.5
                        ring.stroke()
                    }
                }
            }
        case .arrowheads(let count, let filled):
            let polygons = filled ? DotGlyphs.arrowheadPath(count: count) : DotGlyphs.arrowheadOutlinePath(count: count)
            image = Self.template { _ in
                for corners in polygons {
                    let path = NSBezierPath()
                    path.move(to: corners[0])
                    for corner in corners.dropFirst() { path.line(to: corner) }
                    path.close()
                    if filled {
                        path.fill()
                    } else {
                        path.lineWidth = DotGlyphs.arrowheadStroke
                        path.lineJoinStyle = .round
                        path.stroke()
                    }
                }
            }
        case .symbol(let name, let opacity):
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
                return nil
            }
            image = Self.template { box in
                let size = Self.fitted(symbol.size, in: box)
                let target = NSRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
                symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: opacity)
            }
        case .image(let fileName, let opacity):
            // A name that isn't a file's own (it has a folder in it) is no picture of ours.
            guard fileName == (fileName as NSString).lastPathComponent,
                  let picture = NSImage(contentsOf: imageFolder.appending(path: fileName, directoryHint: .notDirectory)),
                  picture.size.width > 0, picture.size.height > 0 else { return nil }
            // Smaller than the box stays as it is; bigger is brought down to fit.
            let size = Self.fitted(picture.size, in: NSSize(width: DotGlyphs.boxSide, height: DotGlyphs.boxSide))
            image = NSImage(size: size, flipped: false) { rect in
                picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
                return true
            }
            image.isTemplate = false
        }
        // `DotsCopy.isDot` finds the dots in the menu bar's Accessibility tree by this description (the tree gives status items no names):
        // changing it, or leaving it off, makes Mantel stop finding its own dots, and nothing is made room for.
        image.accessibilityDescription = dot == .hidden ? DotsCopy.hiddenDotDescription : DotsCopy.alwaysDotDescription
        return image
    }

    /// A template picture of the box's size: `draw` paints black on it, and the menu bar colours it.
    private static func template(_ draw: @escaping (NSSize) -> Void) -> NSImage {
        let size = NSSize(width: DotGlyphs.boxSide, height: DotGlyphs.boxSide)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            draw(rect.size)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `size` as it is when it fits in `box`, and brought down to fit, keeping its shape, when it doesn't.
    private static func fitted(_ size: NSSize, in box: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let factor = min(box.width / size.width, box.height / size.height, 1)
        return NSSize(width: size.width * factor, height: size.height * factor)
    }

    private func configure(_ item: NSStatusItem, autosaveName: String, action: Selector) {
        item.autosaveName = autosaveName
        // No `menu`: see the type's comment.
        item.menu = nil
        guard let button = item.button else { return }
        // macOS 27 doesn't give Accessibility the autosave name, so the button carries it as its identifier: it is how a read of the
        // menu bar tells the dots apart.
        button.setAccessibilityIdentifier(autosaveName)
        button.target = self
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
    /// a right click counts only when it was on the dot's own window, and an event counts only when it is a moment old (`DotClickRule`).
    private func clicked(_ dot: DotKind, from sender: NSStatusBarButton) {
        // The menu is being asked for, and the system sent the action in the middle of it: that is no click, and answering it would ask again.
        guard !opening.isAsking else { return }
        let current = NSApp.currentEvent
        let event = DotClickRule.event(isLeftMouseUp: current?.type == .leftMouseUp, isRightMouseUp: current?.type == .rightMouseUp,
                                       isOnTheDotsWindow: current?.window === sender.window,
                                       age: current.map { ProcessInfo.processInfo.systemUptime - $0.timestamp } ?? 0)
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
        let commandBar = NSMenuItem(title: DotsCopy.commandBarItem, action: #selector(commandBarChosen), keyEquivalent: "")
        commandBar.target = self
        menu.addItem(commandBar)
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

    /// Opens the menu for a right click on a dot, the way `DotMenuPlacement` says: through the dot's status item when the click was on the
    /// display the item's button is on, and otherwise popped up under the dot that was clicked.
    ///
    /// - **Through the status item:** it is given the menu and its button is clicked, and the system puts the menu under the dot. The item
    ///   has a menu only while it is open: `menuDidClose` takes it away, so that the left click is the reveal again. The dot is lit while
    ///   the menu is open: the system does that for a menu a status item has itself. With a menu set the button doesn't send its action,
    ///   so this is not entered again, and if it ever did, `opening` makes that action no click.
    /// - **Popped up:** a status item has one button, in one window, on one display, and its menu opens under that window whichever
    ///   display's dot was clicked. So the menu is shown at a point of its own, under the dot's slot on the bar that was clicked. The menu
    ///   is the same one and tracks the same way (arrow keys, type-ahead, Return, Esc, the shortcut letters). What it doesn't get is the
    ///   status item's own: the dot isn't lit while the menu is open.
    ///
    /// Nothing says the menu will open. A status item's menu that hasn't opened by the time the click returns is looked for again a
    /// moment later (the click may return before the menu has begun to track); when it still hasn't, the item's menu is taken away at
    /// once and the log says so, so that the left click keeps revealing. A menu that was popped up has been tracked by the time the call
    /// returns, so it is looked for then.
    private func openMenu(on dot: DotKind) {
        dispatchPrecondition(condition: .onQueue(.main))
        let item = statusItem(for: dot)
        let decision = menuPlacement(dot, NSEvent.mouseLocation, item.button?.window?.frame)
        guard case .popUp(let point, _) = decision else {
            openMenuThroughStatusItem(on: dot)
            return
        }
        // Put off to the run loop's next turn, as the shortcut's menu is (`popUpMenuAtPointer`), so that the menu's tracking loop runs
        // inside no queued block, and not inside the button's action.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.popUpMenu(at: point) }
        }
    }

    private func popUpMenu(at point: CGPoint) {
        guard let ticket = opening.beginAsking() else { return }
        defer { opening.endAsking() }
        focusModeItem.state = isFocusModeOn ? .on : .off
        menu.popUp(positioning: nil, at: point, in: nil)
        checkThatTheMenuOpened(since: ticket)
    }

    private func openMenuThroughStatusItem(on dot: DotKind) {
        guard let ticket = opening.beginAsking() else { return }
        defer { opening.endAsking() }
        let item = statusItem(for: dot)
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

    /// Opens the menu at the pointer, wherever the dots are (and when they are off the bar): the shortcut for Mantel's menu does this.
    /// It is put off to the run loop's next turn, in the common modes, and not onto the main queue: the menu's tracking loop then runs
    /// inside no queued block, so work that is waiting on the main queue (such as quitting from this menu) isn't held up by it.
    func popUpMenuAtPointer() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.focusModeItem.state = self.isFocusModeOn ? .on : .off
                self.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
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
    @objc private func commandBarChosen() { openCommandBar() }
    @objc private func focusModeChosen() { actions.toggleFocusMode() }
    @objc private func refreshChosen() { actions.refresh() }
    @objc private func diagnosticsChosen() { actions.openDiagnostics() }
}
