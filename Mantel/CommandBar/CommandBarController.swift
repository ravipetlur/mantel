import AppKit
import MKCommands
import MKCore
import MKLayout
import MKMenuBar
import MKSearch
import SwiftUI

/// The command bar: a panel with a search field over the icons in the menu bar and Mantel's own actions. Return clicks the icon that is
/// selected (⌥, ⌘ and ⇧ say how), or runs the action.
///
/// - **Opening** (the hotkey, or "Command Bar…" in the dots' menu) closes Mantel's other panels (`PanelMath.closes`), puts the panel on the
///   screen with the pointer (`PanelMath.commandBarFrame`) and makes it key, and asks the providers what they offer, once
///   (`CommandBarSearch.open`). Every keystroke filters that answer.
/// - **Keys** are `CommandBarKeys`'s. The panel is offered each press first.
/// - **Activating** is in this order: the pick goes to the recent picks (saved to `icons.json`), then the icon is clicked (through the one
///   click driver, which tells a failure with its toast) or shown, or the action is run. For a click the panel closes at the driver's
///   `beforeClick`: once the icon is on the bar. For a show it closes once the show wasn't refused; an action closes it first.
/// - **Closing** orders the panel out, which gives the key back to the front app's window. Nothing here makes Mantel the active app.
/// - **It closes** on Esc, a click outside it, losing key, a change of displays, another panel opening and quitting.
@MainActor
final class CommandBarController {
    /// What the command bar asks of the rest of the app.
    struct Host {
        /// The icons as they are now, for the icons provider.
        let iconEntries: @Sendable () async -> [IconSearchEntry]
        /// What decides which of Mantel's actions apply now.
        let actionState: @Sendable () async -> MantelActionState
        /// An event for the reveal, from the keyboard (the `.hotkey` trigger).
        let reveal: (RevealEvent) -> Void
        let openSecondBar: () -> Void
        let refresh: () async -> Void
        let recapture: () async -> Void
        let openSettings: (SettingsPage?) -> Void
        /// Shows an icon without clicking it. Tells a refusal with a toast, and returns it (nil when the icon was shown).
        let showIcon: (ItemID, String) async -> IconClickFailure?
        /// Changes `icons.json` through the one writer of it, in the order of the calls.
        let writeIconPreferences: (@escaping @Sendable (inout IconPreferences) -> Void) -> Void
    }

    private let panels: MantelPanels
    private let environment: PanelEnvironment
    private let store: SettingsStore
    private let host: Host
    private let rules = ClickRouteRules.measured
    private let model = CommandBarModel()
    private let panel: CommandBarPanel
    private var search: CommandBarSearch?
    /// Counts openings, so that what an opening asked for isn't taken by the next.
    private var openings = 0
    /// Counts searches, so that the newest answer is the one that is shown.
    private var searches = 0
    private var display: DisplayInfo?
    private var mouseMonitor: Any?
    private var isSending = false

    var isOpen: Bool { panels.open.contains(.commandBar) }

    init(panels: MantelPanels, store: SettingsStore, host: Host) {
        self.panels = panels
        environment = panels.environment
        self.store = store
        self.host = host
        panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMath.commandBarWidth, height: PanelMath.commandBarFieldHeight))
        let hosting = NSHostingView(rootView: CommandBarView(model: model, images: panels.environment.images,
                                                             activate: { [weak self] place in self?.activateByClick(place) }))
        // `place(results:)` alone sizes the panel: the content's own size never grows it.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.keyHandler = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) ?? false } }
        panel.resignedKey = { [weak self] in MainActor.assumeIsolated { self?.close(.appSwitch) } }
        model.queryChanged = { [weak self] in self?.search(for: self?.model.query ?? "") }
        panels.closeCommandBar = { [weak self] reason in self?.close(reason) }
    }

    // MARK: Opening and closing

    /// The hotkey: opens the command bar, or closes it when it is open.
    func toggle() {
        if isOpen { close(.hotkey) } else { open() }
    }

    func open() {
        guard !isOpen, let info = environment.display(named: nil) else { return }
        // Opening closes an open second bar, which puts its reveal away: it isn't a reveal to offer "Hide icons again" for.
        let secondBarWasOpen = panels.open.contains(.secondBar)
        openings += 1
        let opening = openings
        display = info
        panels.willOpen(.commandBar)
        model.reset()
        apply(style: environment.style())
        place(results: 0)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitor()
        panels.didOpen(.commandBar)
        isSending = false

        // The providers are asked once, now; what is typed meanwhile is answered when they have.
        search = nil
        Task { [weak self] in
            guard let self else { return }
            let recents = await store.load(IconPreferences.self).recentPicks
            let actionState = host.actionState
            let state: @Sendable () async -> MantelActionState = {
                var state = await actionState()
                if secondBarWasOpen { state.revealed = false }
                return state
            }
            let fresh = CommandBarSearch(providers: [IconsProvider(entries: host.iconEntries), MantelActionsProvider(state: state)],
                                         recents: recents)
            await fresh.open()
            guard openings == opening, isOpen else { return }
            search = fresh
            self.search(for: model.query)
        }
    }

    func close(_ reason: PanelCloseReason) {
        guard isOpen else { return }
        openings += 1
        removeMonitor()
        search = nil
        // The panels are told first: ordering the key panel out resigns it, and that `resignKey` has to find the bar closed, or it would
        // close it again for another reason.
        panels.didClose(.commandBar, reason)
        panel.orderOut(nil)
    }

    // MARK: Looking

    private func apply(style: PanelStyle) {
        model.style = style
        panel.hasShadow = style.shadow
        panel.appearance = switch style.appearance {
        case .matchMenuBar: environment.barAppearance()
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Puts the panel on its screen, as tall as its results need and with its top where it always is.
    private func place(results: Int) {
        guard let display else { return }
        let displays = environment.layout()
        let screen = displays.cgRect(fromAppKit: display.frame)
        panel.setFrame(displays.appKitRect(fromCG: PanelMath.commandBarFrame(screen: screen, results: results)), display: true)
        panel.invalidateShadow()
    }

    // MARK: Searching

    private func search(for query: String) {
        guard let search else { return }
        searches += 1
        let this = searches
        let opening = openings
        Task { [weak self] in
            let results = await search.results(for: query)
            // An answer from an earlier opening must not fill this one's list, however quickly it was opened again.
            guard let self, searches == this, openings == opening, isOpen else { return }
            let before = model.selectedResult?.id
            model.set(results: results)
            showFooter()
            place(results: results.count)
            if model.selectedResult?.id != before { announceSelection() }
        }
    }

    /// VoiceOver keeps its focus in the field, so the result Return would act on is said aloud when it changes: its title, then its subtitle.
    private func announceSelection() {
        guard let candidate = model.selectedResult?.candidate else { return }
        let words = [candidate.title, candidate.subtitle].compactMap { $0 }.joined(separator: ", ")
        AccessibilityNotification.Announcement(words).post()
    }

    private func showFooter() {
        model.footer = CommandBarKeys.footer(for: model.selectedResult?.candidate.kind, postedRightWorks: rules.postedRightWorks,
                                             postedOptionWorks: rules.postedOptionWorks)
    }

    // MARK: Keys

    /// A key press in the panel: true when it was the command bar's.
    private func handle(_ event: NSEvent) -> Bool {
        // A press that is part of what an input method is composing is the field's.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let activation = CommandBarKeys.activation(
            keyCode: event.keyCode, modifiers: ModifierSet(cocoaFlags: event.modifierFlags.rawValue),
            selected: model.selectedResult?.candidate.kind, postedRightWorks: rules.postedRightWorks, postedOptionWorks: rules.postedOptionWorks)
        switch activation {
        case .ignored:
            return false
        case .nothing:
            break
        case .close:
            close(.escape)
        case .moveUp:
            model.moveSelection(by: -1)
            showFooter()
            announceSelection()
        case .moveDown:
            model.moveSelection(by: 1)
            showFooter()
            announceSelection()
        case .click, .show, .run:
            // A held Return repeats; one press is one pick.
            if !event.isARepeat { activate(activation) }
        }
        return true
    }

    /// A click on a result: an icon is clicked, an action is run.
    private func activateByClick(_ place: Int) {
        guard model.results[safe: place] != nil else { return }
        model.moveSelection(by: place - (model.selected ?? place))
        switch model.results[place].candidate.kind {
        case .icon: activate(.click(.left))
        case .action: activate(.run)
        }
    }

    // MARK: Activating

    private func activate(_ activation: CommandBarActivation) {
        guard !isSending, let result = model.selectedResult else { return }
        let title = result.candidate.title
        // The pick counts as soon as it is made, whatever comes of it: an icon that then isn't running or can't be reached is still what
        // the person chose, and is the newest recent pick.
        pick(result.id)
        // What a send does when it ends is for this opening only: one the person closed and opened again meanwhile is left as it is.
        let opening = openings
        switch (result.candidate.kind, activation) {
        case (.icon(let item), .click(let kind)):
            isSending = true
            Task { [self, environment, display] in
                // The panel closes once the icon is on the bar and before the click is sent. A click that can't be made leaves it open under
                // the toast that says why.
                await environment.clicker.click(item, kind: kind, title: title, display: display?.uuid, origin: .commandBar) {
                    await self.closeForTheClick(opening)
                }
                if openings == opening { isSending = false }
            }
        case (.icon(let item), .show):
            isSending = true
            Task { [self, host] in
                // A show that is refused leaves the panel open under the toast that says why, as a refused click does.
                if await host.showIcon(item, title) == nil, openings == opening { close(.iconClick) }
                if openings == opening { isSending = false }
            }
        case (.action(let action), .run):
            close(.iconClick)
            run(action)
        default:
            break
        }
    }

    private func closeForTheClick(_ opening: Int) {
        guard openings == opening else { return }
        close(.iconClick)
    }

    /// The pick is the newest recent pick, kept in `icons.json` (which holds no shortcut, so nothing is registered again). It is written
    /// through the one writer of the file, on the file as it is when its turn comes: it is put at the front of the recents the file has
    /// then, not of the list this opening began with.
    private func pick(_ id: String) {
        host.writeIconPreferences { preferences in
            var recents = preferences.recentPicks
            recents.removeAll { $0 == id }
            recents.insert(id, at: 0)
            preferences.recentPicks = recents
        }
        // The boosts, while this opening lasts.
        guard let search else { return }
        Task { _ = await search.picked(id) }
    }

    private func run(_ action: CommandBarActionID) {
        switch action {
        case .showHidden: host.reveal(.show(.hidden))
        case .showAll: host.reveal(.show(.all))
        case .hideAgain: host.reveal(.show(.off))
        case .focusModeOn: host.reveal(.setFocusMode(true))
        case .focusModeOff: host.reveal(.setFocusMode(false))
        case .openSecondBar: host.openSecondBar()
        case .refreshMenuBar: Task { [host] in await host.refresh() }
        case .recaptureIcons: Task { [host] in await host.recapture() }
        case .openSettings: host.openSettings(nil)
        case .openLayout: host.openSettings(.layout)
        case .openHotkeys: host.openSettings(.hotkeys)
        }
    }

    // MARK: Clicks outside

    /// A mouse-down outside the panel closes it, unless it is on one of Mantel's own status items (that item's business). The global
    /// monitor sees only clicks in other apps' windows; losing key covers the rest.
    private func installMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
    }

    private func removeMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func mouseDown() {
        guard isOpen else { return }
        let displays = environment.layout()
        let spot = displays.cgPoint(fromAppKit: NSEvent.mouseLocation)
        let frame = displays.cgRect(fromAppKit: panel.frame)
        if PanelMath.isOutsideClick(spot, panel: frame, ownItemFrames: environment.ownItemFrames()) { close(.outsideClick) }
    }
}
