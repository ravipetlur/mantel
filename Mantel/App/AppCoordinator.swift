import AppKit
import ApplicationServices
import MKCommands
import MKCore
import MKLayout
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
///    on a task of its own: the launch doesn't wait for it), and 10. onboarding opens if the person hasn't been through it, and Settings
///    opens on Cosmetics if both dots are hidden (`LaunchSequence.opensSettingsForHiddenDots`).
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

    /// The one list of the apps that are running, kept up to date from the workspace: the menu bar reader reads it. The controller starts it.
    let runningApps = RunningAppsSource()
    /// Reads and changes the plist files the menu bar's state is kept in, with the journal behind every change.
    private(set) lazy var plist = PlistFileAccess(journal: journal, paths: paths, grants: grants, codecs: PlistBlobCodecs.standard)
    /// Reads and changes preferences (`defaults`: the icon spacing), with the journal behind every change. Made when first used, for the same
    /// reason as the journal it keeps its changes in.
    private(set) lazy var defaultsAccess = DefaultsAccess(journal: journal, preferences: LivePreferences())
    /// The one writer of `icons.json`: the Hotkeys page's changes and the Layout editor's go through it.
    let iconPreferencesWriter = IconPreferencesWriter()
    /// Reads and changes the icon spacing, which Settings › Advanced offers. Made when first used, with the journal its changes are kept in.
    private(set) lazy var spacingWriter = SpacingWriter(defaults: defaultsAccess, journal: journal)
    /// Asks the apps Settings › Advanced lists to quit and opens them again, when the person has ticked them.
    private(set) lazy var appRelauncher: any AppRelaunching = LiveAppRelauncher(runningApps: { [runningApps] in runningApps.all })
    /// What puts back the journal's entries, whatever kind of change they are: a plist file's (the layout table, the approvals file) or a
    /// preference's (the icon spacing). Every replay (the launch's, quitting's, Reset's, Replay now) uses this one.
    private(set) lazy var journalRestorer = RoutingJournalRestorer(plist: PlistJournalRestorer(access: plist, grants: grants),
                                                                   defaults: DefaultsJournalRestorer(access: defaultsAccess))
    /// The way of hiding icons that works through the "Allow in the Menu Bar" switches. Made when first used, for the same reason as the
    /// journal it keeps its changes in.
    private(set) lazy var approvalsEngine = ApprovalsEngine(access: plist, grants: grants, journal: journal)
    /// The Accessibility the scanner reads with, patient with a busy Mac (`PatientAX`). Held here so that quitting can tell it to stop waiting
    /// at the very start, from the quit itself and before anything that needs a thread of the pool (`beginQuit`).
    private let patientAX = PatientAX(inner: AXClient())
    /// What reads the menu bar, finds an item in it and presses it. The menu bar controller's session scans with it: what its scans learned of where each app's items are, while they were all drawn, is what
    /// lets it say which slot an item that was concealed has been drawn in.
    private(set) lazy var scanner = MenuBarScanner(
        ax: patientAX, runningApps: { [runningApps] in runningApps.regular }, layout: { [layoutSource] in layoutSource.current },
        ownBundleID: Bundle.main.bundleIdentifier ?? "com.example.mantel", isTrusted: { AXIsProcessTrusted() })
    /// How macOS keeps the menu bar's order table, from the platform check's results. Built once; the writer, the applier and the session
    /// all go by this value. (`LayoutRules.unmeasured` is what is assumed before anything was measured.)
    private let layoutRules = LayoutRules.measured
    /// Set while a reset of the menu bar is under way.
    private let resetActivity = ResetActivity()
    /// Set when quitting begins.
    private var isQuitting = false
    /// How long quitting may take: a second, or three while what Mantel changed in the system is being put back.
    let quitTimer = QuitTimer()
    /// Whether this copy has been through the launch's replay, which is what makes the journal its own: a copy that handed off to
    /// the running one never opens the journal, and never replays it when it quits.
    private var ownsJournal = false
    /// The displays, readable from anywhere.
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
    /// What the person told Mantel about individual icons (`icons.json`), as loaded: which icons have an action for their shortcut.
    private(set) var iconPreferences = IconPreferences()

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
    /// The updater: the daily check, the offer and its window, and the install. Nil unless the build names an update repository, and
    /// then there is no menu item, no Settings rows, no timer and no network. Made with the dots, which show its menu item.
    private(set) var updates: UpdateCenter?
    /// Holds the update's relaunch off for an open dialog and for an order change being written.
    private let relaunchGate = RelaunchGate()
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
            iconPreferences = await store.load(IconPreferences.self)
            hasLoadedSettings = true
        case .registerHotkeys:
            hotkeyCenter = HotkeyCenter()
            registerHotkeys()
        case .createStatusItem:
            updates = makeUpdates()
            menuBar = MenuBarController(
                store: store, approvals: approvalsEngine, runningApps: runningApps, scanner: scanner,
                layout: { [layoutSource] in layoutSource.current },
                reveal: generalSettings.reveal, hiding: generalSettings.hiding,
                dots: generalSettings.dots, secondBar: generalSettings.secondBar, ownImages: paths.ownImages, itemImagesFolder: paths.itemImages,
                replayJournal: { [weak self] in await self?.replayJournal() },
                resetActivity: resetActivity,
                layoutRules: layoutRules, layout: generalSettings.layout, plist: plist, grants: grants, journal: journal,
                home: FileManager.default.homeDirectoryForCurrentUser,
                openSettings: { [weak self] in self?.openSettings(nil) }, openDiagnostics: { [weak self] in self?.openSettings(.diagnostics) },
                updates: updates.map(dotsUpdates), activation: activation,
                recordsChecked: { [weak self] app, done in await self?.moveRecordSettings(ofApp: app, done) ?? SettingsMoved() })
            menuBar?.openSettingsPage = { [weak self] page in self?.openSettings(page) }
            menuBar?.iconPreferencesWriter = iconPreferencesWriter
            relaunchGate.layoutWriteIsUnderWay = { [weak self] in await self?.menuBar?.layoutWriteIsUnderWay() ?? false }
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
            // The first check comes five minutes after launch, once launch has settled.
            updates?.start()
        case .openOnboardingIfNeeded:
            if !generalSettings.onboardingCompleted {
                openOnboarding()
            }
            // With both dots off the bar nothing of Mantel is there to be found: Settings opens on the page that turns them back on.
            if LaunchSequence.opensSettingsForHiddenDots(onboardingCompleted: generalSettings.onboardingCompleted,
                                                         dots: generalSettings.dots) {
                openSettings(.cosmetics)
            }
        }
    }

    /// The updater, when the build names a repository to check (`UpdateConfiguration`); nil otherwise.
    private func makeUpdates() -> UpdateCenter? {
        guard let configuration = UpdateConfiguration.current() else { return nil }
        let gate = relaunchGate
        // The install's relaunch waits for a dialog that is open, and for an order change that is being written.
        let installer = LiveUpdateInstaller(configuration: configuration, waitUntilQuiet: { [gate] in await gate.waitUntilQuiet() })
        let center = UpdateCenter(
            configuration: configuration, store: store, automaticChecks: { [weak self] in self?.generalSettings.checkForUpdatesAutomatically ?? true },
            activation: activation, gate: gate, installer: installer)
        // A check from Settings answers in its About pane, but only while that pane is showing.
        center.aboutPaneIsShowing = { [weak self] in self?.settingsWindow?.isShowingAbout ?? false }
        return center
    }

    /// What the dots' menu says and does for the update item. A check from the menu that has no dot to answer under opens Settings on About.
    private func dotsUpdates(_ center: UpdateCenter) -> DotsController.Updates {
        DotsController.Updates(
            title: { center.menuTitle },
            chosen: { [weak self] anchor in center.menuItemChosen(anchor: anchor, showAbout: { self?.openSettings(.about) }) })
    }

    private func makeRouter() -> CommandRouter {
        CommandRouter(
            openSettings: { [weak self] page in self?.openSettings(page) },
            diagnostics: { [weak self] in
                guard let self else { return .null }
                return await DiagnosticsReport.json(for: self)
            },
            menuBar: { [weak self] in self?.menuBar })
    }

    /// Reads the displays again, for everything that needs them (the menu bar among it).
    private func updateDisplays() {
        let layout = DisplayLayout.current()
        layoutSource.set(layout)
        menuBar?.displaysChanged(layout)
    }

    /// Replays the journal: puts back the temporary changes an earlier run made and didn't put back (what Mantel keeps, its own
    /// arrangement, stays: only Restore original layout puts that back). Gives up after 10 seconds (what is left stays in the journal
    /// for the next launch). Returns a sentence about how it went, for the Diagnostics pane.
    @discardableResult
    func replayJournal() async -> String {
        switch await journal.replay(using: journalRestorer, cap: .seconds(10)) {
        case .completed(let failures):
            if failures.isEmpty { return "All of Mantel's temporary changes were put back." }
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

    /// "Replay now" in Diagnostics: the same replay as at launch.
    func replayJournalNow() async -> String {
        await replayJournal()
    }

    /// Whether the journal has nothing to put back: no temporary change is waiting. What Mantel keeps isn't waiting for anything. One
    /// that couldn't be read isn't empty: its replay says why it can't be done.
    var journalIsEmpty: Bool {
        get async {
            guard await journal.isUsable else { return false }
            return await journal.untilQuitRecords().isEmpty
        }
    }

    /// Whether a hiding method is holding journaled changes in place: the System Settings switches' engine does for as long as it keeps
    /// an app's icons hidden. ("Replay now" would put them back from under it.)
    var engineHoldsJournal: Bool {
        get async { await approvalsEngine.holdsJournalEntries }
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
            AppQuit.request()
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
    /// 1. Nothing new is started: the tap that holds clicks on
    ///    the clock is stopped for good (the states the session publishes from now on start nothing again).
    /// 2. What is waiting to be saved is written, before anything that can take long; so is an order change still in its debounce, in a
    ///    fraction of a second (it is dropped, and the log says so, when that isn't enough).
    /// 4. The hiding method is taken down (`MenuBarController.tearDownForQuit`): the pointer monitors are removed, a takeover of the menu
    ///    bar ends, no more plans are delivered, and the engine in charge shows everything and puts back what it changed, waited for for
    ///    1.5 seconds at most. When the journal holds temporary changes the timer is stretched first, so that the engine's undoing and
    ///    the replay after it have the three seconds and not the one. (What Mantel keeps stays across a quit, and asks for no time.)
    /// 5. If the journal still holds temporary changes, they are put back, within what is left of the quit timer's wait less a margin
    ///    (so that when the replay is cut short, it is the replay that says so, and not the app that quits in the middle of it, and the
    ///    final steps have their time).
    /// 6. The socket stops, the hotkeys are let go, and the settings are written once more.
    func prepareToQuit() async {
        isQuitting = true
        menuBar?.stopClockClicks()
        let trace = quitTrace
        await trace.step("saving what waits to be saved") { await lastSave?.value }
        // The settings of the icons that a check of the saved layout took out are moved on a task of the session's, and a move that hasn't been
        // made when the settings are written is lost for good: the app was checked, and isn't checked again.
        // A move can change a shortcut, which is a save of its own, so what waits to be saved is awaited again after the moves, and the step
        // has a bound: it comes out of the quit timer's first second.
        await trace.step("finishing the moves of the settings of icons that were checked") {
            await menuBar?.settingsMovesFinishedForQuit { [weak self] in await self?.lastSave?.value }
        }
        await trace.step("flushing the settings") { await store.flush() }
        await trace.step("flushing the layout") { await menuBar?.flushLayoutForQuit() }
        if ownsJournal { await trace.step("stretching the quit for the journal's replay") { await quitTimer.extendForReplay(of: journal) } }
        await trace.step("taking down the engine") { await menuBar?.tearDownForQuit() }
        if ownsJournal, await !journal.untilQuitRecords().isEmpty {
            await trace.step("putting the journal back") {
                await quitTimer.extend()
                switch await journal.replay(using: journalRestorer, cap: await quitTimer.replayCap()) {
                case .completed(let failures):
                    if !failures.isEmpty { Log.warning("quit", "\(failures.count) journal entries weren't put back and stay for the next launch") }
                case .timedOut:
                    Log.warning("quit", "putting the journal back took too long; what is left stays for the next launch")
                }
            }
        }
        // On the main thread, and waited for for half a second at most: the one step that the quit timer can't get past.
        trace.quickStep("stopping the control socket") { controlServer?.stop() }
        trace.quickStep("letting go of the hotkeys") { hotkeyCenter?.unregisterAll() }
        await trace.step("the last flush of the settings") { await store.flush() }
    }

    /// What the log says of the quit (`QuitTrace`): set when it begins.
    private(set) var quitTrace = QuitTrace(write: { Log.info("quit", $0) })

    /// What the SIGTERM fallback's line says besides the last step reached: how many queries wait for an app, how long the oldest has, and
    /// the read gate's counts. Registered when the app starts, and not when the quit begins, so that a SIGTERM whose main thread never runs
    /// the quit has them too.
    func registerQuitDiagnostics(on trace: QuitTrace) {
        let scanner = scanner
        trace.setDiagnostics { [patientAX] in
            let activity = patientAX.activity()
            let queries = "\(activity.inFlight) Accessibility queries waiting, the oldest \(Int((activity.oldestAge * 1000).rounded())) ms"
            let gate = scanner.readGateCounts
            return "\(queries); the read gate: \(gate.running) running, \(gate.waiting) waiting"
        }
    }

    /// The very start of the quit, called by the app's delegate on the main thread before anything is awaited and before the cleanup's task
    /// is made: reads of the menu bar stop waiting for apps (`MenuBarScanner.stopWaiting`: switches that are turned over, which need no thread
    /// of the pool, and which no actor has to take a turn for), so that the threads they hold are back as soon as the call each is in ends, a
    /// scan that is under way doesn't sleep through its retries, and the cleanup and the timer that need the threads aren't held up. Then the
    /// log's account of the quit begins (`QuitTrace`).
    func beginQuit(_ trace: QuitTrace, because cause: String) {
        isQuitting = true
        scanner.stopWaiting()
        quitTrace = trace
        trace.begin(cause)
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
        window.show(page: page)
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

    /// The person gave Mantel a file in Settings › Permissions, or put back what an earlier run left ("Replay now"): the menu bar asks again
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

    /// The page Settings was last on.
    var lastSettingsPage: SettingsPage {
        generalSettings.settingsPage.flatMap(SettingsPage.init(rawValue:)) ?? .general
    }

    func rememberSettingsPage(_ page: SettingsPage) {
        updateGeneralSettings { $0.settingsPage = page.rawValue }
    }

    /// Changes `generalSettings` and has the store save them, and passes what reveals and hides on to the menu bar. It is the one way a
    /// setting changes, for Settings' panes too. Before the file has been read nothing changes: saving the defaults over a file not yet
    /// read would lose it.
    func updateGeneralSettings(_ change: (inout GeneralSettings) -> Void) {
        guard hasLoadedSettings else { return }
        change(&generalSettings)
        enqueueSave(generalSettings)
        // What reveals and hides follows the settings: the menu bar passes on only what is different.
        menuBar?.settingsChanged(reveal: generalSettings.reveal, hiding: generalSettings.hiding, dots: generalSettings.dots,
                                 layout: generalSettings.layout, secondBar: generalSettings.secondBar)
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
        guard hasLoadedSettings else { return .notSaved(Self.stillStarting) }
        if let combo, combo.withoutFunction.lacksModifier {
            return .notSaved(HotkeyClash.noModifier.message(actionTitle: HotkeyAction.title(for:)))
        }
        hotkeyBindings.bindings[id] = combo
        enqueueSave(hotkeyBindings)
        registerHotkeys()
        if let failure = hotkeyFailures[id] { return .savedButNotRegistered(failure) }
        return .saved
    }

    private static let stillStarting = "Mantel is still starting. Try again in a moment."

    /// Gives an icon a shortcut, or none when `combo` is nil, together with what it does: the action is written to `icons.json` and is
    /// registered with the shortcut at once, so that a shortcut is never saved that does nothing. The outcome is `setHotkey`'s.
    func setIconShortcut(_ combo: KeyCombo?, action: IconHotkeyAction, for item: ItemID) async -> HotkeySetOutcome {
        guard hasLoadedSettings else { return .notSaved(Self.stillStarting) }
        await writeIconPreferences { $0.hotkeyActions[item] = action }
        return setHotkey(combo, for: .icon(item))
    }

    /// Changes what an icon's shortcut does. The shortcut stays as it is.
    func setIconAction(_ action: IconHotkeyAction, for item: ItemID) async {
        guard hasLoadedSettings else { return }
        await writeIconPreferences { $0.hotkeyActions[item] = action }
    }

    /// Takes an icon's shortcut away, and with it what the shortcut did.
    func removeIconShortcut(for item: ItemID) async {
        guard hasLoadedSettings else { return }
        _ = setHotkey(nil, for: .icon(item))
        await writeIconPreferences { $0.hotkeyActions[item] = nil }
    }

    /// Gives several icons' shortcuts the action each is to do, in one write.
    func setIconActions(_ actions: [ItemID: IconHotkeyAction]) async {
        guard hasLoadedSettings, !actions.isEmpty else { return }
        await writeIconPreferences { preferences in
            for (item, action) in actions { preferences.hotkeyActions[item] = action }
        }
    }

    /// A check of an app's saved icons took records out: the settings of the icons they were (a shortcut, the names it is found by, what the
    /// shortcut does) go to the app's one icon when it has exactly one and none of that kind, and stay under the old ID otherwise
    /// (`IconSettingsMover`). The settings kept under a name of Mantel's own that the version 1 file's migration took out of the layout are
    /// among them. Returns what was moved and what was left.
    func moveRecordSettings(ofApp bundleID: String, _ done: SectionModel.Reconciled) async -> SettingsMoved {
        guard hasLoadedSettings else { return SettingsMoved() }
        var bindings = hotkeyBindings
        var preferences = iconPreferences
        let ownNamed = IconSettingsMover.ownNamedRecords(ofApp: bundleID, preferences: preferences, bindings: bindings)
        let dropped = done.dropped + ownNamed.filter { !done.dropped.contains($0) }
        guard !dropped.isEmpty else { return SettingsMoved() }
        let current = done.kept + done.added
        let outcome = IconSettingsMover.move(dropped: dropped, current: current, preferences: &preferences, bindings: &bindings)
        guard !outcome.moved.isEmpty else { return outcome }
        if bindings != hotkeyBindings {
            hotkeyBindings = bindings
            enqueueSave(hotkeyBindings)
        }
        // The same moves on the file as it is when its turn comes; this registers the icons' shortcuts again.
        await writeIconPreferences { preferences in
            var unused = HotkeyBindings()
            _ = IconSettingsMover.move(dropped: dropped, current: current, preferences: &preferences, bindings: &unused)
        }
        return outcome
    }

    /// Changes `icons.json` as it is when its turn comes, through `iconPreferencesWriter` (the one writer of the file), and registers the
    /// icons' shortcuts again (`iconPreferencesChanged`), in the order of the writes.
    private func writeIconPreferences(_ change: @escaping @Sendable (inout IconPreferences) -> Void) async {
        _ = await iconPreferencesWriter.update(in: store, change, saved: { [weak self] in self?.iconPreferencesChanged($0) }).value
    }

    /// Unregisters every hotkey while a shortcut is being recorded, and registers them again when it is done.
    func setHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        registerHotkeys()
    }

    /// What the icons' shortcuts do changed (`icons.json` was written): the icons that have an action are registered, the others aren't.
    func iconPreferencesChanged(_ preferences: IconPreferences) {
        iconPreferences = preferences
        registerHotkeys()
    }

    /// Makes the registered hotkeys what `hotkeyBindings` says: everything is unregistered, and each action with a shortcut
    /// is registered again, without Fn (which Carbon can't represent), and so is each icon's that has something to do
    /// (`HotkeyRegistrationPlan`). Only the actions this version knows are registered; the rest of the file is kept as it is.
    private func registerHotkeys() {
        guard let center = hotkeyCenter else { return }
        center.unregisterAll()
        hotkeyFailures = [:]
        guard !hotkeysSuspended else { return }

        let combos = hotkeyBindings.bindings
        for id in HotkeyRegistrationPlan.iconBindingsWithoutAction(combos, preferences: iconPreferences) {
            Log.warning("hotkeys", "\(id.rawValue) has no action for its shortcut and isn't registered")
        }
        for (id, saved) in HotkeyRegistrationPlan.bindings(combos, actions: HotkeyAction.all, preferences: iconPreferences) {
            let combo = saved.withoutFunction
            guard !combo.lacksModifier else {
                // Only a file edited by hand can hold one: the pane doesn't save it.
                Log.warning("hotkeys", "\(id.rawValue) has a shortcut without ⌘, ⌃ or ⌥ and isn't registered")
                continue
            }
            do throws(HotkeyRegistrationError) {
                try center.register(id, combo) { [weak self] event in
                    self?.hotkeyFired(id, event)
                }
            } catch {
                hotkeyFailures[id] = error
                Log.warning("hotkeys", "\(id.rawValue) isn't registered: \(error)")
            }
        }
    }

    private func hotkeyFired(_ id: HotkeyID, _ event: HotkeyCenter.Event) {
        // Releases matter to push-to-talk, which comes later; opening Settings is done by the press alone.
        guard event == .pressed else { return }
        if id == .openSettings {
            openSettings(nil)
        } else if let item = id.iconItem {
            // What the shortcut does is read when it is pressed: it may have been changed since the shortcuts were registered.
            Task { [store] in
                if let action = await store.load(IconPreferences.self).hotkeyActions[item] { menuBar?.iconHotkeyFired(item, action) }
            }
        } else {
            // The menu bar isn't made until the launch gets to it: a key pressed before that does nothing.
            menuBar?.hotkeyFired(id)
        }
    }
}
