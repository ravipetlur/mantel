import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// Whether the session has finished starting: what a reveal waits for. (`MenuBarSession.start` begins collapsed once it has loaded the
/// sections, so a reveal that was applied before that would be undone by it while the dots said it was on.)
final class SessionStart {
    /// The session's start, once it has begun; nil before.
    var task: Task<Void, Never>?

    /// Returns when the session has started: at once if it has, or if it hasn't begun to.
    func finished() async {
        await task?.value
    }
}

/// What the person's reveal does in the app: it owns the reveal machine's driver, takes events for it (the dots, the pointer, the
/// hotkeys and the commands), and carries out what the machine asks for by way of the session.
///
/// - **Events are sent in the order they come.** They go through a queue of their own, one at a time, and never from a task that is
///   cancelled. (`RevealDriver.send` returns at once; what it asks of this controller is delivered later, in order, by a task the
///   driver owns.)
/// - **The dots follow what was asked for at once.** After each event is sent, the machine's state is copied to `MenuBarModel`, so the
///   dots don't wait for the session.
/// - **A change of state is applied at once, in order.** The dots are drawn for the new state first (`MenuBarModel`), then the session
///   applies the plan (`session.applyReveal`), on the driver's one delivery task, so the plans reach the bar in the order they were
///   asked for and nothing waits for anything but the plan before it. A change the machine has already left (the person clicked
///   again while one was being applied) is not applied: the newest one is, and the session's own queue keeps only the latest plan.
///   Nor is a change to the state the bar already shows (`RevealApplyPolicy`). A change asked for while the session is still starting
///   waits for it to be done.
/// - **What follows a reveal is not on that path.** Looking for the revealed icons on the bar and for room for them takes seconds, so
///   it runs on a task of its own (`session.followUp`) while the next change is applied. A newer change makes an older follow-up stop,
///   by itself, where it is; no task that is making a call to the session is ever cancelled. When the follow-up is back, the reveal is
///   confirmed to the machine, and the takeover of the menu bar is made if one is still wanted. (Seeing a reveal on the bar is
///   advisory: the machine's rehide countdown doesn't wait for it.) A command waits for the follow-up (`perform`).
/// - **The state is looked at before acting on what is left to do.** A reveal that was hidden again while the session worked is a reveal
///   that is over: it has no takeover to make, and no follow-up is started for it. The look is at the state, not at a count of the
///   changes of state, so a reveal that was hidden and shown again while the session worked (hidden, collapsed, hidden) is the one it
///   was: the collapse isn't applied, and neither is the second reveal, which the bar already shows, so what the first one's
///   follow-up made (a swap) stays. A reveal that was left during its apply isn't remembered as applied: if the machine comes back to
///   it, it is applied again and followed up then. A reset forgets what was applied (`sessionWasReset`), so the next change is applied.
/// - **A skipped change touches nothing.** The guard poll and the takeover are changed only once a change has passed both looks at the
///   state, so a change that is skipped can't leave a revealed bar without its guard poll, or end a takeover the next change needs.
/// - **Guards.** While a reveal is on the bar, every half second the controller says to the machine whether a menu is open and whether
///   the pointer is in a bar; those hold the icons on the bar. (None of Mantel's own panels is one yet.)
final class RevealController {
    /// How often the guards are looked at while a reveal is on the bar.
    private static let guardInterval: Duration = .milliseconds(500)

    private let session: MenuBarSession
    private let model: MenuBarModel
    private let classifier: PointerClassifier
    private let windows: any WindowListReading
    private let takeover: MenuBarTakeover
    private let sessionStart: SessionStart
    private let events = AsyncSerialQueue()
    private var settings: RevealSettings
    private var guardPoll: Task<Void, Never>?
    private var lastGuards: RehideGuards?
    /// Whether the log has said, during this run, that the « menu keeps the revealed icons: the session says it when it decides that, and
    /// so does the takeover when it can't make room.
    private var overflowLogged = false

    /// The follow-up of the newest reveal that was applied: what a command waits for. The follow-ups of older ones aren't kept, and
    /// aren't waited for: they stop by themselves when they find they are overtaken.
    private var latestFollowUp: Task<Void, Never>?
    /// Which changes of state are applied, and which are followed up (`RevealApplyPolicy`).
    private var applyPolicy = RevealApplyPolicy()

    /// The rehide countdown starts with the reveal and doesn't wait for it to be seen on the bar (`RevealMachine.live`).
    private lazy var driver = RevealDriver(machine: .live(settings: settings), clock: SystemClock()) { [weak self] effect in
        await self?.deliver(effect)
    }

    init(session: MenuBarSession, sessionStart: SessionStart, model: MenuBarModel, classifier: PointerClassifier,
         windows: any WindowListReading, takeover: MenuBarTakeover, settings: RevealSettings) {
        self.session = session
        self.sessionStart = sessionStart
        self.model = model
        self.classifier = classifier
        self.windows = windows
        self.takeover = takeover
        self.settings = settings
    }

    // MARK: Events

    /// Gives the reveal an event. Returns at once; events are handled in the order they were sent.
    func send(_ event: RevealEvent) {
        let driver = driver, model = model
        events.enqueue { _ = await Self.give(event, to: driver, followedBy: model) }
    }

    /// Gives the reveal an event, and returns what it comes to: the state it is in after the event, once everything that was to be
    /// done for it (the plan applied, the revealed icons looked for) is finished.
    @discardableResult
    func perform(_ event: RevealEvent) async -> RevealState {
        let driver = driver, model = model
        let state = await events.run { await Self.give(event, to: driver, followedBy: model) }
        await driver.settled()
        // The plan is applied now. What follows a reveal goes on apart from the next change, and a command is answered after it.
        await latestFollowUp?.value
        return state
    }

    /// Sends the event, and shows the state the machine is in now (the dots follow what was asked for; the session catches up).
    private static func give(_ event: RevealEvent, to driver: RevealDriver, followedBy model: MenuBarModel) async -> RevealState {
        await driver.send(event)
        let state = await driver.state
        model.apply(reveal: state)
        return state
    }

    /// The settings of the reveal changed (the delays, which kinds of reveal are on).
    func settingsChanged(_ new: RevealSettings) {
        guard new != settings else { return }
        settings = new
        send(.settingsChanged(new))
    }

    // MARK: What the machine asks for

    private func deliver(_ effect: RevealEffect) async {
        switch effect {
        case .stateChanged(let state):
            await reveal(state)
        case .checkRoom:
            // Nothing to do: the follow-up of a reveal looks at the room as a part of it, and what it finds is handled there. (The machine
            // still says when a reveal begins: `RevealEffect.checkRoom`.)
            break
        case .startTimer, .cancelTimer:
            // The driver carries these out itself.
            break
        }
    }

    private func reveal(_ state: RevealState) async {
        // The machine's state, which may be a later one than this effect's: a state it has left isn't applied (the newest is, when its
        // effect comes), nor is the one the bar already shows. The dots never go back to a state that was already left.
        let current = await driver.state
        guard applyPolicy.shouldApply(state, machineIsIn: current) else { return }
        model.apply(reveal: current)

        await sessionStart.finished()
        // A state the machine left while the session was starting isn't applied either. Nothing is done to the guard poll or the takeover
        // before this second look: a change that is skipped here must leave them as they are, and the one that replaces it sets them.
        guard applyPolicy.shouldApply(state, machineIsIn: await driver.state) else { return }

        // Hidden or everything is on the bar (Focus Mode and a collapse have nothing revealed).
        let isRevealed = state.level != .off
        if isRevealed {
            startGuardPoll()
        } else {
            stopGuardPoll()
            takeover.end()
        }
        let applied = await session.applyReveal(state)
        // Nothing is left to do for a state that shows nothing, and for one the machine left during the apply: the follow-up of the
        // reveal before it is stale, and a command doesn't wait for it.
        guard applyPolicy.didApply(state, machineIsIn: await driver.state) else {
            latestFollowUp = nil
            return
        }
        // The plan is on the bar, and the next change can be applied. Looking for the reveal and for room for it is for a task of its own.
        latestFollowUp = Task { [weak self] in await self?.followUp(applied, in: state) }
    }

    /// The menu bar was reset (`MenuBarController.reset`): the session has collapsed its own reveal, so what was applied last is no longer
    /// on the bar. The next change is applied, whatever it is.
    func sessionWasReset() {
        applyPolicy.forget()
    }

    /// Looks for the reveal on the bar and for room for it, then does what is left about the icons that have none.
    private func followUp(_ applied: AppliedReveal, in state: RevealState) async {
        let action = await session.followUp(applied)
        // The reveal is on the bar, or the session has looked for as long as it is going to. Another one may have taken its place.
        guard await driver.state == state else { return }
        await driver.send(.revealConfirmed)
        await handle(action, in: state)
    }

    /// What is left to do about icons that have no room. The session has dealt with everything but taking over the menu bar.
    private func handle(_ action: NoRoomAction, in state: RevealState) async {
        switch action {
        case .takeOverMenuBar:
            await takeOverMenuBar(for: state)
        case .leaveOverflow:
            // The session has said so in the log, now or earlier.
            overflowLogged = true
        case .none, .swap, .giveUp:
            break
        }
    }

    private func takeOverMenuBar(for state: RevealState) async {
        guard await driver.state == state else { return }
        let list = windows.onScreenWindows()
        let bars = classifier.knownBars
        let shown = BarVisibility.shownBars(list, bars: bars)
        guard MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: Self.frontDisplay(), shownBars: shown, bars: bars) else {
            Log.info("reveal", MenuBarTakeoverPolicy.skippedLogLine)
            return
        }
        // Taken over already (by the reveal this one replaced), `begin` only says whether Mantel is the active app.
        let activated = await takeover.begin()
        switch MenuBarTakeoverPolicy.afterBegin(activated: activated, overflowAlreadyLogged: overflowLogged) {
        case .undo(let action):
            // Mantel never came to the front, so the menus of the app that was in front are still on the bar: nothing is made room for.
            // The focus goes nowhere (nothing was taken), and the icons stay in the « menu.
            takeover.end(reactivate: false)
            Log.info("reveal", MenuBarTakeoverPolicy.couldNotActivateLogLine)
            if case .leaveOverflow(logOnce: true) = action {
                Log.info("reveal", NoRoomResponse.overflowLogLine)
                overflowLogged = true
            }
        case .recheckRoom:
            // The reveal may have been hidden again while the menu bar was being taken over: there is nothing to make room for then, and the
            // hide that follows gives the menu bar back.
            guard await driver.state == state else { return }
            // The menus of the app that was in front are off the bar. What is left to do is decided as for any reveal, knowing that.
            if case .leaveOverflow = await session.recheckRoom(menuBarTakenOver: true) { overflowLogged = true }
        }
    }

    /// The display the person is working on: the screen of the key window. Nil when it can't be told which display that is.
    private static func frontDisplay() -> String? {
        guard let frame = NSScreen.main?.frame else { return nil }
        return DisplayLayout.current().displays.first { $0.frame == frame }?.uuid
    }

    // MARK: Guards

    private func startGuardPoll() {
        guard guardPoll == nil else { return }
        // The machine may have been told of guards that no longer hold, in an earlier reveal: this one begins with a look.
        lastGuards = nil
        guardPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleGuards()
                do { try await SystemClock().sleep(for: Self.guardInterval) } catch { return }
            }
        }
    }

    private func stopGuardPoll() {
        guardPoll?.cancel()
        guardPoll = nil
    }

    private func sampleGuards() {
        let list = windows.onScreenWindows()
        let spot = classifier.spot(atAppKit: NSEvent.mouseLocation, windowsJustRead: list)
        let now = RehideGuards(menuOpen: WindowRules.isMenuOpen(list), pointerInBar: EmptySpace.isInBar(spot), panelOpen: false)
        guard now != lastGuards else { return }
        lastGuards = now
        send(.guardsChanged(now))
    }
}
