import AppKit
import MKCommands
import MKCore
import MKMenuBar

/// Owns everything in Mantel that lives as long as the app does: the settings store, the journal, the permission checker,
/// the command router and the control socket, the • in the menu bar, and the Settings and onboarding windows.
///
/// `start()` runs the launch in the order `LaunchSequence` gives, and the order matters:
/// 1. Mantel's folders are made, and 2. the log is pointed at its file, so that everything after is kept.
/// 3. The control socket starts. Another Mantel holding it ends the launch here: this copy hands off and quits.
/// 4. The journal is replayed, and the replay finishes before anything can record into it. It is given 10 seconds: a restore
///    that hangs would otherwise keep the • and Settings from appearing, so after that the launch goes on, and what was not
///    restored stays in the journal for the next launch.
/// 5. Every settings document in use is loaded before any is saved: the store only protects a file it has read.
/// 6. The hotkeys are registered from the bindings that were loaded.
/// 7. The • appears, 8. the displays are watched, and 9. onboarding opens if the person hasn't been through it.
@MainActor
final class AppCoordinator {
    let paths: MantelPaths
    let store: SettingsStore
    /// Made when first used, which is the launch's replay, after the log has its file: what opening it logs is then kept.
    private(set) lazy var journal = Journal(file: paths.journalFile)
    let grants: FileGrantStore
    let permissionChecker: any PermissionChecking

    /// The displays as of launch or the last change to them.
    private(set) var displayLayout = DisplayLayout(displays: [])
    /// The journal entries the launch's replay couldn't restore; they stay in the journal.
    private(set) var replayFailures: [ReplayFailure] = []
    /// Reads and changes the plist files the menu bar's state is kept in, with the journal behind every change.
    private(set) lazy var plist = PlistFileAccess(journal: journal, paths: paths, grants: grants)
    /// The probes. Made when first used (it needs the journal): a copy that only hands off and quits never makes one, and so
    /// never opens the running copy's journal.
    var probes: ProbeRunner {
        if let probeRunner { return probeRunner }
        let runner = ProbeRunner(
            paths: paths, reader: MenuBarReader(ax: AXClient(), runningApps: { RunningApps.current() }), plist: plist,
            grants: grants, layoutProvider: { [layoutSource] in layoutSource.current }, platform: .live)
        probeRunner = runner
        return runner
    }
    private var probeRunner: ProbeRunner?
    /// Set when quitting begins: no probe is started after it.
    private var isQuitting = false
    /// The displays, readable from anywhere: the probes ask for them off the main actor.
    private let layoutSource = DisplayLayoutSource()
    private(set) var generalSettings = GeneralSettings()
    /// The shortcut each action has, as loaded and as changed in Settings › Hotkeys.
    private(set) var hotkeyBindings = HotkeyBindings()
    /// The actions whose shortcut macOS wouldn't register, and why. Empty while the hotkeys are suspended.
    private(set) var hotkeyFailures: [HotkeyID: HotkeyRegistrationError] = [:]

    private lazy var router = makeRouter()
    private var controlServer: ControlSocketServer?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
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

    init(paths: MantelPaths) {
        self.paths = paths
        store = SettingsStore(paths: paths)
        grants = FileGrantStore(store: store)
        permissionChecker = LivePermissionChecker(grants: grants)
        layoutSource.set(DisplayLayout.current())
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
                // Carries on: the • and Settings still work, and the person can quit. Nothing is saved, and the socket can't start.
                Log.error("launch", "couldn't make Mantel's folders: \(error.localizedDescription)")
            }
        case .configureLog:
            Log.configure(sink: FileLogSink(directory: paths.logs))
            Log.info("launch", "Mantel \(Bundle.main.versionString) starting")
        case .replayJournal:
            _ = await replayJournal()
        case .loadSettings:
            generalSettings = await store.load(GeneralSettings.self)
            hotkeyBindings = await store.load(HotkeyBindings.self)
            hasLoadedSettings = true
        case .registerHotkeys:
            hotkeyCenter = HotkeyCenter()
            registerHotkeys()
        case .createStatusItem:
            statusItem = StatusItemController(openSettings: { [weak self] in self?.openSettings(nil) },
                                              openDiagnostics: { [weak self] in self?.openSettings(.diagnostics) })
        case .observeDisplays:
            updateDisplays()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDisplays() }
            }
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
            })
    }

    /// Reads the displays again, for everything that needs them (the probes among it).
    private func updateDisplays() {
        displayLayout = DisplayLayout.current()
        layoutSource.set(displayLayout)
    }

    /// Replays the journal: puts back what an earlier run changed and didn't put back. Gives up after 10 seconds (what is
    /// left stays in the journal for the next launch). Returns a sentence about how it went, for the Diagnostics pane.
    @discardableResult
    func replayJournal() async -> String {
        let restorer = PlistJournalRestorer(access: plist, grants: grants)
        switch await journal.replay(using: restorer, cap: .seconds(10)) {
        case .completed(let failures):
            replayFailures = failures
            if failures.isEmpty { return "Everything in the journal was put back." }
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
        // A build signed with a team also has the system check each client against that team's certificate.
        let own = OwnSigningReader.current()
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
                    // Mantel works without it; only `mantel` can't reach it.
                    Log.error("control", "the control socket isn't started: \(error)")
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

    /// Another Mantel holds the socket's lock: asks it to open Settings and quits, unless it is gone by then.
    private func handOffToHolder(of server: ControlSocketServer) async -> SocketStartOutcome {
        Log.warning("launch", "another Mantel holds the control socket; handing off")
        var facts = await SingleInstance.handOff(socket: paths.controlSocket, to: SingleInstance.otherInstance())
        // The holder may have quit while the hand-off ran. The lock is asked once more: if it is free, this copy takes it.
        do throws(SocketError) {
            try server.start()
            controlServer = server
            facts.socketLockStillHeld = false
        } catch {
            facts.socketLockStillHeld = (error == .inUse)
            if error != .inUse { Log.error("control", "the control socket isn't started: \(error)") }
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

    /// What has to be done before the app ends: the socket stops (which removes its file) and what is waiting to be saved
    /// is written. The app gives it a second.
    func prepareToQuit() async {
        // First: nothing new is started, and a probe that runs puts back what it changed.
        isQuitting = true
        await probeRunner?.shutDown()
        controlServer?.stop()
        hotkeyCenter?.unregisterAll()
        await lastSave?.value
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

    /// Shows onboarding from its first step. Open already, it only comes forward.
    func openOnboarding() {
        if let onboardingWindow, onboardingWindow.window?.isVisible == true {
            onboardingWindow.show()
            return
        }
        let window = OnboardingWindowController(finish: { [weak self] in self?.finishOnboarding() })
        onboardingWindow = window
        window.show()
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

    /// Changes `generalSettings` and has the store save them. Before the file has been read nothing changes: saving the
    /// defaults over a file not yet read would lose it.
    private func updateGeneralSettings(_ change: (inout GeneralSettings) -> Void) {
        guard hasLoadedSettings else { return }
        change(&generalSettings)
        enqueueSave(generalSettings)
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

    /// Gives an action the shortcut `combo`, or none when it is nil: saved, and registered at once. Returns why macOS
    /// wouldn't register it, if it wouldn't (the shortcut is saved all the same: the other app may let go of it).
    ///
    /// A combo without a modifier (`KeyCombo.lacksModifier`) is never saved: it would take a key that is typed.
    @discardableResult
    func setHotkey(_ combo: KeyCombo?, for id: HotkeyID) -> HotkeyRegistrationError? {
        // Before the file has been read nothing changes, for the reason given at `updateGeneralSettings`.
        guard hasLoadedSettings else { return nil }
        if let combo, combo.withoutFunction.lacksModifier { return nil }
        hotkeyBindings.bindings[id] = combo
        enqueueSave(hotkeyBindings)
        registerHotkeys()
        return hotkeyFailures[id]
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
        }
    }
}
