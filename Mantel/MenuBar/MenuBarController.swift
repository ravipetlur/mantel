import AppKit
import ApplicationServices
import MKCommands
import MKCore
import MKLayout
import MKMenuBar
import MKSearch
import Synchronization

/// The session, for what is made before it: the controller of the engines asks it for a look at the bar. Set once, as the session is
/// made. It isn't tied to the main actor, as the rest of the app is: the controller asks from its own actor, and its lock is all that
/// the answer waits for, not a turn of the main thread.
private nonisolated final class SessionLink: Sendable {
    private let held = Mutex<MenuBarSession?>(nil)

    var session: MenuBarSession? {
        get { held.withLock { $0 } }
        set { held.withLock { $0 = newValue } }
    }
}

/// Everything of Mantel that hides and reveals, so that the coordinator stays thin: the dots, the session that turns what happens into
/// plans for the engines, the reveal and what drives it, and the commands that reach it.
///
/// It owns the scanner, the three engines and the controller that keeps one in charge, the session, the model of the session's state, the
/// reveal controller, the dots, the pointer monitors and the clock-click controller. (The one source of running apps, and the engine
/// that works through the System Settings switches, are the coordinator's.) The session is the only caller
/// of the engines, apart from the clock-click controller, which lifts the allowlist for a click on the clock and puts it back.
///
/// - **Events go to the session in order,** through a queue of their own: a start or quit of an app, a change of displays, another app in
///   front, a change of settings, Settings opening. They wait for the session's start, which takes two reads of the menu bar, and so does
///   a reveal (the session begins collapsed when it has loaded the sections, and would undo one that came before). Nothing else waits
///   for it: the dots are there from the moment they are made, and the launch goes on.
/// - **The launch isn't held up.** `start()` returns at once; the session starts on its own task.
/// - **The state comes back** as a stream the model copies, and the dots are drawn from the model.
/// - **Quitting** (`tearDownForQuit`) stops the tap, the monitors and a takeover, and has the session take the engine down.
@MainActor
final class MenuBarController: MenuBarCommanding {
    let model: MenuBarModel
    /// The pictures of the menu bar's icons, for whatever draws one.
    let itemImages: ItemImages

    private let store: SettingsStore
    private let runningApps: RunningAppsSource
    /// The displays as they are now, for turning the buttons' frames (AppKit's) into the slots' (CoreGraphics').
    private let layout: @Sendable () -> DisplayLayout
    private let session: MenuBarSession
    /// What takes the pictures of the icons at the moments that call for them; the session asks it.
    private let imageCollector: ItemImageCollector
    private let classifier: PointerClassifier
    private let takeover: MenuBarTakeover
    private let sessionStart: SessionStart
    private let resetter: MenuBarResetter
    /// What restarts MenuBarAgent by itself when a change of displays leaves the menu bar stuck: the same restarter and flag as a reset.
    private let stuckBarRecovery: StuckBarRecovery
    private let reveal: RevealController
    private let dots: DotsController
    /// The spacers, groups and divider as status items.
    private let ownItems: OwnItemsController
    private let monitor: EmptySpaceMonitor
    /// Follows ⌘-drags of icons, for as long as the session runs.
    private let commandDrag: CommandDragMonitor
    /// The second bar and the group panels, and which of them is open.
    let panels: MantelPanels
    /// What clicks an icon (the driver and the toast for a click that fails): the second bar's cells, and what comes after it.
    let iconClicks: IconClickService
    /// Shows Settings at a page (the coordinator's: the command bar's actions open pages).
    var openSettingsPage: (SettingsPage?) -> Void = { _ in }
    /// The coordinator's writer of `icons.json`: the command bar's recent picks go through it.
    var iconPreferencesWriter: IconPreferencesWriter?
    /// The command bar, made when it is first asked for. It asks for the icons, the reveal and the rest through the controller, which has them.
    private lazy var commandBar = CommandBarController(panels: panels, store: store, host: .init(
        iconEntries: { [weak self] in await self?.iconEntries() ?? [] },
        actionState: { [model] in
            await MainActor.run { MantelActionState(focusModeOn: model.revealState == .focusMode, revealed: [.hiddenShown, .allShown].contains(model.revealState)) }
        },
        reveal: { [reveal] in reveal.send($0, cause: RevealCause(trigger: .hotkey)) },
        openSecondBar: { [reveal] in reveal.toggleSecondBar() },
        refresh: { [weak self] in _ = await self?.refresh() },
        recapture: { [weak self] in _ = await self?.recapture() },
        openSettings: { [weak self] in self?.openSettingsPage($0) },
        showIcon: { [weak self] item, title in await self?.iconClicks.show(item, title: title) },
        writeIconPreferences: { [weak self] change in
            guard let self, let writer = iconPreferencesWriter else { return }
            writer.update(in: store, change)
        }))
    /// The layout writer's state as of the last model change, for the toast when a write fails.
    private var lastLayoutStatus: LayoutStatus?
    private let clockClicks: ClockClickController
    private let sessionEvents: AsyncSerialQueue
    private var revealSettings: RevealSettings
    private var hidingSettings: HidingSettings
    private var dotSettings: DotSettings
    private var layoutSettings: LayoutSettings
    /// What the panels read of the person's settings, as they are now.
    private let panelSettings: PanelSettings
    /// The dots' settings the session was last given for the arrangement.
    private var dotsInSession: DotSettings
    /// How macOS keeps the order table, from the platform check: the one value the applier and the session both go by.
    private let layoutRules: LayoutRules
    /// Writes macOS's order table, checks the bar shows it and puts the original back (`MenuBarSession+Layout.swift`).
    private let layoutApplier: LayoutApplier
    private var isStarted = false
    /// Set once the app is quitting: nothing is started again.
    private var isShutDown = false
    private var activationObserver: (any NSObjectProtocol)?
    /// The width of the screen the front app is on, as the session was last told.
    private var lastScreenWidth: CGFloat = 0

    /// - Parameters:
    ///   - store: where the sections are kept (`profiles.json`).
    ///   - approvals: the engine that works through the System Settings switches; it also says which apps are turned off there.
    ///   - runningApps: the one list of the apps that are running. It is started by `start()`.
    ///   - scanner: what reads the menu bar. It is the coordinator's, and not made here: what its scans learned of where each app's items
    ///     are, while they were all drawn, is what lets it say which slot an item that was concealed has been drawn in.
    ///   - layout: the displays as they are now.
    ///   - reveal, hiding, dots, secondBar: the person's settings.
    ///   - ownImages: the folder the pictures chosen for the dots are in.
    ///   - itemImagesFolder: the folder the pictures captured of the menu bar's icons are kept in.
    ///   - replayJournal: puts back what the journal still holds (a reset does it, between taking everything down and restarting the menu bar).
    ///   - resetActivity: set while a reset is under way.
    ///   - layoutRules, layout: how macOS keeps the order table, and the person's layout settings. The rules are built once, by the
    ///     coordinator, and given to the applier and the session alike.
    ///   - plist, grants, journal, home: what writes the order table through the layout file's grant (`home` is where the file is expected).
    ///   - openSettings, openDiagnostics: what the dots' menu opens.
    ///   - updates: the menu's update item; nil in a build that can't update itself, which has none.
    ///   - activation: the owner of Mantel's activation policy, which a takeover of the menu bar is one reason for.
    ///   - recordsChecked: moves the settings of the icons whose records a check of an app's saved icons took out.
    init(store: SettingsStore, approvals: ApprovalsEngine, runningApps: RunningAppsSource, scanner: MenuBarScanner,
         layout: @escaping @Sendable () -> DisplayLayout, reveal revealSettings: RevealSettings, hiding hidingSettings: HidingSettings,
         dots dotSettings: DotSettings, secondBar secondBarSettings: SecondBarSettings, ownImages: URL, itemImagesFolder: URL,
         replayJournal: @escaping @Sendable () async -> Void,
         resetActivity: ResetActivity, layoutRules: LayoutRules, layout layoutSettings: LayoutSettings, plist: PlistFileAccess,
         grants: FileGrantStore, journal: Journal, home: URL,
         openSettings: @escaping () -> Void, openDiagnostics: @escaping () -> Void, updates: DotsController.Updates?,
         activation: ActivationPolicyOwner,
         recordsChecked: @escaping @Sendable (String, SectionModel.Reconciled) async -> SettingsMoved) {
        self.store = store
        self.runningApps = runningApps
        self.layout = layout
        self.revealSettings = revealSettings
        self.hidingSettings = hidingSettings
        self.dotSettings = dotSettings
        self.layoutSettings = layoutSettings
        panelSettings = PanelSettings(secondBar: secondBarSettings, allowClockAndControlCenter: hidingSettings.allowHidingClockAndControlCenter)
        dotsInSession = dotSettings
        self.layoutRules = layoutRules
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.example.mantel"
        let model = MenuBarModel()
        let spacers = LiveSpacers()
        let takeover = MenuBarTakeover(activation: activation)
        let events = AsyncSerialQueue()
        let sessionStart = SessionStart()
        self.model = model
        self.takeover = takeover
        self.sessionStart = sessionStart
        sessionEvents = events

        let allowlist = AllowlistEngine(allowlist: LiveAllowlist(), ownBundleID: ownBundleID,
                                        isInstalledCopy: InstallLocation.verdict(for: Bundle.main.bundleURL) == .applications)
        clockClicks = ClockClickController(allowlist: allowlist, windows: LiveWindowList(), layout: layout)
        // The session is made after the controller of the engines, which asks it, when it switches from one engine to another, whether the
        // bar shows the plan (a look at the bar, as a reveal is confirmed).
        let sessionLink = SessionLink()
        let hiding = HidingController(
            engines: [.allowlist: allowlist, .approvals: approvals, .spacer: SpacerEngine(spacers: spacers)], clock: SystemClock(),
            confirm: { plan in await sessionLink.session?.lookForHiding(of: plan) ?? .cantTell })
        let session = MenuBarSession(
            scanner: scanner, hiding: hiding, runningApps: { runningApps.all },
            loadSections: { await store.load(ProfilesDocument.self).active },
            saveSections: { sections in
                var document = await store.load(ProfilesDocument.self)
                document.active = sections
                await store.save(document)
            },
            turnedOff: { await approvals.turnedOff() }, settings: hidingSettings, ownBundleID: ownBundleID, clock: SystemClock(),
            windows: LiveWindowList(), sessionState: LiveSessionState(), recordsChecked: recordsChecked)
        self.session = session
        sessionLink.session = session

        // The order table: written by the applier on a task of its own, which reads the bar through the session, tells it when the bar is
        // settling, and waits while the wide spacer has the menu bar.
        let writer = LayoutTableWriter(access: plist, reader: LayoutTableReader(access: plist, grants: grants), grants: grants,
                                       journal: journal, home: home, broken: layoutRules.broken)
        let windows = LiveWindowList()
        layoutApplier = LayoutApplier(
            writer: writer, rules: layoutRules, clock: SystemClock(), read: { await sessionLink.session?.readForCheck() },
            shownBars: { BarVisibility.shownBars(windows.onScreenWindows(), bars: $0.bars) },
            phase: { pending, settling, revision in
                await sessionLink.session?.setLayoutPhase(pending: pending, settling: settling, revision: revision)
            },
            held: { LayoutHold.reason(engine: await sessionLink.session?.engineStatus().kind) })

        // The pictures of the icons: taken at the moments the session names, kept in the store, and handed out by the loader.
        let imageStore = ItemImageStore(folder: itemImagesFolder, clock: SystemClock())
        imageCollector = ItemImageCollector(store: imageStore, capture: StripCapture(), layout: layout, windows: LiveWindowList(),
                                            screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
                                            mayCapture: { await sessionLink.session?.layoutCaptureRefusal },
                                            clock: SystemClock(), rules: .measured)
        itemImages = ItemImages(store: imageStore, folder: itemImagesFolder, ownBundleID: ownBundleID)
        // MenuBarAgent is found in the list of running apps when it is asked to restart, and only it is signalled.
        let restarter = MenuBarAgentRestarter(runningApps: { runningApps.all })
        resetter = MenuBarResetter(session: session, restarter: restarter, replayJournal: replayJournal,
                                   activity: resetActivity)
        stuckBarRecovery = StuckBarRecovery(restarter: restarter, activity: resetActivity)

        let classifier = PointerClassifier(windows: LiveWindowList(), layout: layout)
        self.classifier = classifier
        let reveal = RevealController(session: session, sessionStart: sessionStart, model: model, classifier: classifier,
                                      windows: LiveWindowList(), takeover: takeover, settings: revealSettings,
                                      secondBar: secondBarSettings)
        self.reveal = reveal

        dots = DotsController(actions: .init(
            dotClicked: { reveal.send(.dotClicked($0)) },
            openSettings: openSettings,
            toggleFocusMode: { reveal.send(.toggleFocusMode) },
            refresh: { events.enqueue { await session.refresh() } },
            openDiagnostics: openDiagnostics, updates: updates),
            settings: dotSettings, imageFolder: ownImages)
        let ownItems = OwnItemsController(imageFolder: ownImages)
        self.ownItems = ownItems

        // The panels: the second bar and the group panels, and the one click driver their cells go through.
        let clicker = IconClickService(session: session, scanner: scanner, layout: layout, rehide: revealSettings.rehide)
        iconClicks = clicker
        let panelSettings = panelSettings, dots = dots, itemImages = itemImages
        let panels = MantelPanels(environment: PanelEnvironment(
            model: model, images: itemImages, runningApps: runningApps, layout: layout, clicker: clicker,
            style: { panelSettings.secondBar.style }, allowClockAndControlCenter: { panelSettings.allowClockAndControlCenter },
            barAppearance: { dots.barAppearance },
            ownButtonFrames: { (Array(dots.buttonFrames().values) + Array(ownItems.buttonFrames().values)).map { layout().cgRect(fromAppKit: $0) } },
            displaysChangedAt: { panelSettings.displaysChangedAt }, revealStamp: { reveal.stamp },
            iconClickSent: { reveal.iconClickSent(stamp: $0) }))
        panels.onChange = { reveal.panelsChanged() }
        reveal.attach(panels)
        self.panels = panels

        // The pointer resting on a group's icon opens its panel (not made key: a hover never takes the keyboard) and leaving both closes it.
        let monitor = EmptySpaceMonitor(
            classifier: classifier, send: { reveal.send($0) },
            groupActions: .init(
                open: { group in
                    // The pointer opens no panel while the command bar is open (`PanelMath.pointerOpensPanels`); a panel that is open
                    // already (a click opened it) is left, and one for a group with nothing to list doesn't open: the hover is told it
                    // opened nothing, so it never closes what it didn't open.
                    guard PanelMath.pointerOpensPanels(open: panels.open), panels.group.openGroup != group else { return false }
                    Self.toggleGroupPanel(group, makeKey: false, on: panels)
                    return panels.group.openGroup == group
                },
                close: { group in
                    // Only the panel the hover opened: never another group's, that a click opened since.
                    guard panels.group.openGroup == group else { return }
                    panels.group.close(.hoverEnded)
                },
                panelFrame: { panels.group.panelFrame }))
        self.monitor = monitor
        panels.onClosed = { (panel: MantelPanel, reason: PanelCloseReason) in
            reveal.panelClosed(panel, reason)
            if case .group(let group) = panel { monitor.groupPanelClosed(group) }
        }

        // A ⌘-drag in a bar: the session keeps the order macOS shows, and (when the person turned it on) everything is shown on the bar
        // while the icon is moved. The queue keeps the session's calls in order: the begin, then the follow after the end.
        commandDrag = CommandDragMonitor(classifier: classifier, actions: .init(
            began: { showAll, seen in events.enqueue { await session.commandDragBegan(showAll: showAll, seenAt: seen) } },
            showAll: { reveal.commandDragShowsAll() },
            follow: { dropped, end in await events.run { await session.commandDragEnded(droppedAt: dropped, end: end) } },
            collapse: { reveal.commandDragCollapses(to: $0) }))

        commandDrag.showsAll = { [weak self] earlierDragShowing in
            CommandDragLog.ShowAll.decide(settingOn: self?.layoutSettings.showAllWhileCommandDragging == true,
                                          revealAllows: reveal.commandDragMayShowAll, earlierDragShowing: earlierDragShowing)
        }
        commandDrag.revealNow = { reveal.revealLevel }
        ownItems.groupClicked = { [weak self] in self?.groupIconClicked($0) }
        model.changed = { [weak self] in self?.modelChanged() }
        dots.menuPlacement = { dot, pointer, buttonFrame in
            let displays = layout()
            let decision = DotMenuPlacement.decide(dot: dot, pointer: pointer, buttonFrame: buttonFrame, displays: displays,
                                                   inventory: model.state?.inventory, displaysChangedAt: panelSettings.displaysChangedAt,
                                                   barHeight: NSStatusBar.system.thickness)
            if case .popUp(let point, let anchor) = decision {
                Log.info("dots", DotMenuPlacement.popUpLogLine(at: point, under: anchor, displays: displays))
            }
            return decision
        }
        dots.openCommandBar = { [weak self] in
            // The item's action comes as the menu closes: the panel is made key once the menu has finished tracking.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.commandBar.open() } }
        }
    }

    // MARK: Starting

    /// Begins: the running apps are watched, the session starts (on its own task: this returns at once), the state is copied as it
    /// changes, and the pointer is listened to if a reveal needs it.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        let session = session

        runningApps.start { [sessionEvents] change in
            sessionEvents.enqueue { await session.runningAppsChanged(change) }
        }
        observeFrontApp()
        updatePointerMonitor()
        commandDrag.setInstalled(true)

        Task { [model] in
            for await state in await session.states() { model.apply(state) }
        }

        // The session starts on a task of its own, which a reveal waits for (`SessionStart`) and the events behind it wait for. Then it is
        // told what the front app is, so that the wide-screen rule and the pointer's classification have it.
        // The collector is in place before the session starts: the launch's pictures are taken by its first read.
        itemImages.start()
        let collector = imageCollector
        let applier = layoutApplier, rules = layoutRules, layoutSettings = layoutSettings, dots = dotSettings
        let recovery = stuckBarRecovery
        let starting = Task {
            await session.setImageCollector(collector)
            await session.setStuckBarRecovery(recovery)
            await session.setLayout(applier, rules: rules, settings: layoutSettings, dots: dots)
            await session.start()
        }
        sessionStart.task = starting
        let front = reportedFrontApp()
        let width = Self.activeScreenWidth()
        lastScreenWidth = width
        let classifier = classifier
        sessionEvents.enqueue {
            await starting.value
            if let front { await session.frontAppChanged(pid: front, activeScreenWidth: width) }
            await classifier.update(appMenuFrames: await session.frontAppMenuFrames())
        }
    }

    // MARK: What the session is told

    /// The displays changed. The session reads the menu bar again, and learns the width of the screen the person is working on.
    func displaysChanged(_ layout: DisplayLayout) {
        // What the last read says of where the dots are is in the old coordinates until the next one (`PanelAnchors`).
        panelSettings.displaysChangedAt = Date()
        panels.closeAll(.displayChange)
        guard isStarted else { return }
        let session = session, classifier = classifier
        let front = reportedFrontApp()
        let width = Self.activeScreenWidth()
        let widthChanged = width != lastScreenWidth
        lastScreenWidth = width
        sessionEvents.enqueue {
            await session.displaysChanged(layout)
            if widthChanged, let front { await session.frontAppChanged(pid: front, activeScreenWidth: width) }
            await classifier.update(appMenuFrames: await session.frontAppMenuFrames())
        }
    }

    /// Settings opened or closed: the menu bar is read more often while it is open.
    func setSettingsOpen(_ open: Bool) {
        guard isStarted else { return }
        let session = session
        sessionEvents.enqueue { await session.setSettingsOpen(open) }
    }

    /// The person's settings changed: only what is different is passed on.
    func settingsChanged(reveal newReveal: RevealSettings, hiding newHiding: HidingSettings, dots newDots: DotSettings,
                         layout newLayout: LayoutSettings, secondBar newSecondBar: SecondBarSettings) {
        if newSecondBar != panelSettings.secondBar {
            panelSettings.secondBar = newSecondBar
            reveal.secondBarSettingsChanged(newSecondBar)
            panels.styleChanged()
        }
        if newHiding.allowHidingClockAndControlCenter != panelSettings.allowClockAndControlCenter {
            panelSettings.allowClockAndControlCenter = newHiding.allowHidingClockAndControlCenter
            // An open panel lists the clock and Control Center, or doesn't, by this.
            panels.styleChanged()
        }
        if newDots != dotSettings {
            dotSettings = newDots
            dots.setSettings(newDots)
            // Hiding the dots, setting •• to always and the divider change what is on the bar.
            refreshOwnItems()
        }
        if newLayout != layoutSettings || newDots != dotsInSession {
            layoutSettings = newLayout
            dotsInSession = newDots
            if isStarted, !isShutDown {
                let session = session, applier = layoutApplier, rules = layoutRules
                sessionEvents.enqueue { await session.setLayout(applier, rules: rules, settings: newLayout, dots: newDots) }
            }
        }
        if newReveal != revealSettings {
            revealSettings = newReveal
            reveal.settingsChanged(newReveal)
            iconClicks.setRehide(newReveal.rehide)
            updatePointerMonitor()
        }
        if newHiding != hidingSettings {
            hidingSettings = newHiding
            guard isStarted else { return }
            let session = session
            sessionEvents.enqueue { await session.setSettings(newHiding) }
        }
    }

    // MARK: What the person changes in Settings

    // Each goes to the session on the queue of the session's events, as the others do: never from a task a view could cancel (a pane that
    // is closed ends its tasks, and a move that was begun must be finished). Each returns at once; the state that comes back from the
    // session is what the panes draw, so a change shows when the session has made it.

    /// The person moves an app (all its icons) to a section.
    func move(app bundleID: String, to section: MenuBarSection) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.move(app: bundleID, to: section) }
    }

    /// The person moves a system icon (the item itself) to a section.
    func move(item: ItemID, to section: MenuBarSection) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.move(item: item, to: section) }
    }

    /// Where apps that are new go.
    func setNewItemsSection(_ section: MenuBarSection) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.setNewItemsSection(section) }
    }

    // MARK: The layout editor

    /// A drop, a menu's move or an add in the layout editor, handed to the session on the queue of its events. It says the tokens the
    /// thing lands between, and the session works out the place in its list when the change runs, on its model as it is then: a change
    /// before it in the queue may have changed the list. When it no longer lands where it was dropped, nothing is written.
    func apply(_ request: DropRequest) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { _ = await session.drop(request) }
    }

    func update(spacer: LayoutSpacer) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.updateSpacer(spacer) }
    }

    func update(group: IconGroup) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.updateGroup(group) }
    }

    /// Takes a spacer or a group off the layout.
    func remove(ownItem item: ItemID) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.removeOwnItem(item) }
    }

    /// Puts the order the person had back (`MenuBarSession.restoreOriginalLayout`), after the changes that were asked for before it.
    func restoreOriginalLayout() async -> Result<Int, LayoutWriteError> {
        guard isStarted, !isShutDown else { return .failure(.needsGrant) }
        let session = session
        return await sessionEvents.run { await session.restoreOriginalLayout() }
    }

    /// Takes the pictures of the icons again and says so with a toast, as the Recapture button does. It takes a while and is not one of
    /// the queue's events: a reveal waits behind each of those.
    func recaptureIcons() {
        Task { _ = await recapture() }
    }

    /// Drops what is known of an app that isn't running. It is placed again, in the new-items section, if it is seen again.
    func forget(app bundleID: String) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.forget(app: bundleID) }
    }

    /// The person gave Mantel a file, or put back what an earlier run left: what can be used, and what is turned off in System Settings,
    /// are asked again (`MenuBarSession.permissionsChanged`).
    func permissionsChanged() {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.permissionsChanged() }
    }

    /// An icon's own hotkey was pressed: it shows the icon, or shows and clicks it, on the display the pointer is on. A click that fails
    /// says why in a toast.
    func iconHotkeyFired(_ item: ItemID, _ action: IconHotkeyAction) {
        guard isStarted, !isShutDown else { return }
        let display = pointerDisplay()
        Task {
            await sessionStart.finished()
            switch action {
            case .show:
                await iconClicks.show(item, title: await iconTitle(item))
            case .click(let kind):
                await iconClicks.click(item, kind: kind, title: await iconTitle(item), display: display, origin: .hotkey)
            }
        }
    }

    /// The display the pointer is on (the main one when it can't be told).
    private func pointerDisplay() -> String? {
        let displays = DisplayLayout.current()
        return (displays.display(containing: NSEvent.mouseLocation) ?? displays.main)?.uuid
    }

    /// A hotkey was pressed. True when it is one the menu bar handles.
    @discardableResult
    func hotkeyFired(_ id: HotkeyID) -> Bool {
        // Mantel's menu opens at the pointer, with the dots on the bar or off it.
        if id == .mantelMenu {
            dots.popUpMenuAtPointer()
            return true
        }
        if id == .secondBar {
            reveal.toggleSecondBar()
            return true
        }
        if id == .commandBar {
            commandBar.toggle()
            return true
        }
        guard let event = RevealEvent.forHotkey(id) else { return false }
        reveal.send(event)
        return true
    }

    private func observeFrontApp() {
        let own = NSRunningApplication.current.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.appActivated(pid, own: own) }
        }
    }

    /// The app that is in front, when it is one the session is to be told of: Mantel's own windows taking the focus is not (`reportsFrontApp`).
    private func reportedFrontApp() -> pid_t? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              MenuBarTakeoverPolicy.reportsFrontApp(activated: pid, own: NSRunningApplication.current.processIdentifier,
                                                    takeoverActive: takeover.isActive) else { return nil }
        return pid
    }

    private func appActivated(_ pid: pid_t, own: pid_t) {
        guard MenuBarTakeoverPolicy.reportsFrontApp(activated: pid, own: own, takeoverActive: takeover.isActive) else { return }
        let session = session, classifier = classifier
        let width = Self.activeScreenWidth()
        lastScreenWidth = width
        sessionEvents.enqueue {
            await session.frontAppChanged(pid: pid, activeScreenWidth: width)
            await classifier.update(appMenuFrames: await session.frontAppMenuFrames())
        }
    }

    /// The width of the screen the person is working on, in points; 0 when there is no screen.
    private static func activeScreenWidth() -> CGFloat {
        NSScreen.main?.frame.width ?? 0
    }

    // MARK: What the model says

    private func modelChanged() {
        let state = model.state
        refreshOwnItems()
        if let inventory = state?.inventory {
            classifier.update(inventory: inventory)
            iconClicks.setBars(inventory.bars)
        }
        clockClicks.update(state)
        panels.stateChanged()
        if let toast = ToastCopy.layout(previous: lastLayoutStatus, now: state?.layout) { HUDToast.show(symbol: toast.symbol, text: toast.text) }
        lastLayoutStatus = state?.layout
    }

    // MARK: Own items

    /// Puts the dots, spacers, groups and divider on the bar or takes them off as the layout, the plan and the person's settings say
    /// (`OwnItemsVisibility`), and makes the status items the layout holds. Nothing here asks the session for a write of the order: only
    /// what the person changes in the layout does.
    private func refreshOwnItems() {
        let state = model.state
        let shown = state.map {
            OwnItemsVisibility.shown(sections: $0.sections, plan: $0.plan, dots: dotSettings, alwaysHiddenHasApps: $0.alwaysHiddenHasApps)
        } ?? OwnItemsVisibility.beforeTheFirstRead(dots: dotSettings)
        dots.update(reveal: model.revealState, shown: shown, engine: state?.engine)
        ownItems.update(sections: state?.sections, shown: shown)
        let hoverGroups = state?.sections.groups.values.filter(\.opensOnHover).map(\.id) ?? []
        monitor.setHoverGroups(Set(hoverGroups))
        updatePointerMonitor()
    }

    /// The pointer is listened to while a reveal asks for it, or a group opens on hover.
    private func updatePointerMonitor() {
        monitor.setInstalled(isStarted && !isShutDown && (revealSettings.usesPointer || !monitor.hoverGroups.isEmpty))
    }

    // MARK: Group panels

    /// A click on a group's icon, with either button. A panel the hover opened is the person's now and takes the keyboard (the click
    /// doesn't close it); any other click opens the group's panel, key, or closes it.
    private func groupIconClicked(_ group: GroupID) {
        switch monitor.groupIconClicked(group) {
        case .makeKey: panels.group.makeKey()
        case .toggle: toggleGroupPanel(group, makeKey: true)
        }
    }

    /// Opens a group's panel under the group's icon (the slot the last read found it in), or closes it if it is the one that is open. The
    /// display is the one with the pointer; with no slot to be found the panel goes against the right edge.
    func toggleGroupPanel(_ group: GroupID, makeKey: Bool) {
        Self.toggleGroupPanel(group, makeKey: makeKey, on: panels)
    }

    /// A click opens the panel with the keyboard; the pointer resting on the icon opens it without (`makeKey` false).
    private static func toggleGroupPanel(_ group: GroupID, makeKey: Bool, on panels: MantelPanels) {
        let displays = DisplayLayout.current()
        let pointer = NSEvent.mouseLocation
        let display = (displays.display(containing: pointer) ?? displays.main)?.uuid
        panels.group.toggle(group, anchor: .group(group), display: display, makeKey: makeKey)
    }

    /// Stops the tap that holds clicks on the clock, and clears where it holds them. The coordinator calls it when the app is quitting,
    /// and the stop is final: the states the session publishes from then on start nothing again. (The same stop, but not a final one,
    /// happens by itself when another engine takes over.)
    func stopClockClicks() {
        clockClicks.shutDown()
    }

    /// Whether an order change is being written (`MenuBarSession.layoutWriteIsUnderWay`).
    func layoutWriteIsUnderWay() async -> Bool {
        await session.layoutWriteIsUnderWay()
    }

    /// Writes the order change that is still in its debounce, before anything that can take long (`MenuBarSession.flushLayoutForQuit`).
    func flushLayoutForQuit() async {
        await session.flushLayoutForQuit()
    }

    /// Returns when the settings of the icons that were taken out of the saved layout have been moved, and `following` has been done, within
    /// a limit (`MenuBarSession.finishSettingsMovesForQuit`).
    func settingsMovesFinishedForQuit(then following: @escaping @Sendable () async -> Void) async {
        await session.finishSettingsMovesForQuit(then: following)
    }

    /// What quitting does to the menu bar, before the journal is replayed:
    /// 1. the tap that holds clicks on the clock is stopped for good;
    /// 2. the pointer monitors are removed;
    /// 3. a takeover of the menu bar is ended;
    /// 4. the session stops delivering plans and reads, and takes the engine down (which shows everything and puts back what the engine
    ///    changed), waiting for that for at most 1.5 seconds.
    func tearDownForQuit() async {
        clockClicks.shutDown()
        isShutDown = true
        panels.closeAll(.quitting)
        monitor.setInstalled(false)
        commandDrag.setInstalled(false)
        takeover.end()
        await session.tearDownForQuit()
    }

    // MARK: Commands

    func show(_ target: ShowTarget) async {
        await reveal.perform(.forShow(target))
    }

    func focus(_ change: FocusChange) async -> Bool {
        await reveal.perform(.forFocus(change)) == .focusMode
    }

    /// Reads the menu bar again and applies the plan again. Says whether it did: not while a reset is under way.
    func refresh() async -> RefreshOutcome {
        let session = session
        return await sessionEvents.run { await session.refresh() }
    }

    func engine() async -> JSONValue {
        let session = session
        let status = await sessionEvents.run { await session.engineStatus() }
        return status.commandValue
    }

    /// Shows every icon, puts back what Mantel changed, restarts macOS's menu bar and hides again (`MenuBarSession.reset`), unless a platform
    /// test is changing the menu bar (`.refused`). One at a time: asked while another is under way, it starts nothing. Waits for the session
    /// to have started. (It doesn't go through the queue of the session's events: a second reset would wait in it for the first, and then
    /// run.)
    ///
    /// The reveal that the machine and the dots show is collapsed afterwards, whatever came of it: the session has collapsed its own.
    func reset() async -> ResetOutcome {
        await sessionStart.finished()
        let outcome = await resetter.reset()
        switch outcome {
        case .done, .failed:
            // The session has collapsed its own reveal: what the reveal controller applied last isn't on the bar any more.
            reveal.sessionWasReset()
            await reveal.perform(.forShow(.nothing))
        case .alreadyUnderWay, .refused: break
        }
        return outcome
    }

    // MARK: Commands about icons, the bar, the pictures and the order

    /// What the person can name an icon by, as the session last published: nil until it has.
    private func iconEntries() async -> [IconSearchEntry]? {
        guard let state = model.state else { return nil }
        var names: [String: String] = [:]
        for app in runningApps.all {
            if let id = app.bundleID, let name = app.name, names[id] == nil { names[id] = name }
        }
        let preferences = await store.load(IconPreferences.self)
        let running = Set(runningApps.all.compactMap(\.bundleID))
        return IconSearchEntries.build(inventory: state.inventory, sections: state.sections, preferences: preferences, names: names,
                                       running: running, stale: state.staleRecords)
    }

    /// What an icon is called in a toast: its entry's title, else (an app that has gone from the sections) the app's name from where it is
    /// installed, else its bundle ID.
    private func iconTitle(_ item: ItemID) async -> String {
        if let title = await iconEntries()?.first(where: { $0.item == item })?.title { return title }
        return Self.installedName(ofApp: item.bundleID) ?? item.bundleID
    }

    private static func installedName(ofApp bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        let named = [bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName"), bundle?.object(forInfoDictionaryKey: "CFBundleName")]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return named ?? url.deletingPathExtension().lastPathComponent
    }

    func icons(_ filter: IconListFilter?) async -> JSONValue {
        await sessionStart.finished()
        guard let entries = await iconEntries() else { return .array([]) }
        let appearance: BarAppearance = dots.barAppearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let rows = entries.map { entry in
            IconListRow(id: entry.item.string, app: entry.item.bundleID, name: entry.title, section: entry.section.map(Self.listed),
                        group: entry.groupTitle, image: itemImages.path(for: entry.item, appearance: appearance))
        }
        return CommandAnswers.iconList(rows, filter: filter)
    }

    private static func listed(_ section: MenuBarSection) -> IconListFilter {
        switch section {
        case .shown: .shown
        case .hidden: .hidden
        case .alwaysHidden: .always
        }
    }

    /// Shows one icon, or shows and clicks it, through the one click driver. The answer comes as soon as the click is sent.
    func icon(_ command: IconCommand, query: String, kind: ClickKind) async -> CommandResult {
        await sessionStart.finished()
        guard let entries = await iconEntries() else { return .failure(code: .unavailable, message: CommandAnswers.stillStarting) }
        switch IconQuery.resolve(query, in: entries) {
        case .failure(let error):
            return .failure(code: .badRequest, message: error.answer(for: query))
        case .success(let item):
            let title = entries.first { $0.item == item }?.title ?? item.bundleID
            switch command {
            case .show:
                if let refusal = await iconClicks.show(item, title: title, toasts: false) {
                    return IconClickOutcome.failed(refusal).result(app: title, kind: kind)
                }
                return .ok(.string(CommandAnswers.iconShown(app: title)))
            case .click:
                let outcome = await iconClicks.click(item, kind: kind, title: title, display: pointerDisplay(), origin: .command, toasts: false)
                return outcome.result(app: title, kind: kind)
            }
        }
    }

    func bar(_ change: BarChange, all: Bool) async -> Bool {
        // A command sent while the session starts waits here, not inside the reveal's queue, which it would hold through the whole start.
        await sessionStart.finished()
        return await reveal.changeSecondBar(change, all: all)
    }

    /// Takes the pictures of the icons again and shows the toast when pictures were taken. What is left of the bar's capture throttle is
    /// waited out by the session, on its clock and after it has asked whether it can run at all.
    func recapture() async -> CommandResult {
        guard isStarted, !isShutDown else { return .failure(code: .unavailable, message: CommandAnswers.stillStarting) }
        await sessionStart.finished()
        let summary = await session.recaptureIcons()
        if summary.skipped == nil, summary.captured > 0 {
            HUDToast.show(symbol: ToastCopy.iconsCaptured.symbol, text: ToastCopy.iconsCaptured.text)
        }
        return CommandAnswers.recapture(captured: summary.captured, skipped: summary.skipped)
    }

    func restoreLayout() async -> CommandResult {
        await sessionStart.finished()
        // Before the session has started, or while Mantel quits, the layout file's grant isn't what is missing.
        guard isStarted else { return .failure(code: .unavailable, message: CommandAnswers.stillStarting) }
        guard !isShutDown else { return .failure(code: .unavailable, message: CommandAnswers.quitting) }
        return await restoreOriginalLayout().restoreResult
    }
}
