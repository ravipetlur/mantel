import AppKit
import MKCommands
import MKCore
import MKMenuBar

/// Owns everything in Mantel that lives as long as the app does: the settings store, the journal, the permission checker,
/// the command router and the control socket, the menu bar controller (the dots and what hides and reveals), and the Settings and
/// onboarding windows.
///
/// `start()` runs the launch in the order `LaunchSequence` gives, and the order matters:
/// 1. Mantel's folders are made.
/// 2. The control socket starts. Another Mantel holding it ends the launch here: this copy hands off (unless the app delegate
///    already did) and quits, having written nothing to the running copy's log.
/// 3. The log is pointed at its file, so that everything after is kept.
/// 4. The journal is replayed, and the replay finishes before anything can record into it. It is given 10 seconds: a restore
///    that hangs would otherwise keep the dots and Settings from appearing, so after that the launch goes on, and what was not
///    restored stays in the journal for the next launch.
/// 5. Every settings document in use is loaded before any is saved: the store only protects a file it has read.
/// 6. The hotkeys are registered from the bindings that were loaded.
/// 7. The dots appear, 8. the displays are watched, 9. the menu bar starts (the running apps are watched, and the session begins to hide
///    on a task of its own: the launch doesn't wait for it), and 10. onboarding opens if the person hasn't been through it.
@MainActor
final class AppCoordinator {
    let paths: MantelPaths
    /// Owns Mantel's activation policy: the windows and the menu bar takeover feed it.
    let activation: ActivationPolicyOwner
    let store: SettingsStore
    /// Made when first used, which is the launch's replay, after the log has its file: what opening it logs is then kept.
    private(set) lazy var journal = Journal(file: paths.journalFile)
    let grants: FileGrantStore
    let permissionChecker: any PermissionChecking

    /// The one list of the apps that are running, kept up to date from the workspace: the menu bar reader and the probes read it. It is
    /// here and not in the menu bar controller because the probes, which can be asked for before the menu bar is made, use it too; the
    /// controller starts it.
    let runningApps = RunningAppsSource()
    /// Reads and changes the plist files the menu bar's state is kept in, with the journal behind every change.
    private(set) lazy var plist = PlistFileAccess(journal: journal, paths: paths, grants: grants, codecs: PlistBlobCodecs.standard)
    /// The way of hiding icons that works through the "Allow in the Menu Bar" switches. Made when first used, for the same reason as the
    /// journal it keeps its changes in.
    private(set) lazy var approvalsEngine = ApprovalsEngine(access: plist, grants: grants, journal: journal)
    /// "Enable platform test" in Settings › Diagnostics: the probes that change the menu bar run only while it is on, also when the
    /// command line asks for one. Not saved: it is off at every launch.
    private let platformTestSwitch = PlatformTestSwitch()
    var platformTestEnabled: Bool {
        get { platformTestSwitch.isOn }
        set { platformTestSwitch.isOn = newValue }
    }
    /// The probes. Made when first used (it needs the journal): a copy that only hands off and quits never makes one, and so
    /// never opens the running copy's journal.
    var probes: ProbeRunner {
        if let probeRunner { return probeRunner }
        let runner = ProbeRunner(
            paths: paths, reader: MenuBarReader(ax: AXClient(), runningApps: { [runningApps] in runningApps.regular }),
            plist: plist, grants: grants, layoutProvider: { [layoutSource] in layoutSource.current },
            platform: .live(runningApps: runningApps), stateChangingAllowed: { [platformTestSwitch] in platformTestSwitch.isOn },
            resetUnderWay: { [resetActivity] in resetActivity.isUnderWay })
        probeRunner = runner
        return runner
    }
    private var probeRunner: ProbeRunner?
    /// Set while a reset of the menu bar is under way: the probes that change the menu bar are refused meanwhile, and a reset is refused
    /// while one of them is changing it (`resetRefusal`).
    private let resetActivity = ResetActivity()
    /// Set when quitting begins: no probe is started after it.
    private var isQuitting = false
    /// How long quitting may take: a second, or three while what Mantel changed in the system is being put back.
    let quitTimer = QuitTimer()
    /// Whether this copy has been through the launch's replay, which is what makes the journal its own: a copy that handed off to
    /// the running one never opens the journal, and never replays it when it quits.
    private var ownsJournal = false
    /// The displays, readable from anywhere: the probes ask for them off the main actor.
    private let layoutSource = DisplayLayoutSource()
    /// What the app delegate saw when it handed off to another Mantel and decided to start all the same, if it did. Nil for a
    /// copy that found nobody to hand off to: it hands off here, if the control socket turns out to be held. A hand-off is
    /// made once, by whichever of the two comes first.
    private let earlierHandOff: HandOffFacts?
    /// Why the control socket isn't started, when it isn't: said in the log as soon as the log has its file.
    private var controlSocketProblem: String?
    /// The general settings the panes draw (a change redraws them). `generalSettings` is what the file holds.
    let settingsModel = GeneralSettingsModel()
    private(set) var generalSettings: GeneralSettings {
        get { settingsModel.settings }
        set { settingsModel.set(newValue) }
    }
    /// The shortcut each action has, as loaded and as changed in Settings › Hotkeys.
    private(set) var hotkeyBindings = HotkeyBindings()
    /// The actions whose shortcut macOS wouldn't register, and why. Empty while the hotkeys are suspended.
    private(set) var hotkeyFailures: [HotkeyID: HotkeyRegistrationError] = [:]

    private lazy var router = makeRouter()
    private var controlServer: ControlSocketServer?
    /// The dots and what hides and reveals. Made at the launch's step for the dots, after the settings are loaded, and started two steps on.
    /// It is kept in a slot that is observable, so that Settings' panes draw again when it arrives.
    let menuBarSlot = MenuBarSlot()
    private(set) var menuBar: MenuBarController? {
        get { menuBarSlot.controller }
        set { menuBarSlot.set(newValue) }
    }
    private var settingsWindow: SettingsWindowController?
    /// The Settings window, once it has been made.
    var settingsNSWindow: NSWindow? { settingsWindow?.window }
    private var onboardingWindow: OnboardingWindowController?
    private var screenObserver: (any NSObjectProtocol)?
    /// Made when the hotkeys are registered at launch, which is after the settings are loaded.
    private var hotkeyCenter: HotkeyCenter?
    /// Whether every hotkey is unregistered for the moment: while a shortcut is being recorded, a key that is already a
    /// hotkey would act instead of being heard.
    private var hotkeysSuspended = false
    private var isStarted = false
    /// Set once `generalSettings` and `hotkeyBindings` have been read from their files; before that nothing is saved.
    private var hasLoadedSettings = false
    /// The last save of a settings document. Each waits for the one before, so that they reach the store in order.
    private var lastSave: Task<Void, Never>?
    /// A request to open Settings that came before the settings were loaded (the socket is listening during the replay, and
    /// a second copy's hand-off can arrive then). Nil when there is none; the page inside is nil for "wherever it was".
    private var deferredSettingsRequest: SettingsRequest?

    private struct SettingsRequest {
        let page: SettingsPage?
    }

    init(paths: MantelPaths, activation: ActivationPolicyOwner, earlierHandOff: HandOffFacts? = nil) {
        self.paths = paths
        self.activation = activation
        self.earlierHandOff = earlierHandOff
        store = SettingsStore(paths: paths)
        grants = FileGrantStore(store: store)
        permissionChecker = LivePermissionChecker(grants: grants)
        layoutSource.set(DisplayLayout.current())
        // About Mantel and Settings… in the main menu an ordinary Mantel has.
        activation.openSettings = { [weak self] page in self?.openSettings(page) }
    }

    // MARK: Launch

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Task { await launch() }
    }

    private func launch() async {
        for step in LaunchSequence.beforeSocket {
            await perform(step)
        }

        // The socket comes before the journal replay: the lock on it is the single-instance lock, and the one check that
        // can't miss another running Mantel (LaunchServices may not list it). A copy that finds the socket held hands off
        // and quits here, and never replays: the replay would restore what the running copy has journaled for a change it
        // is in the middle of. Commands that arrive during the replay are safe: `Journal.record` refuses during one, and
        // the router records nothing.
        let socket = await startControlServer()
        for step in LaunchSequence.steps(after: socket) {
            await perform(step)
        }

        // What was asked for while the launch was under way.
        if hasLoadedSettings, let request = deferredSettingsRequest {
            deferredSettingsRequest = nil
            openSettings(request.page)
        }
    }

    private func perform(_ step: LaunchStep) async {
        switch step {
        case .createFolders:
            do {
                try paths.createDirectories()
            } catch {
                // Carries on: the dots and Settings still work, and the person can quit. Nothing is saved, and the socket can't start.
                Log.error("launch", "couldn't make Mantel's folders: \(error.localizedDescription)")
            }
        case .configureLog:
            Log.configure(sink: FileLogSink(directory: paths.logs))
            Log.info("launch", "Mantel \(Bundle.main.versionString) starting")
            // The socket was started before the log had its file. What a crash left at its path is evidence of it, so it is said here.
            if let problem = controlSocketProblem {
                Log.error("control", problem)
            } else if isControlSocketListening {
                if controlServer?.replacedLeftoverSocket == true {
                    Log.info("control", "replacing a control socket that was left behind")
                }
                Log.info("control", "listening on the control socket")
            }
        case .replayJournal:
            ownsJournal = true
            _ = await replayJournal()
        case .loadSettings:
            generalSettings = await store.load(GeneralSettings.self)
            hotkeyBindings = await store.load(HotkeyBindings.self)
            hasLoadedSettings = true
        case .registerHotkeys:
            hotkeyCenter = HotkeyCenter()
            registerHotkeys()
        case .createStatusItem:
            menuBar = MenuBarController(
                store: store, approvals: approvalsEngine, runningApps: runningApps, layout: { [layoutSource] in layoutSource.current },
                reveal: generalSettings.reveal, hiding: generalSettings.hiding,
                replayJournal: { [weak self] in await self?.replayJournal() },
                resetRefusal: { [weak self] in await self?.resetRefusal() }, resetActivity: resetActivity,
                openSettings: { [weak self] in self?.openSettings(nil) }, openDiagnostics: { [weak self] in self?.openSettings(.diagnostics) },
                activation: activation)
        case .observeDisplays:
            updateDisplays()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDisplays() }
            }
        case .startMenuBar:
            // Returns at once: the session starts on a task of its own, and the launch (onboarding next) doesn't wait for its reads.
            menuBar?.start()
        case .openOnboardingIfNeeded:
            if !generalSettings.onboardingCompleted {
                openOnboarding()
            }
        }
    }

    private func makeRouter() -> CommandRouter {
        CommandRouter(
            openSettings: { [weak self] page in self?.openSettings(page) },
            runProbe: { [weak self] name, options in await self?.runProbe(name, options: ProbeOptions(options)) },
            diagnostics: { [weak self] in
                guard let self else { return .null }
                return await DiagnosticsReport.json(for: self)
            },
            menuBar: { [weak self] in self?.menuBar })
    }

    /// Reads the displays again, for everything that needs them (the probes and the menu bar among it).
    private func updateDisplays() {
        let layout = DisplayLayout.current()
        layoutSource.set(layout)
        menuBar?.displaysChanged(layout)
    }

    /// Replays the journal: puts back what an earlier run changed and didn't put back. Gives up after 10 seconds (what is
    /// left stays in the journal for the next launch). Returns a sentence about how it went, for the Diagnostics pane.
    @discardableResult
    func replayJournal() async -> String {
        let restorer = PlistJournalRestorer(access: plist, grants: grants)
        switch await journal.replay(using: restorer, cap: .seconds(10)) {
        case .completed(let failures):
            if failures.isEmpty { return "Everything in the journal was put back." }
            // A journal that couldn't be read restores nothing, and its one failure says what to do.
            if await !journal.isUsable, let reason = failures.first?.message {
                Log.error("launch", "the journal couldn't be read, so nothing was put back")
                return reason
            }
            Log.warning("launch", "\(failures.count) journal entries weren't restored and stay in the journal")
            return failures.count == 1 ? "1 change couldn't be put back; it stays in the journal."
                : "\(failures.count) changes couldn't be put back; they stay in the journal."
        case .timedOut:
            Log.warning("launch", "journal replay took too long; continuing, leftovers stay for next launch")
            return "Putting the changes back took too long. What is left stays in the journal for the next launch."
        }
    }

    /// Why a reset of the menu bar can't be made now, if it can't: a platform test is changing it, and the reset's replay would put the test's
    /// records back in the middle of a measurement.
    private func resetRefusal() async -> String? {
        ReplayNowPolicy.resetRefusal(probeChangingMenuBar: await probeRunner?.isChangingMenuBar ?? false)
    }

    /// "Replay now" in Diagnostics: the same replay as at launch.
    func replayJournalNow() async -> String {
        await replayJournal()
    }

    /// Whether the journal has nothing to put back. One that couldn't be read isn't empty: its replay says why it can't be done.
    var journalIsEmpty: Bool {
        get async {
            guard await journal.isUsable else { return false }
            return await journal.records().isEmpty
        }
    }

    /// Whether a hiding method is holding journaled changes in place: the System Settings switches' engine does for as long as it keeps
    /// an app's icons hidden. ("Replay now" would put them back from under it.)
    var engineHoldsJournal: Bool {
        get async { await approvalsEngine.holdsJournalEntries }
    }

    /// Runs a probe, unless quitting has begun (nil then): from the control socket and from the Diagnostics pane.
    func runProbe(_ name: ProbeName, options: ProbeOptions) async -> ProbeReport? {
        guard !isQuitting else { return nil }
        return await probes.run(name, options: options)
    }

    /// Whether the control socket is up.
    var isControlSocketListening: Bool {
        controlServer != nil
    }

    /// Starts the control socket. When another Mantel holds it, this copy has handed off to it and is quitting.
    private func startControlServer() async -> SocketStartOutcome {
        // A copy the move to Applications started finds the one that moved still holding the socket for a moment, while it
        // quits, so it waits for it (5 s at most) instead of handing off to a copy that is about to be gone.
        var patience = SingleInstancePolicy.suppressesHandOff(environment: ProcessInfo.processInfo.environment) ? 50 : 0

        let router = router
        // A build signed with a team also has the system check each client against that team's certificate. (Reading how the app
        // is signed checks the whole of it, which takes a moment: not on the main actor.)
        let own = await Self.ownSigning()
        let inspector = CodeSigningInspector(requirement: PeerPolicy.requirement(for: own))
        let server = ControlSocketServer(path: paths.controlSocket, inspector: inspector, own: own) { command, _ in
            await router.handle(command)
        }
        while true {
            do throws(SocketError) {
                try server.start()
                controlServer = server
                return .listening
            } catch {
                guard error == .inUse else {
                    // Mantel works without it; only `mantel` can't reach it. Said when the log has its file.
                    controlSocketProblem = "the control socket isn't started: \(error)"
                    return .notStarted
                }
                if patience > 0 {
                    patience -= 1
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                return await handOffToHolder(of: server)
            }
        }
    }

    /// How the app is signed, read off the main actor.
    @concurrent
    private static func ownSigning() async -> OwnSigning {
        OwnSigningReader.current()
    }

    /// Another Mantel holds the socket's lock: asks it to open Settings and quits, unless it is gone by then. The asking is done
    /// once: when the app delegate has already asked (`earlierHandOff`), what it saw is what this decides with, and nobody is
    /// asked again. This copy has no log file yet, so what it says here is in the unified log only.
    private func handOffToHolder(of server: ControlSocketServer) async -> SocketStartOutcome {
        Log.warning("launch", "another Mantel holds the control socket")
        var facts: HandOffFacts
        if let earlierHandOff {
            facts = earlierHandOff
        } else {
            facts = await SingleInstance.handOff(socket: paths.controlSocket, to: SingleInstance.otherInstance())
        }
        // The holder may have quit while the hand-off ran. The lock is asked once more: if it is free, this copy takes it.
        do throws(SocketError) {
            try server.start()
            controlServer = server
            facts.socketLockStillHeld = false
        } catch {
            facts.socketLockStillHeld = (error == .inUse)
            if error != .inUse { controlSocketProblem = "the control socket isn't started: \(error)" }
        }
        switch HandOff.decide(facts) {
        case .quit:
            Log.info("launch", "handed off to the running Mantel; quitting")
            NSApp.terminate(nil)
            return .heldByAnotherMantel
        case .start:
            Log.info("launch", "the other Mantel is gone; carrying on")
            return controlServer == nil ? .notStarted : .listening
        }
    }

    // MARK: Quitting

    /// What has to be done before the app ends. The app answers the quit when this returns, or when `quitTimer` runs out (a second,
    /// or three once the journal's replay has begun), whichever comes first; what isn't done by then is done at the next launch.
    ///
    /// In this order:
    /// 1. Nothing new is started: no probe (the only command that changes the system) is run from now on, and the tap that holds clicks on
    ///    the clock is stopped for good (the states the session publishes from now on start nothing again).
    /// 2. What is waiting to be saved is written, before anything that can take long.
    /// 3. A probe that runs is cut short, and puts back what it changed.
    /// 4. The hiding method is taken down (`MenuBarController.tearDownForQuit`): the pointer monitors are removed, a takeover of the menu
    ///    bar ends, no more plans are delivered, and the engine in charge shows everything and puts back what it changed, waited for for
    ///    1.5 seconds at most. When the journal holds changes the timer is stretched first, so that the engine's undoing and the replay
    ///    after it have the three seconds and not the one.
    /// 5. If the journal still holds changes, they are put back, within what is left of the quit timer's wait (so that when the replay is
    ///    cut short, it is the replay that says so, and not the app that quits in the middle of it).
    /// 6. The socket stops, the hotkeys are let go, and the settings are written once more.
    func prepareToQuit() async {
        isQuitting = true
        menuBar?.stopClockClicks()
        await lastSave?.value
        await store.flush()
        await probeRunner?.shutDown()
        if ownsJournal, await !journal.records().isEmpty { await quitTimer.extend() }
        await menuBar?.tearDownForQuit()
        if ownsJournal, await !journal.records().isEmpty {
            await quitTimer.extend()
            let restorer = PlistJournalRestorer(access: plist, grants: grants)
            switch await journal.replay(using: restorer, cap: await quitTimer.remaining()) {
            case .completed(let failures):
                if !failures.isEmpty { Log.warning("quit", "\(failures.count) journal entries weren't put back and stay for the next launch") }
            case .timedOut:
                Log.warning("quit", "putting the journal back took too long; what is left stays for the next launch")
            }
        }
        controlServer?.stop()
        hotkeyCenter?.unregisterAll()
        await store.flush()
    }

    // MARK: Windows

    /// Shows Settings at `page`, or at the pane it was last on when `page` is nil, and brings the app forward. Asked before
    /// the launch has loaded the settings, it is done when it has.
    func openSettings(_ page: SettingsPage?) {
        // The window starts on the pane the settings file says it was last on, so it waits until the file has been read.
        guard hasLoadedSettings else {
            deferredSettingsRequest = SettingsRequest(page: page)
            return
        }
        let window = settingsWindow ?? SettingsWindowController(coordinator: self)
        settingsWindow = window
        window.show(pane: page.map(SettingsPane.init(page:)))
    }

    /// Mantel was opened again, with the Dock icon or from Finder: onboarding comes forward if it is open, and otherwise Settings opens
    /// (or comes forward).
    func reopen() {
        if isOnboardingOpen {
            openOnboarding()
        } else {
            openSettings(nil)
        }
    }

    /// The person gave Mantel a file in Settings › Permissions, or put back what a platform test left ("Replay now"): the menu bar asks again
    /// what it can use, and what is turned off in System Settings.
    func permissionsChanged() {
        menuBar?.permissionsChanged()
    }

    /// Settings was shown or put away: the menu bar is read every two seconds while it is open.
    func setSettingsOpen(_ open: Bool) {
        menuBar?.setSettingsOpen(open)
    }

    /// Shows onboarding from its first step. Open already, it only comes forward.
    func openOnboarding() {
        if let onboardingWindow, isOnboardingOpen {
            onboardingWindow.show()
            return
        }
        let window = OnboardingWindowController(activation: activation, finish: { [weak self] in self?.finishOnboarding() })
        onboardingWindow = window
        window.show()
    }

    private var isOnboardingOpen: Bool {
        onboardingWindow?.window?.isVisible == true
    }

    private func finishOnboarding() {
        updateGeneralSettings { $0.onboardingCompleted = true }
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: Settings

    /// The pane Settings was last on.
    var lastSettingsPane: SettingsPane {
        generalSettings.settingsPage.flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    func rememberSettingsPane(_ pane: SettingsPane) {
        updateGeneralSettings { $0.settingsPage = pane.rawValue }
    }

    /// Changes `generalSettings` and has the store save them, and passes what reveals and hides on to the menu bar. It is the one way a
    /// setting changes, for Settings' panes too. Before the file has been read nothing changes: saving the defaults over a file not yet
    /// read would lose it.
    func updateGeneralSettings(_ change: (inout GeneralSettings) -> Void) {
        guard hasLoadedSettings else { return }
        change(&generalSettings)
        enqueueSave(generalSettings)
        // What reveals and hides follows the settings: the menu bar passes on only what is different.
        menuBar?.settingsChanged(reveal: generalSettings.reveal, hiding: generalSettings.hiding)
    }

    /// Hands a settings document to the store after the saves that came before it.
    private func enqueueSave<Document: SettingsDocument>(_ document: Document) {
        let previous = lastSave
        lastSave = Task { [store] in
            await previous?.value
            await store.save(document)
        }
    }

    // MARK: Hotkeys

    /// Gives an action the shortcut `combo`, or none when it is nil: saved, and registered at once. What came of it is the
    /// outcome: saved; not saved, and why; or saved but not registered by macOS, and why (the shortcut is saved all the same:
    /// the other app may let go of it).
    ///
    /// A combo without a modifier (`KeyCombo.lacksModifier`) is never saved: it would take a key that is typed.
    func setHotkey(_ combo: KeyCombo?, for id: HotkeyID) -> HotkeySetOutcome {
        // Before the file has been read nothing changes, for the reason given at `updateGeneralSettings`.
        guard hasLoadedSettings else { return .notSaved("Mantel is still starting. Try again in a moment.") }
        if let combo, combo.withoutFunction.lacksModifier {
            return .notSaved(HotkeyClash.noModifier.message(actionTitle: HotkeyAction.title(for:)))
        }
        hotkeyBindings.bindings[id] = combo
        enqueueSave(hotkeyBindings)
        registerHotkeys()
        if let failure = hotkeyFailures[id] { return .savedButNotRegistered(failure) }
        return .saved
    }

    /// Unregisters every hotkey while a shortcut is being recorded, and registers them again when it is done.
    func setHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        registerHotkeys()
    }

    /// Makes the registered hotkeys what `hotkeyBindings` says: everything is unregistered, and each action with a shortcut
    /// is registered again, without Fn (which Carbon can't represent). Only the actions this version knows are registered;
    /// the rest of the file is kept as it is.
    private func registerHotkeys() {
        guard let center = hotkeyCenter else { return }
        center.unregisterAll()
        hotkeyFailures = [:]
        guard !hotkeysSuspended else { return }

        for action in HotkeyAction.all {
            guard let combo = hotkeyBindings.bindings[action.id]?.withoutFunction else { continue }
            guard !combo.lacksModifier else {
                // Only a file edited by hand can hold one: the pane doesn't save it.
                Log.warning("hotkeys", "\(action.id.rawValue) has a shortcut without ⌘, ⌃ or ⌥ and isn't registered")
                continue
            }
            do throws(HotkeyRegistrationError) {
                try center.register(action.id, combo) { [weak self] event in
                    self?.hotkeyFired(action.id, event)
                }
            } catch {
                hotkeyFailures[action.id] = error
                Log.warning("hotkeys", "\(action.id.rawValue) isn't registered: \(error)")
            }
        }
    }

    private func hotkeyFired(_ id: HotkeyID, _ event: HotkeyCenter.Event) {
        // Releases matter to push-to-talk, which comes later; opening Settings is done by the press alone.
        guard event == .pressed else { return }
        if id == .openSettings {
            openSettings(nil)
        } else {
            // The menu bar isn't made until the launch gets to it: a key pressed before that does nothing.
            menuBar?.hotkeyFired(id)
        }
    }
}
