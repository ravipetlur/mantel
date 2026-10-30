import AppKit
import MKCommands
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

/// What a change of state carries to what follows it: what asked for it, where the pointer was, and the stamp a correction is checked
/// against (`RevealApplyPolicy.isStale(stamp:)`).
private struct RevealContext {
    let cause: RevealCause
    let pointer: CGPoint
    let stamp: Int
}

/// What a change of state was applied as.
private struct AppliedLook: Equatable {
    let state: RevealState
    let presentation: RevealPresentation
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
/// - **Guards.** While a reveal is on the bar, every half second the controller says to the machine whether a menu is open, whether
///   the pointer is in a bar and whether one of Mantel's own panels is open; those hold the icons on the bar. A panel opening or closing
///   is told at once.
/// - **How a reveal is shown.** Before a change to a reveal is applied, it is asked how to show it (`RevealPresentationPolicy`), from the
///   setting, what asked for the reveal (`RevealCause`, noted when the event is sent) and, in "only when there's no room", whether the
///   icons are predicted to fit (`MenuBarSession.predictedFits`). A reveal shown in the second bar opens the bar at once and is applied as
///   the sections make the menu bar (`.secondBar`). A reveal shown on the bar whose follow-up finds icons without room is shown in the
///   second bar after all (`.openSecondBar`): the same state, applied again with the other presentation, by this controller (the apply
///   policy skips a state that was applied last, so it never sees the correction). The two are never applied at the same time
///   (`applyQueue`).
/// - **A correction is looked at again where it acts.** The change of state that asked for it carries a stamp (`RevealApplyPolicy`
///   counts the changes that pass their second look), and the correction opens the bar, on the main actor, only if no change has passed
///   since: otherwise a newer change has closed the bar or decided on another level, and the correction is dropped. It carries the cause
///   and the pointer of the change it corrects, too (`RevealContext`), since what was noted since is another's.
/// - **The takeover of the menu bar ends wherever the second bar opens.** Handing the menu bar back activates the app it was taken from,
///   which the bar is told is not the person leaving.
/// - **Closing.** A collapse closes the bar. The second bar closing for the person's own reason (Esc, a click outside it, the hotkey,
///   another app in front, a change of displays) collapses the reveal (`PanelMath.collapsesReveal`); a click on a dot closes it through
///   the machine's own transition, and an icon clicked in it collapses the reveal after the click is sent (`iconClickSent`).
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
    private var secondBarSettings: SecondBarSettings
    /// Mantel's panels, which a reveal may open and which hold it. Set once, by `MenuBarController`.
    private weak var panels: MantelPanels?
    /// What asked for the reveal that is under way, and where the pointer was then (AppKit's points): taken when the event is sent, since
    /// the change of state is delivered later, and a hover's comes from a timer.
    private var cause = RevealCause(trigger: .command)
    private var causePointer = CGPoint.zero
    /// Whether what asked for the reveal wants it in the second bar whatever the setting is (`mantel bar open`). Noted with the command, taken
    /// by the change of state it causes (`reveal`) and cleared when the command is done, so that it never outlives it.
    private var forcesSecondBar = false
    /// What the last change of state was put on the bar as, so that the second bar's correction doesn't apply it again.
    private var lastApplied: AppliedLook?
    /// Applying a reveal and applying it again in the second bar are never done together.
    private let applyQueue = AsyncSerialQueue()
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
         windows: any WindowListReading, takeover: MenuBarTakeover, settings: RevealSettings, secondBar: SecondBarSettings) {
        self.secondBarSettings = secondBar
        self.session = session
        self.sessionStart = sessionStart
        self.model = model
        self.classifier = classifier
        self.windows = windows
        self.takeover = takeover
        self.settings = settings
    }

    /// Where the panels are, for what a reveal opens and what holds it.
    func attach(_ panels: MantelPanels) {
        self.panels = panels
    }

    // MARK: Events

    /// Gives the reveal an event. Returns at once; events are handled in the order they were sent.
    ///
    /// - Parameter cause: what asked for it, when the event doesn't say (the hotkey for the second bar is a `.show` like any command's).
    func send(_ event: RevealEvent, cause: RevealCause? = nil) {
        // The pointer opens no panel while the command bar is open, so no reveal is applied for a bar that won't open.
        if let trigger = (cause ?? RevealCause.of(event))?.trigger, trigger == .hover || trigger == .scroll,
           !PanelMath.pointerOpensPanels(open: panels?.open ?? []) { return }
        note(event, cause: cause)
        let driver = driver, model = model
        events.enqueue { _ = await Self.give(event, to: driver, followedBy: model) }
    }

    /// Whether a ⌘-drag that begins now can show everything and put it away again: not when everything shows already (it is the person's
    /// reveal, and the drag has none of its own to put away) or in Focus Mode (showing leaves it).
    var commandDragMayShowAll: Bool {
        model.revealState != .allShown && model.revealState != .focusMode
    }

    /// A ⌘-drag began and the person has everything shown for it: shown on the menu bar itself and never in the second bar, whatever the
    /// setting is, and never taking the keyboard (`RevealPresentationPolicy`).
    func commandDragShowsAll() {
        send(.show(.all), cause: RevealCause(trigger: .commandDrag))
    }

    /// What the person has revealed now, as the machine has it.
    var revealLevel: RevealLevel { model.revealState.level }

    /// The order a ⌘-drag left has been followed: what the drag showed is put away, back to what it was when the drag began (the Hidden
    /// reveal the person had made with •, or collapsed). A reveal that is no longer the drag's (the person put it away or made another
    /// while the drop was followed, or the rehide did) is left as it is.
    func commandDragCollapses(to level: RevealLevel) {
        guard model.revealState == .allShown else { return }
        send(.show(level))
    }

    /// Takes what asked for a reveal, and where the pointer is, for the change of state that comes of it.
    private func note(_ event: RevealEvent, cause given: RevealCause?, forcingSecondBar: Bool = false) {
        guard let found = given ?? RevealCause.of(event) else { return }
        cause = found
        forcesSecondBar = forcingSecondBar
        causePointer = NSEvent.mouseLocation
    }

    /// `mantel bar`: opens the second bar now (for what is in Hidden, or with Always Hidden's too), closes it, or the other of the two.
    /// A command never takes the keyboard, so the bar opens without being key. Returns whether the bar is open once everything the
    /// change asked for is done.
    ///
    /// It is decided, and done, in one turn of the event queue, after what was sent before has been delivered: two commands (or a command
    /// and the hotkey) never both see a bar that is about to open as closed, and an event sent before this one is delivered as its own.
    func changeSecondBar(_ change: BarChange, all: Bool) async -> Bool {
        let driver = driver, model = model
        await events.run { [self] in
            await driver.settled()
            let isOpen = await panels?.secondBar.isOpen == true
            let opens = switch change {
            case .open: true
            case .close: false
            case .toggle: !isOpen
            }
            if opens {
                let event = RevealEvent.forShow(all ? .all : .hidden)
                await note(event, cause: nil, forcingSecondBar: true)
                let state = await Self.give(event, to: driver, followedBy: model)
                await driver.settled()
                await endForcing()
                // Hidden showing already on the bar: the machine has no change to make, so the bar is opened the way a reveal that didn't fit is.
                if await panels?.secondBar.isOpen != true, state == .hiddenShown || state == .allShown {
                    await applyInSecondBar(state, context: currentContext())
                }
            } else if isOpen {
                let event = RevealEvent.forShow(.nothing)
                await note(event, cause: nil)
                _ = await Self.give(event, to: driver, followedBy: model)
                await driver.settled()
                // A bar the machine had already left has no change to close it: it is closed here, so an open bar can always be closed.
                await panels?.secondBar.close(.revealEnded)
            }
        }
        // What follows a reveal goes on apart from the next change; a command is answered after it.
        await latestFollowUp?.value
        return panels?.secondBar.isOpen == true
    }

    /// The command that forced the second bar is done: no change after it is forced.
    private func endForcing() {
        forcesSecondBar = false
    }

    /// The hotkey for the second bar: it closes the bar if it is open, and otherwise opens it, at the pointer, whatever the setting is.
    func toggleSecondBar() {
        let hotkey = RevealCause(trigger: .secondBarHotkey)
        note(.show(.hidden), cause: hotkey)
        let pointer = causePointer
        let driver = driver, model = model
        events.enqueue { [weak self] in
            guard let self else { return }
            // What was sent before has been delivered, so a bar that is about to open is open.
            await driver.settled()
            let isOpen = await self.panels?.secondBar.isOpen == true
            switch PanelMath.secondBarHotkey(isOpen: isOpen, state: await driver.state) {
            case .close:
                // The bar closes itself, for a reason that collapses the reveal: it closes even when the machine has left the state it
                // showed (and a collapse the machine has nothing to change for would leave it open).
                await self.closeSecondBar(.hotkey)
            case .openForTheCurrentState:
                // Hidden showing already (on the bar, as macOS draws it): the machine has no change to make, so the bar is opened the way
                // a reveal that didn't fit is.
                await self.applyInSecondBar(.hiddenShown, context: self.currentContext(cause: hotkey, pointer: pointer))
            case .showHidden:
                _ = await Self.give(.show(.hidden), to: driver, followedBy: model)
            }
        }
    }

    /// Something closed one of Mantel's panels: the reveal goes with it when it was the second bar and the person closed it
    /// (`PanelMath.collapsesReveal`).
    func panelClosed(_ panel: MantelPanel, _ reason: PanelCloseReason) {
        if PanelMath.collapsesReveal(closed: panel, reason: reason) { send(.show(.off)) }
    }

    /// Where the reveal is: the stamp moves with every change of it (`RevealApplyPolicy.looks`).
    var stamp: Int { applyPolicy.looks }

    /// A click from a panel's cell was sent (the panel closed for it first): the reveal that showed the cell collapses, the icon's own
    /// reveal staying for as long as its click holds it. A newer reveal than the one at `stamp` (taken when the cell was clicked) stays.
    func iconClickSent(stamp: Int) {
        guard applyPolicy.collapsesAfterIconClick(stamp: stamp) else { return }
        send(.show(.off))
    }

    private func closeSecondBar(_ reason: PanelCloseReason) {
        panels?.secondBar.close(reason)
    }

    /// What a correction made now carries: the cause and pointer noted last (or given), and the stamp of the newest change.
    private func currentContext(cause: RevealCause? = nil, pointer: CGPoint? = nil) -> RevealContext {
        RevealContext(cause: cause ?? self.cause, pointer: pointer ?? causePointer, stamp: applyPolicy.looks)
    }

    /// A panel opened or closed: whether one is open is told to the machine at once.
    func panelsChanged() {
        sampleGuards()
        // A hover that is counting down when the command bar opens is over: the pointer opens no panel while it is open.
        if !PanelMath.pointerOpensPanels(open: panels?.open ?? []) { send(.pointerLeftEmptySpace) }
    }

    /// The person's second bar settings changed (when it opens, where).
    func secondBarSettingsChanged(_ new: SecondBarSettings) {
        secondBarSettings = new
    }

    /// Gives the reveal an event, and returns what it comes to: the state it is in after the event, once everything that was to be
    /// done for it (the plan applied, the revealed icons looked for) is finished.
    @discardableResult
    func perform(_ event: RevealEvent) async -> RevealState {
        note(event, cause: nil)
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
        // Whether the icons go in the second bar is decided before the change is applied (the prediction is made from what is known, and
        // reads nothing from the bar).
        let isRevealed = state.level != .off
        let (cause, pointer) = (self.cause, causePointer)
        // The command's force belongs to the change it caused: it is taken here, and no later change is forced by it.
        let forced = forcesSecondBar
        forcesSecondBar = false
        let chosen = isRevealed ? await howToShow(state, caused: cause, forced: forced) : .inline
        // A state the machine left while the session was starting isn't applied either. Nothing is done to the guard poll or the takeover
        // before this second look: a change that is skipped here must leave them as they are, and the one that replaces it sets them.
        guard applyPolicy.shouldApply(state, machineIsIn: await driver.state) else { return }
        // From here to the end of this turn nothing else runs on the main actor: the stamp is taken, and the bar opens or closes, in one.
        let context = RevealContext(cause: cause, pointer: pointer, stamp: applyPolicy.passedSecondLook())
        // A second bar that would list nothing would fill the dots and show nothing: the reveal is shown on the menu bar instead.
        let presentation = RevealPresentationPolicy.presentation(chosen, secondBarListsSomething: panels?.secondBar.wouldList(level: state.level) ?? false)

        // Hidden or everything is on the bar (Focus Mode and a collapse have nothing revealed).
        if isRevealed {
            startGuardPoll()
        } else {
            stopGuardPoll()
            takeover.end()
        }
        if presentation == .secondBar {
            // The bar opens at once; the plan it leaves the menu bar with is applied behind it.
            openSecondBar(for: state, context: context)
        } else {
            // A collapse, Focus Mode, or a reveal that is on the bar itself: the second bar has nothing to show.
            panels?.secondBar.close(.revealEnded)
        }
        let session = session
        lastApplied = AppliedLook(state: state, presentation: presentation)
        let applied = await applyQueue.run { await session.applyReveal(state, presentation: presentation) }
        // Nothing is left to do for a state that shows nothing, and for one the machine left during the apply: the follow-up of the
        // reveal before it is stale, and a command doesn't wait for it.
        guard applyPolicy.didApply(state, machineIsIn: await driver.state) else {
            latestFollowUp = nil
            return
        }
        // The plan is on the bar, and the next change can be applied. Looking for the reveal and for room for it is for a task of its own.
        latestFollowUp = Task { [weak self] in await self?.followUp(applied, in: state, context: context) }
    }

    /// How a reveal to this state is shown, for what asked for it. The room is predicted only where the answer is read: in "only when
    /// there's no room", for the triggers that follow the setting.
    private func howToShow(_ state: RevealState, caused cause: RevealCause, forced: Bool) async -> RevealPresentation {
        if forced { return .secondBar }
        let opens = secondBarSettings.opens
        var fits = true
        if opens == .whenNoRoom, cause.trigger != .secondBarHotkey, cause.trigger != .commandDrag {
            fits = await session.predictedFits(state)
        }
        return RevealPresentationPolicy.presentation(opens: opens, trigger: cause.trigger, predictedFits: fits)
    }

    /// Opens the second bar for a reveal of this state: under the slot of the dot that was clicked, at the pointer, or against the right
    /// edge, on the display the pointer was on, and with the keyboard when what asked for it means the person wants to use it. The
    /// takeover of the menu bar ends first, so the front app's menus are on the bar while the panel is open; the app that gets the focus
    /// back is not the person leaving, and the panel is told so.
    private func openSecondBar(for state: RevealState, context: RevealContext) {
        let expected = takeover.end()
        guard let panels, model.state != nil else { return }
        let displays = DisplayLayout.current()
        let display = (displays.display(containing: context.pointer) ?? displays.main)?.uuid
        let kind = RevealPresentationPolicy.anchor(trigger: context.cause.trigger, position: secondBarSettings.position)
        let anchor = PanelAnchorSpec.secondBar(kind, dot: context.cause.dot, pointer: displays.cgPoint(fromAppKit: context.pointer))
        panels.secondBar.open(level: state.level, anchor: anchor, display: display,
                              makeKey: RevealPresentationPolicy.makesKey(trigger: context.cause.trigger), ignoringActivationOf: expected)
    }

    /// A reveal that was applied on the bar and found icons without room is shown in the second bar: the bar opens and the state is
    /// applied again with that presentation. Nothing is done for a state the machine has left, for a bar that would list nothing, or when
    /// a change has passed since the correction was asked for (`RevealApplyPolicy.isStale`).
    private func applyInSecondBar(_ state: RevealState, context: RevealContext) async {
        let session = session
        await applyQueue.run { [self] in
            guard await driver.state == state, await openCorrection(for: state, context: context) else { return }
            guard await notesApplyingInSecondBar(state) else { return }
            _ = await session.applyReveal(state, presentation: .secondBar)
        }
    }

    /// Notes that the state is about to be applied as the second bar's, and says whether it is to be: a forced reveal has applied it that way
    /// already (even when the bar couldn't open, which applying again doesn't help), so only a state applied the other way is applied again.
    private func notesApplyingInSecondBar(_ state: RevealState) -> Bool {
        let look = AppliedLook(state: state, presentation: .secondBar)
        guard lastApplied != look else { return false }
        lastApplied = look
        return true
    }

    /// Opens the bar for a correction, in one turn of the main actor with the look at whether a change has overtaken it.
    private func openCorrection(for state: RevealState, context: RevealContext) -> Bool {
        guard !applyPolicy.isStale(stamp: context.stamp),
              RevealPresentationPolicy.presentation(.secondBar, secondBarListsSomething: panels?.secondBar.wouldList(level: state.level) ?? false) == .secondBar
        else { return false }
        openSecondBar(for: state, context: context)
        return true
    }

    /// The menu bar was reset (`MenuBarController.reset`): the session has collapsed its own reveal, so what was applied last is no longer
    /// on the bar. The next change is applied, whatever it is.
    func sessionWasReset() {
        applyPolicy.forget()
        lastApplied = nil
    }

    /// Looks for the reveal on the bar and for room for it, then does what is left about the icons that have none.
    private func followUp(_ applied: AppliedReveal, in state: RevealState, context: RevealContext) async {
        // A ⌘-drag's reveal makes no room: the person holds an icon with the mouse, and nothing may take over the menu bar, move the
        // reveal into the second bar or conceal Shown apps meanwhile. It is confirmed without looking at the bar.
        guard RevealPresentationPolicy.makesRoom(trigger: context.cause.trigger) else {
            guard await driver.state == state else { return }
            await driver.send(.revealConfirmed)
            return
        }
        let action = await session.followUp(applied)
        // The reveal is on the bar, or the session has looked for as long as it is going to. Another one may have taken its place.
        guard await driver.state == state else { return }
        await driver.send(.revealConfirmed)
        await handle(action, in: state, context: context)
    }

    /// What is left to do about icons that have no room. The session has dealt with everything but taking over the menu bar.
    private func handle(_ action: NoRoomAction, in state: RevealState, context: RevealContext) async {
        switch action {
        case .takeOverMenuBar:
            await takeOverMenuBar(for: state)
        case .leaveOverflow:
            // The session has said so in the log, now or earlier.
            overflowLogged = true
        case .openSecondBar:
            await applyInSecondBar(state, context: context)
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
        case .endedMeanwhile:
            // The takeover ended while Mantel was being brought forward (the second bar opened, the person went to another app, the reveal
            // was put away, or Mantel is quitting): the room isn't made this way.
            break
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
        let now = RehideGuards(menuOpen: WindowRules.isMenuOpen(list), pointerInBar: EmptySpace.isInBar(spot), panelOpen: panels?.isAnyOpen ?? false)
        guard now != lastGuards else { return }
        lastGuards = now
        send(.guardsChanged(now))
    }
}
