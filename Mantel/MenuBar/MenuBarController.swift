import AppKit
import ApplicationServices
import MKCommands
import MKCore
import MKLayout
import MKMenuBar
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
/// that works through the System Settings switches, are the coordinator's: the probes use them too.) The session is the only caller
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

    private let runningApps: RunningAppsSource
    private let session: MenuBarSession
    private let classifier: PointerClassifier
    private let takeover: MenuBarTakeover
    private let sessionStart: SessionStart
    private let resetter: MenuBarResetter
    private let reveal: RevealController
    private let dots: DotsController
    private let monitor: EmptySpaceMonitor
    private let clockClicks: ClockClickController
    private let sessionEvents: AsyncSerialQueue
    private var revealSettings: RevealSettings
    private var hidingSettings: HidingSettings
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
    ///   - layout: the displays as they are now.
    ///   - reveal, hiding: the person's settings.
    ///   - replayJournal: puts back what the journal still holds (a reset does it, between taking everything down and restarting the menu bar).
    ///   - resetRefusal: why a reset can't be made now, if it can't (a platform test is changing the menu bar). Asked at the start of each.
    ///   - resetActivity: set while a reset is under way, for the probes.
    ///   - openSettings, openDiagnostics: what the dots' menu opens.
    ///   - activation: the owner of Mantel's activation policy, which a takeover of the menu bar is one reason for.
    init(store: SettingsStore, approvals: ApprovalsEngine, runningApps: RunningAppsSource, layout: @escaping @Sendable () -> DisplayLayout,
         reveal revealSettings: RevealSettings, hiding hidingSettings: HidingSettings,
         replayJournal: @escaping @Sendable () async -> Void, resetRefusal: @escaping @Sendable () async -> String?,
         resetActivity: ResetActivity,
         openSettings: @escaping () -> Void, openDiagnostics: @escaping () -> Void, activation: ActivationPolicyOwner) {
        self.runningApps = runningApps
        self.revealSettings = revealSettings
        self.hidingSettings = hidingSettings
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

        let scanner = MenuBarScanner(ax: AXClient(), runningApps: { runningApps.regular }, layout: layout, ownBundleID: ownBundleID,
                                     isTrusted: { AXIsProcessTrusted() })
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
            windows: LiveWindowList())
        self.session = session
        sessionLink.session = session
        // MenuBarAgent is found in the list of running apps when it is asked to restart, and only it is signalled.
        resetter = MenuBarResetter(session: session, restarter: MenuBarAgentRestarter(runningApps: { runningApps.all }),
                                   replayJournal: replayJournal, refusal: resetRefusal, activity: resetActivity)

        let classifier = PointerClassifier(windows: LiveWindowList(), layout: layout)
        self.classifier = classifier
        let reveal = RevealController(session: session, sessionStart: sessionStart, model: model, classifier: classifier,
                                      windows: LiveWindowList(), takeover: takeover, settings: revealSettings)
        self.reveal = reveal
        monitor = EmptySpaceMonitor(classifier: classifier, send: { reveal.send($0) })

        dots = DotsController(actions: .init(
            dotClicked: { reveal.send(.dotClicked($0)) },
            openSettings: openSettings,
            toggleFocusMode: { reveal.send(.toggleFocusMode) },
            refresh: { events.enqueue { await session.refresh() } },
            openDiagnostics: openDiagnostics))

        model.changed = { [weak self] in self?.modelChanged() }
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
        monitor.setInstalled(revealSettings.usesPointer)

        Task { [model] in
            for await state in await session.states() { model.apply(state) }
        }

        // The session starts on a task of its own, which a reveal waits for (`SessionStart`) and the events behind it wait for. Then it is
        // told what the front app is, so that the wide-screen rule and the pointer's classification have it.
        let starting = Task { await session.start() }
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
    func settingsChanged(reveal newReveal: RevealSettings, hiding newHiding: HidingSettings) {
        if newReveal != revealSettings {
            revealSettings = newReveal
            reveal.settingsChanged(newReveal)
            if isStarted, !isShutDown { monitor.setInstalled(newReveal.usesPointer) }
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

    /// Drops what is known of an app that isn't running. It is placed again, in the new-items section, if it is seen again.
    func forget(app bundleID: String) {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.forget(app: bundleID) }
    }

    /// The person gave Mantel a file, or put back what a platform test left: what can be used, and what is turned off in System Settings,
    /// are asked again (`MenuBarSession.permissionsChanged`).
    func permissionsChanged() {
        guard isStarted, !isShutDown else { return }
        let session = session
        sessionEvents.enqueue { await session.permissionsChanged() }
    }

    /// A hotkey was pressed. True when it is one the menu bar handles.
    @discardableResult
    func hotkeyFired(_ id: HotkeyID) -> Bool {
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
        dots.update(reveal: model.revealState, alwaysHiddenHasApps: state?.alwaysHiddenHasApps ?? false, engine: state?.engine)
        if let inventory = state?.inventory { classifier.update(inventory: inventory) }
        clockClicks.update(state)
    }

    /// Stops the tap that holds clicks on the clock, and clears where it holds them. The coordinator calls it when the app is quitting,
    /// and the stop is final: the states the session publishes from then on start nothing again. (The same stop, but not a final one,
    /// happens by itself when another engine takes over.)
    func stopClockClicks() {
        clockClicks.shutDown()
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
        monitor.setInstalled(false)
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
}
