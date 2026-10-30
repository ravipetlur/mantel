import AppKit
import MKCore
import MKMenuBar
import MKUpdate
import Observation

/// Owns the updater: the daily schedule, the checks, the offer and its window, and the install. It exists only when the
/// build names an update repository (`UpdateConfiguration`), so in any other build there is nothing of it: no timer, no
/// request, no menu item, no Settings rows.
///
/// - **When it checks:** a daily check at the time `UpdateSchedule` gives, the first five minutes after launch, and one
///   after a wake from sleep if one is due. Every attempt is recorded as the last check, a failure included, so a failing
///   check doesn't repeat in a loop. A manual check (the menu, Settings) works any time.
/// - **A background check** never starts while a check, download or install runs or the update window is open, and fails
///   quietly, with a line in the log; an offer standing when it fails stays. It opens the window once per version per
///   launch, without taking the keys from the app the person is using.
/// - **A manual check** answers where it was asked (`CheckSource`), never in a floating HUD or a separate alert: from the
///   dots' menu a popover under the dot whose menu it came from (`CheckPopoverController`), or, with no dot to point at, Settings ›
///   About's line under Check Now; from Settings › About's Check Now that line (`aboutLine`). It says "Checking…", then
///   "up to date" or the failure in plain words (`CheckAnswer`). An update always opens the window, even one that was
///   skipped.
@MainActor
@Observable
final class UpdateCenter {
    /// Where the update is, from the check to the install. The menu, the window and Settings read it.
    private(set) var flow = InstallFlow()
    /// The running version.
    let currentVersion: VersionNumber
    /// The version installed on disk by an update that this process hasn't restarted into (the swap is done, and the app
    /// hasn't quit yet or couldn't relaunch). It counts as the current version for the rest of the process, so a later
    /// check doesn't offer what is already installed.
    @ObservationIgnored private var installedVersion: VersionNumber?
    /// The answer to a check asked from Settings › About, while the pane shows one: "Up to date", the failure or the update
    /// found (`aboutLine` adds "Checking…"). It is dropped when the pane closes or a new check starts, and never kept for
    /// a pane that isn't showing.
    private var aboutAnswer: CheckAnswer?
    /// Whether Return may install: the window has been key for a moment (`DefaultActionArming`, kept by the window
    /// controller). Until then Install and Relaunch works by click only.
    private(set) var defaultActionArmed = false
    /// Where the disk image of a hand-off is mounted, while the window says "Drag Mantel to Applications to finish".
    private(set) var handedOffVolume: URL?
    /// The new app is installed and the relaunch holds off for an open dialog (`RelaunchGate`): the window says
    /// `InstallFlow.restartWaitingText`, with Cancel still off.
    private(set) var restartIsWaiting = false

    /// What the updater remembers between launches (`update-state.json`): the last check and the version the person skipped. Read
    /// when the updater starts; the schedule waits for it.
    private(set) var state = UpdateState()
    @ObservationIgnored private let store: SettingsStore
    /// Whether "Check for updates automatically" is on (`GeneralSettings`), read when the schedule asks.
    @ObservationIgnored private let automaticChecks: () -> Bool
    @ObservationIgnored private let activation: ActivationPolicyOwner
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var lastSave: Task<Void, Never>?
    @ObservationIgnored private let client: ReleaseClient
    @ObservationIgnored private let installer: any UpdateInstaller
    /// When this launch began: the first check comes `UpdateSchedule.firstCheckDelay` after it.
    @ObservationIgnored private let launch = Date()
    @ObservationIgnored private var offers = OfferWindowPolicy()
    /// Waits for the next background check; replaced whenever the schedule may have changed.
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// The install that is running (or was last started), and its task. An install's reports and its end are tagged with
    /// its attempt, so those of an old one are never taken for the new one's.
    @ObservationIgnored private var installRun: (attempt: InstallAttempt, task: Task<Void, Never>)?
    /// Who the running check is for: nobody (the schedule fails quietly), or each surface a person asked from. A manual
    /// check that comes while another runs joins it, and every surface that asked gets the answer.
    @ObservationIgnored private var askers = CheckAskers()
    /// The popover under a dot, where a check from the dots' menu answers.
    @ObservationIgnored private let popover = CheckPopoverController()
    @ObservationIgnored private var windowController: UpdateWindowController?
    /// Why the last due background check had to wait, so the log says it once per reason and not at every retry.
    @ObservationIgnored private var saidWaiting: String?
    /// The offered release's notes cut into blocks, kept so the window doesn't cut them again at every progress tick.
    @ObservationIgnored private var cachedNotes: (markdown: String, blocks: [ReleaseNotes.Block])?

    /// How long after a wake the check waits, for the network to come back.
    private static let wakeSettleDelay: TimeInterval = 30
    /// How long a check that couldn't start (an update window is open, an install runs) waits to be tried again.
    private static let busyRetryDelay: TimeInterval = 10 * 60
    /// How long, after an install has asked the app to relaunch, before the app that is still running says so.
    private static let relaunchWait: Duration = .seconds(15)

    /// Whether Settings is open on its About pane, which is where a check from Settings answers. The Settings window's, set by
    /// the coordinator; until then (and in a build without one) no pane shows an answer.
    @ObservationIgnored var aboutPaneIsShowing: () -> Bool = { false }

    init(configuration: UpdateConfiguration, store: SettingsStore, automaticChecks: @escaping () -> Bool,
         activation: ActivationPolicyOwner, gate: RelaunchGate, installer: any UpdateInstaller) {
        self.currentVersion = configuration.currentVersion
        self.store = store
        self.automaticChecks = automaticChecks
        self.activation = activation
        self.installer = installer
        self.client = ReleaseClient(endpoint: configuration.endpoint, userAgent: configuration.userAgent,
                                    repository: configuration.repository)
        // The gate keeps the closure for good, so it captures the center weakly.
        gate.dialogWaitChanged = { [weak self] waiting in self?.restartIsWaiting = waiting }
    }

    // MARK: Starting

    /// Starts the schedule, and listens for the Mac waking from sleep.
    func start() {
        Log.update.info("Updates on, running \(currentVersion)")
        // Whatever an earlier install left in the temporary folder, once it is old enough to be nobody's, and the hidden
        // staged copies a crash left beside the app (no install of this process can be using one yet).
        let app = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            UpdateWorkFolder.sweepStagedCopies(besides: app)
            await UpdateWorkFolder.sweepLeftovers()
        }
        loading = Task { [weak self, store] in
            let loaded = await store.load(UpdateState.self)
            self?.state = loaded
            self?.arm()
        }
        // The notification center keeps the observers for good, so they capture the center weakly.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    /// The wait is dropped for the sleep. `Task.sleep(for:)` counts through sleep (it runs on the continuous clock), so
    /// a wait that ran on would end the moment the Mac wakes, before the network is back and without the settle delay
    /// (and a dark wake would check too); `systemDidWake` makes the wait again.
    private func systemWillSleep() {
        timer?.cancel()
        timer = nil
        Log.update.info("The Mac is going to sleep: the wait for the next check is dropped")
    }

    /// One check per wake at most: the schedule is asked again, which says a check is due or not, and a due one waits a
    /// moment for the network. A second wake before then replaces the wait rather than adding a check.
    private func systemDidWake() {
        arm(minimumDelay: Self.wakeSettleDelay)
    }

    /// Settings' "Check for updates automatically" changed.
    func automaticChecksChanged() {
        arm()
    }

    // MARK: What the menu and Settings show

    /// The offered release while one stands, through a re-check or a failed install, else nil.
    var offer: ReleaseInfo? { flow.release }

    /// A check, a manual or a background one, is running.
    var isChecking: Bool { flow.state == .checking }

    /// The offered release can be installed now: it is on offer, with nothing running.
    var canInstall: Bool {
        if case .available = flow.state { true } else { false }
    }

    /// "Update to 1.2.0…" while a release is known, else "Check for Updates…".
    var menuTitle: String {
        if let offer { DotsCopy.updateItem(to: offer.version.description) } else { DotsCopy.checkForUpdatesItem }
    }

    /// The last check, as Settings › About shows it.
    var lastCheck: Date? { state.lastCheck }

    /// The line under Check Now in Settings › About: "Checking…" while any check runs (the schedule's too, which is why the
    /// button is off), else the answer to the last check asked from there; nil when there is none.
    var aboutLine: CheckAnswer? {
        isChecking ? CheckAnswer(.checking, source: .settings) : aboutAnswer
    }

    /// The dots' menu's item: the update window when a release is known ("Update to X…"), else a manual check, which
    /// answers in a popover hanging from `anchor` (the button of the dot whose menu it came from). `anchor` is nil when the dot
    /// can't be pointed at (off the bar, in the menu bar's overflow, or the menu came from its shortcut): the check then answers
    /// in Settings › About, which `showAbout` opens, and never in a floating message.
    func menuItemChosen(anchor: NSView?, showAbout: () -> Void) {
        if offer != nil {
            showWindow(activating: true)
            return
        }
        switch CheckSource.dotsMenu.answering(anchorIsUsable: anchor != nil) {
        case .dotsMenu:
            // Open at once, saying "Checking for updates…", then ask.
            if let anchor { popover.show(below: anchor) }
            checkNow(from: .dotsMenu)
        case .settings:
            showAbout()
            checkNow(from: .settings)
        }
    }

    /// Settings › About's pane closed (another pane, or the window): the line under Check Now is cleared.
    func aboutPaneClosed() {
        aboutAnswer = nil
    }

    /// The offered release's notes as blocks for the window.
    func notesBlocks(for release: ReleaseInfo) -> [ReleaseNotes.Block] {
        if let cachedNotes, cachedNotes.markdown == release.notes { return cachedNotes.blocks }
        let blocks = ReleaseNotes.blocks(fromMarkdown: release.notes)
        cachedNotes = (release.notes, blocks)
        return blocks
    }

    // MARK: Scheduling

    /// Waits until the schedule says a check is due, `minimumDelay` at least, then checks. Replaces any wait there was.
    /// `logs` is false for the retry of a check that had to wait, which would otherwise log every ten minutes.
    private func arm(minimumDelay: TimeInterval = 0, logs: Bool = true) {
        timer?.cancel()
        timer = nil
        let now = Date()
        guard let next = nextCheck(now: now) else {
            Log.update.info("Automatic checks are off")
            return
        }
        let delay = max(next.timeIntervalSince(now), minimumDelay, 0)
        if logs { Log.update.info("The next background check is in \(Int(delay)) s") }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    /// When the next background check is due, nil with automatic checks off. A last check dated after now (the clock moved
    /// back) is first overwritten with now, which fixes the answer.
    private func nextCheck(now: Date) -> Date? {
        let stored = state.lastCheck
        let kept = UpdateSchedule.correctedLastCheck(stored: stored, now: now)
        if kept != stored {
            state.lastCheck = kept
            saveState()
            Log.update.info("The last check was dated in the future; it is now")
        }
        return UpdateSchedule.nextCheck(lastCheck: kept, launch: launch, now: now, automatic: automaticChecks())
    }

    private func timerFired() {
        timer = nil
        let now = Date()
        // The schedule is asked again: the setting or the clock may have changed while it waited.
        guard let next = nextCheck(now: now), next <= now else {
            arm()
            return
        }
        guard UpdateSchedule.backgroundCheckMayStart(state: flow.state, offerWindowOpen: isWindowOpen) else {
            // Said when the reason changes, not at every retry while the window sits open.
            let reason = isWindowOpen ? "the update window is open" : "a check, download or install is running"
            if saidWaiting != reason {
                saidWaiting = reason
                Log.update.info("A due background check waits: \(reason)")
            }
            arm(minimumDelay: Self.busyRetryDelay, logs: false)
            return
        }
        saidWaiting = nil
        check(askedFrom: nil)
    }

    // MARK: Checking

    /// A manual check, asked from `source`: Settings' Check Now, or the menu's "Check for Updates…". It asks even while an
    /// offer stands, so a newer release replaces the offer; the answer appears where it was asked, and a found update
    /// opens the window. While an install runs the window comes forward instead.
    func checkNow(from source: CheckSource) {
        switch flow.state {
        case .downloading, .verifying, .installing, .handedOff:
            showWindow(activating: true)
        case .checking:
            // A check is already asking (the schedule's, or another surface's): the person gets its answer too. Whatever an
            // earlier answer said no longer holds.
            askers.add(source)
            aboutAnswer = nil
            answer(.checking, to: source)
        default:
            check(askedFrom: source)
        }
    }

    /// Says `outcome` where `source` asked: the popover under the dot, or the line in Settings › About, which
    /// only takes it while the pane is showing (a person who has left it doesn't find an old answer on coming back).
    private func answer(_ outcome: CheckAnswer.Outcome, to source: CheckSource) {
        let answer = CheckAnswer(outcome, source: source)
        switch source {
        case .dotsMenu:
            popover.present(answer)
        case .settings:
            aboutAnswer = aboutPaneIsShowing() ? answer : nil
        }
    }

    /// A check that ended with no word to say (a result that came when no check was running) leaves no "Checking…" up.
    private func dropPendingAnswers() {
        popover.closeIfPending()
        if aboutAnswer?.isPending == true { aboutAnswer = nil }
    }

    /// Starts a check: for `source`, or for the schedule when it is nil.
    private func check(askedFrom source: CheckSource?) {
        // A check that can't start leaves nothing behind: a manual one's "Checking…" comes down, and the schedule is asked
        // again.
        guard checkTask == nil, apply(.checkStarted) else {
            dropPendingAnswers()
            arm(minimumDelay: Self.busyRetryDelay, logs: false)
            return
        }
        askers = CheckAskers()
        if let source { askers.add(source) }
        Log.update.info("Checking for updates (\(askers.logName))")
        // Whatever the last check said no longer holds, whoever asks now: an old "up to date" under an update window that
        // this check opens would contradict it.
        aboutAnswer = nil
        if let source { answer(.checking, to: source) }
        let client = client
        checkTask = Task { [weak self] in
            let result = await client.fetchLatest()
            self?.finishCheck(result)
        }
    }

    private func finishCheck(_ result: FeedResult) {
        checkTask = nil
        let askers = askers
        self.askers = CheckAskers()
        // Every attempt is recorded, a failed one too: a stale last check would put the next one in the past, and a check
        // that keeps failing would repeat in a loop.
        state.lastCheck = Date()
        saveState()

        switch result {
        case .failed(let failure):
            Log.update.warning("The check failed (\(askers.logName)): \(String(describing: failure))")
            // The offer that stood before the check stays; with none, the flow is idle again.
            if flow.settleAfterFailedCheck(failure) {
                for source in askers.sources { answer(.failed(failure), to: source) }
            } else {
                Log.update.debug("A failed check arrived when none was running")
            }
        case .noRelease:
            noUpdate(askers)
        case .release(let release):
            // A manual check ignores the skipped version: the person asked.
            let skipped = askers.isManual ? nil : state.skippedVersion.flatMap { VersionNumber($0) }
            if let offer = UpdateDecision.offer(current: effectiveVersion, latest: release, skipped: skipped) {
                found(offer, askers)
            } else {
                noUpdate(askers)
            }
        }
        // Whatever the branches left unanswered ends here.
        dropPendingAnswers()
        arm()
    }

    private func found(_ offer: ReleaseInfo, _ askers: CheckAskers) {
        guard apply(.updateFound(offer)) else { return }
        Log.update.info("Version \(offer.version) is available")
        // The popover closes (the update window says it better), and Settings' line says which version.
        for source in askers.sources { answer(.found(offer.version), to: source) }
        if offers.shouldShowWindow(for: offer.version, manual: askers.isManual) {
            // A background offer doesn't take the focus.
            showWindowIfOffered(activating: askers.isManual)
        }
    }

    private func noUpdate(_ askers: CheckAskers) {
        guard apply(.noUpdateFound) else { return }
        Log.update.info("No update: running \(currentVersion)" + (effectiveVersion == currentVersion ? "" : ", \(effectiveVersion) is installed"))
        // A window left open on an offer that has gone has nothing to show.
        closeWindow()
        for source in askers.sources { answer(.upToDate(effectiveVersion), to: source) }
    }

    // MARK: The window

    var isWindowOpen: Bool { windowController?.isOpen ?? false }

    /// Brings the update window forward on the release in play. `activating` is for what the person asked for (the menu, a
    /// manual check): the window is key and Mantel is active. A background offer (`false`) only orders the window in
    /// front, without the keys: whatever the person is typing in another app keeps going there.
    func showWindow(activating: Bool) {
        guard let release = flow.release else { return }
        // A cancel leaves the offer standing: the window shows the offer, not the cancel.
        if flow.state == .cancelled, !apply(.retry) { return }
        let controller = windowController ?? UpdateWindowController(center: self, activation: activation)
        windowController = controller
        controller.show(for: release, activating: activating)
    }

    /// The window for an offer that was found: it opens only while the release is still on offer.
    private func showWindowIfOffered(activating: Bool) {
        guard case .available = flow.state else { return }
        showWindow(activating: activating)
    }

    private func closeWindow() {
        windowController?.close()
    }

    /// The window controller's word on whether Return may install (`DefaultActionArming`).
    func setDefaultActionArmed(_ armed: Bool) {
        if defaultActionArmed != armed { defaultActionArmed = armed }
    }

    /// The window has closed (Later, Esc, the close button, or the center closing it). What the close leaves is settled: a
    /// failed or cancelled update goes back to being offered (unless the new version is already installed, which is
    /// nothing to offer), or to idle when no release is in play, and a hand-off is over. The schedule is asked again,
    /// since a check may have been waiting for the window to close.
    func windowDidClose() {
        switch flow.state {
        case .failed(let failure):
            if offer != nil, failure.canTryAgain {
                if !apply(.retry) { Log.update.debug("The offer couldn't be restored") }
            } else if !apply(.dismiss) {
                Log.update.debug("The failure couldn't be dismissed")
            }
        case .cancelled:
            if offer != nil {
                if !apply(.retry) { Log.update.debug("The offer couldn't be restored") }
            } else if !apply(.dismiss) {
                Log.update.debug("The cancel couldn't be dismissed")
            }
        case .handedOff:
            // The image stays mounted for the person to finish with; it is theirs now.
            handedOffVolume = nil
            if !apply(.dismiss) { Log.update.debug("The hand-off couldn't be dismissed") }
        default:
            break
        }
        arm()
    }

    // MARK: Choices in the window

    /// Later: closes the window. The menu keeps saying "Update to…", and the next launch offers it again.
    func later() {
        closeWindow()
    }

    /// Skip This Version: it isn't offered again by a background check, unless a newer one appears.
    func skipThisVersion() {
        guard case .available(let release) = flow.state, apply(.dismiss) else { return }
        state.skippedVersion = release.version.description
        saveState()
        Log.update.info("Skipped \(release.version)")
        // Settings' "Version X is available" no longer holds.
        aboutAnswer = nil
        closeWindow()
    }

    /// Try Again, after a failed install. Not after a failure that came with the new version already installed, or with
    /// the app missing from its folder: there is nothing for a new install to do (`UpdateFailure.canTryAgain`).
    func tryAgain() {
        guard case .failed(let failure) = flow.state, failure.canTryAgain, apply(.retry) else { return }
        installAndRelaunch()
    }

    /// Install and Relaunch: the installer takes it from here, and tells the flow how it goes.
    func installAndRelaunch() {
        guard case .available(let release) = flow.state, apply(.downloadStarted), let attempt = flow.attempt else { return }
        Log.update.info("Installing \(release.version)")
        handedOffVolume = nil
        let installer = installer
        // Every report carries the attempt, and the flow takes it only while this attempt is the one running.
        let report: InstallSteps.Report = { [weak self] event in
            await self?.report(event, from: attempt) ?? false
        }
        // The newest version installed here, so a backup of an earlier update isn't named after the old running version
        // and the new app only has to be newer than what is actually installed.
        let current = effectiveVersion
        let task = Task { [weak self] in
            let outcome = await installer.install(release: release, currentVersion: current, report: report)
            self?.installEnded(outcome, of: release, attempt: attempt)
        }
        installRun = (attempt, task)
    }

    /// What the install reports as it goes: true when the flow took it. One it turns down comes from an attempt that was
    /// cancelled or replaced, or was too late, and the installer stops there.
    private func report(_ event: InstallFlow.Event, from attempt: InstallAttempt) -> Bool {
        guard flow.handle(event, from: attempt) else { return false }
        if case .failure(let failure) = event {
            Log.update.warning("The install failed: \(String(describing: failure))")
            // A failure after the swap: the new version is on disk, whatever is running.
            if failure.newVersionIsInstalled, let release = flow.release { rememberInstalled(release.version) }
        }
        return true
    }

    /// The version a check compares with: the running one, or the one installed since, if that is newer.
    private var effectiveVersion: VersionNumber {
        UpdateDecision.currentVersion(running: currentVersion, installed: installedVersion)
    }

    private func rememberInstalled(_ version: VersionNumber) {
        installedVersion = UpdateDecision.currentVersion(running: version, installed: installedVersion)
        Log.update.info("\(version) is installed on disk; it counts as the current version until the app restarts")
    }

    /// The installer is done. The flow was told along the way, so this is for what the center itself does: say how it
    /// ended, keep the hand-off's volume, and wait to see the relaunch through.
    private func installEnded(_ outcome: InstallOutcome, of release: ReleaseInfo, attempt: InstallAttempt) {
        if installRun?.attempt == attempt { installRun = nil }
        switch outcome {
        case .installed(let backupNotRemoved):
            Log.update.info("The new version is installed" + (backupNotRemoved ? " (the old copy is beside it)" : "") + "; relaunching")
            rememberInstalled(release.version)
            watchRelaunch(of: attempt)
        case .handedOff(let volume):
            // Only while the hand-off is what the window says: the person may have closed it already.
            if case .handedOff = flow.state { handedOffVolume = volume }
            Log.update.info("The disk image is open for the person to finish the install")
        case .cancelled:
            Log.update.info("The install was cancelled")
        case .failed:
            break
        }
    }

    /// The relaunch quits this app. When it is still here after a while (the quit was held up, say, by an editor with
    /// unsaved changes), the window says the app was updated and that quitting finishes it: the relaunch helper is still
    /// waiting, and opens the app again when it quits.
    private func watchRelaunch(of attempt: InstallAttempt) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.relaunchWait)
            guard let self, flow.state == .installing else { return }
            Log.update.warning("The app is still running after the relaunch was asked for")
            _ = report(.failure(.quitPending), from: attempt)
        }
    }

    /// Cancel, while downloading or verifying: back to the offer.
    func cancelInstall() {
        guard flow.canCancel, apply(.cancel) else { return }
        installRun?.task.cancel()
        installRun = nil
        if !apply(.retry) { Log.update.debug("The offer couldn't be restored after the cancel") }
    }

    /// The app's quit has begun (`applicationShouldTerminate`, and the SIGTERM that starts one). A running install is cancelled
    /// at once, not when the process is about to end: the quit's cleanup takes a second or three, and an install that carries on
    /// meanwhile could swap, pass `RelaunchGate` (the quit's own flush has just ended the layout write) and start the relauncher,
    /// which opens the app again after the quit the person asked for. The relaunch's own quit isn't touched by this: by then the
    /// relauncher's shell has started, and the install has nothing left to skip. Past the swap nothing is undone: the new version
    /// is in place for the next launch.
    func quitBegan() {
        installRun?.task.cancel()
    }

    /// The app is quitting (`applicationWillTerminate`). An install that is still running is cancelled, and the disk image
    /// it mounted is ejected on the spot, which waits a few seconds at most. The eject doesn't depend on an install
    /// running: a Cancel just before the quit has dropped the run, while its own eject may not have finished. It does
    /// nothing when no image is recorded or mounted, and a hand-off's image (the person's) was never recorded.
    func prepareForQuit() {
        installRun?.task.cancel()
        installer.ejectMountedImageForQuit()
    }

    /// Shows the mounted disk image of a hand-off in Finder again.
    func showDiskImage() {
        guard case .handedOff = flow.state, let volume = handedOffVolume else { return }
        if !NSWorkspace.shared.open(volume) { Log.update.warning("The disk image couldn't be shown in Finder") }
    }

    // MARK: What is remembered

    /// Hands the state to the store, after the saves that came before it and after it was read: the store only writes a file it has
    /// read. The store writes it a moment later, and when the app quits.
    private func saveState() {
        let snapshot = state
        let previous = lastSave
        let loaded = loading
        lastSave = Task { [store] in
            await previous?.value
            await loaded?.value
            await store.save(snapshot)
        }
    }

    // MARK: The flow

    /// Applies `event`. True when the flow accepted it: whatever the event stands for is done only then, so a rejected
    /// event (a late result, a double click) never goes on to its side effect.
    private func apply(_ event: InstallFlow.Event) -> Bool {
        let accepted = flow.handle(event)
        if !accepted { Log.update.debug("The update flow ignored an event it didn't allow") }
        return accepted
    }
}
