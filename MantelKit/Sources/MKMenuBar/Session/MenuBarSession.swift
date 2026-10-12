import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout

/// What the menu bar is like, and what Mantel makes of it: the whole picture the dots and Settings draw from.
public struct MenuBarState: Sendable, Equatable {
    /// The last read of the menu bar.
    public let inventory: Inventory
    /// Where the person has put every app and system item.
    public let sections: SectionModel
    /// The lists that explain what can't be changed.
    public let lists: ReadOnlyLists
    /// What the bar is asked to show now.
    public let plan: VisibilityPlan
    /// How icons are hidden, and why.
    public let engine: EngineStatus
    /// Whether anything that is running is in Always Hidden: the •• dot is shown only then.
    public let alwaysHiddenHasApps: Bool

    public init(inventory: Inventory, sections: SectionModel, lists: ReadOnlyLists, plan: VisibilityPlan, engine: EngineStatus,
                alwaysHiddenHasApps: Bool) {
        self.inventory = inventory
        self.sections = sections
        self.lists = lists
        self.plan = plan
        self.engine = engine
        self.alwaysHiddenHasApps = alwaysHiddenHasApps
    }
}

/// A reveal whose plan the engines have applied, and which has yet to be followed up (`MenuBarSession.followUp`).
public struct AppliedReveal: Sendable, Equatable {
    /// The state that was applied.
    public let state: RevealState
    /// The number of changes of reveal the session had made when this one was applied. A later change makes this one stale.
    let generation: Int

    init(state: RevealState, generation: Int) {
        self.state = state
        self.generation = generation
    }
}

/// Turns what happens (apps start and quit, displays change, the person reveals, a menu bar is read) into a plan for the menu bar, and
/// has the engine in charge apply it. The app only forwards events here and draws `states()`.
///
/// - **One plan at a time reaches the engine, and the latest one wins.** While an engine is applying a plan (a switch's change to the
///   preferences service that disagrees costs seconds), newer plans don't queue up behind it: only the newest is kept, and it is
///   applied when the one under way returns.
/// - **The menu bar is read through `ScanScheduler` only**, so reads come one at a time, those that are asked for together are one
///   read, and a read that is asked for after a change is never answered with one that began before it. Every read, whoever asked for
///   it, goes through the same steps (`ingest`). The one exception is the look at the bar that confirms a reveal
///   (`MenuBarScanner.lookAtBar`): it reads one window of MenuBarAgent's, learns nothing, and is asked for directly.
/// - **A read says nothing of apps that did not answer** (`Inventory.unansweredApps`), and an app that is missing from it is not one
///   that has quit: only the list of running apps says that.
/// - **A reveal starts collapsed.** What an earlier run was showing is not remembered; a start always hides what the sections say.
/// - **A reveal is applied at once and followed up apart.** `applyReveal` puts the plan on the bar and returns; `followUp` then looks
///   for the revealed icons and for room, which takes seconds when the bar is slow. A caller that has to apply changes in order does
///   the first one by one and starts each follow-up on a task of its own, so a follow-up never holds up the next change; a newer
///   change makes an older follow-up stop (it is stale), and nothing is ever cancelled for that. `setReveal` is the two together.
/// - **Refresh, reset and auto-refresh** are in `refresh()`, `reset(restarter:replayJournal:)` and `scan`: a refresh applies the plan
///   again whether or not it is the one that was applied, a reset takes everything down and restarts the menu bar's process, and the
///   session refreshes by itself (once, and logged) when the agent hasn't answered three reads in a row or a display change left a bar
///   empty (`AutoRefreshPolicy`).
/// - **Quitting** (`tearDownForQuit()`) ends reads and plans for good, and takes the engine down within a bound.
public actor MenuBarSession {
    /// How often the bar is looked at while a reveal is being confirmed. Each look reads one window of MenuBarAgent's.
    static let confirmationInterval: Duration = .milliseconds(250)
    /// How long a reset waits for the agent to answer a read once it is running again, and how often it asks.
    static let agentWait: Duration = .seconds(5)
    static let agentPollInterval: Duration = .milliseconds(250)
    /// The most that taking the engine down at quit waits for: a teardown can queue behind a plan an engine is still applying (a
    /// preferences service that disagrees costs seconds), and the app can't wait for that.
    static let quitTeardownLimit: Duration = .milliseconds(1500)
    static let quitStillBusyLogLine = "the hiding method was still busy at quit; macOS releases its hold shortly after Mantel quits"
    static let couldNotLookLogLine = "the reveal couldn't be confirmed on the bar (Accessibility, MenuBarAgent or its window didn't answer); going on"

    /// What the log says when a reveal isn't seen on the bar within the wait: how many icons were there of how many there should be.
    /// Counts only: nothing here names an app.
    static func notSeenLogLine(drawn: Int, expected: Int) -> String {
        "the reveal wasn't seen on the bar within the wait (\(drawn) of \(expected) icons on the main bar); going on"
    }

    private let scanner: MenuBarScanner
    private let hiding: HidingController
    private let runningApps: @Sendable () -> [RunningApp]
    private let loadSections: @Sendable () async -> SectionModel
    private let saveSections: @Sendable (SectionModel) async -> Void
    private let turnedOff: @Sendable () async -> TurnedOffList
    private let ownBundleID: String
    private let clock: any Clock
    private let confirmationWait: Duration
    /// The windows on screen, which say whether a display's bar is shown (`BarVisibility`). Read only when a read of the menu bar has a «.
    private let windows: any WindowListReading

    private var settings: HidingSettings
    /// Where everything is. (Readable by the tests of the session.)
    private(set) var sections = SectionModel()
    private var inventory = Inventory.empty
    private var widths = ItemWidthCache()
    /// How many slots the bar should draw, learned from the reads (what a reveal is looked for by).
    private var expectation = BarExpectation()
    private var tracker = AutoOverflowTracker()
    /// Where the apps' icons were last seen on each bar: what the Shown apps are put in order by when the dots need room.
    private var barOrder = BarOrder()
    /// What has been said in the log about the dots and the « menu, so that a state of the bar is said once for as long as Mantel runs.
    private var dotsLog = DotsRoomLog()
    /// What the log has said about the dots, the last hundred lines. (Readable by the tests of the session.)
    private(set) var dotsLogLines: [String] = []
    /// The displays as the session was last told they are, for naming the kind of display in the log.
    private var knownLayout: DisplayLayout?
    /// What the apps that were put on trial said of where they were, before the trial, for as long as they say it still: a place that is
    /// what it was is no sign of how the trial went (`OverflowInputs.overflowedApps(in:ignoringUnchangedPlaces:)`). Cleared when the
    /// displays change.
    private var placesBeforeTrials: [ItemID: [String: CGRect]] = [:]
    private var turnedOffList: TurnedOffList = .apps([])
    /// How icons are hidden and why, as of the last time the engines were asked or switched.
    private var lastStatus: EngineStatus?

    private var revealState: RevealState = .collapsed
    /// Bumped by every `applyReveal` and `collapseReveal`, so that a follow-up that is under way knows it has been overtaken.
    private var revealGeneration = 0
    /// The Shown apps that are concealed to make room for a reveal. Cleared by every `applyReveal` and `collapseReveal`: a swap lasts as long as its reveal.
    private var swapConcealed: Set<String> = []
    private var alreadyLogged = false
    /// Whether the log has said, during this run, that the bar couldn't be looked at to confirm a reveal.
    private var couldNotLookLogged = false
    private var activeScreenWidth: CGFloat = 0

    /// The front app (by process), and where its menus are. They are read once for each front app, not for each read of the bar.
    private(set) var frontPID: pid_t?
    private var frontMenuFrames: [CGRect] = []

    /// When the engines last finished with a plan or a switch of engine, and nil until the first plan has been applied. A read that was
    /// taken before that shows the bar as an earlier plan left it (a reveal that was just collapsed, say, or everything on the bar
    /// before anything was hidden), and is not what automatic overflow judges the bar by. This is also what keeps the read that judges
    /// a trial honest: the plan that opened the trial is the last one the engines were given, and a read taken before it was applied
    /// says nothing of how the apps fit.
    private var lastApplyEndedAt: Date?
    /// How many switches of engine are under way (a switch applies the plan with the new engine and takes the old one down): a read
    /// that comes in the middle of one shows a bar in transition.
    private var switchesUnderway = 0

    private var scheduler: ScanScheduler?
    private var periodicTask: Task<Void, Never>?
    private var isStarted = false

    /// Whether a reset is under way. Set before the reset awaits anything, so that a second one finds it set.
    private var resetting = false
    /// Set when quitting begins: no plan is applied and nothing is read from then on.
    private var isQuitting = false
    private var autoRefresh = AutoRefreshPolicy()
    /// The displays, as the session was last told they are (`displaysChanged`).
    private var knownDisplays: Set<String> = []
    /// The displays that had a bar, or slots, in the last read the agent answered: only a display that had one can be left with none.
    private var displaysWithABar: Set<String> = []

    // The plan that is applied, and the one that is asked for.
    private var currentPlan: VisibilityPlan?
    /// The plan that was asked for last. (Readable by the tests of the session.)
    private(set) var lastSubmitted: VisibilityPlan?
    private var pendingApply: (plan: VisibilityPlan, force: Bool)?
    private var isApplying = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []

    // Reads that someone waits for.
    private struct ScanTicket {
        /// The read that answers is one that began at this moment or later.
        let since: Date
        var result: Inventory?
        var isDone = false
        var continuation: CheckedContinuation<Inventory?, Never>?
    }
    private var tickets: [Int: ScanTicket] = [:]
    private var nextTicketID = 0
    /// How many reads have been through `ingest`. For tests.
    private(set) var scansIngested = 0

    // What is published.
    private var subscribers: [Int: AsyncStream<MenuBarState>.Continuation] = [:]
    private var nextSubscriberID = 0
    private(set) var lastPublished: MenuBarState?

    /// - Parameters:
    ///   - scanner: reads the menu bar. Only the session asks it for a read, and only through the scheduler it makes.
    ///   - hiding: the engines. Only the session calls it.
    ///   - runningApps: every running app that has a bundle ID, background-only ones included (`RunningAppsSource.all`): what the plan
    ///     is made for.
    ///   - loadSections: the sections that were saved; `saveSections` keeps them.
    ///   - turnedOff: the apps macOS has turned off in System Settings, or why that isn't known.
    ///   - windows: the windows on screen. A read of the menu bar with a « in it is told apart by which bars are shown: a bar that a
    ///     full-screen app has hidden has no dots to make room for.
    ///   - confirmationWait: how long a reveal is looked for on the bar before the session goes on without having seen it, as the
    ///     clock measures it (the time a look takes counts). Seeing it is only advisory: a look at the bar can miss a change that did
    ///     happen, and never fails anything.
    public init(scanner: MenuBarScanner, hiding: HidingController, runningApps: @escaping @Sendable () -> [RunningApp],
                loadSections: @escaping @Sendable () async -> SectionModel,
                saveSections: @escaping @Sendable (SectionModel) async -> Void,
                turnedOff: @escaping @Sendable () async -> TurnedOffList,
                settings: HidingSettings, ownBundleID: String, clock: any Clock, windows: any WindowListReading,
                confirmationWait: Duration = .seconds(2)) {
        self.scanner = scanner
        self.hiding = hiding
        self.runningApps = runningApps
        self.loadSections = loadSections
        self.saveSections = saveSections
        self.turnedOff = turnedOff
        self.settings = settings
        self.ownBundleID = ownBundleID
        self.clock = clock
        self.windows = windows
        self.confirmationWait = confirmationWait
    }

    deinit {
        periodicTask?.cancel()
        if let scheduler { Task { await scheduler.stop() } }
        for continuation in subscribers.values { continuation.finish() }
    }

    // MARK: Starting

    /// Loads the sections, chooses how to hide, reads the menu bar, puts apps that are new in their section, and applies the plan, with
    /// every reveal collapsed. The bar is read once more, now that it is collapsed, and that read is the first that apps that don't fit
    /// are moved to Hidden by. Then the menu bar is read every ten seconds, and a minute at a time the apps automatic overflow moved
    /// out are asked whether they fit again.
    ///
    /// The first read comes before anything is hidden, which is what lets Mantel see how wide each icon is. It judges nothing about
    /// room: the icons that are about to be hidden are on the bar then.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        knownLayout = await scanner.currentLayout()
        sections = await loadSections()
        revealState = .collapsed
        await chooseEngine()
        turnedOffList = await turnedOff()

        let scheduler = ScanScheduler(clock: clock) { [weak self] reasons in
            await self?.scan(reasons)
        }
        self.scheduler = scheduler
        _ = await requestScan(.refresh)
        // A read that told nothing still leaves the sections to be applied. (A plan that an engine failed to apply was asked for, and is
        // sent again with the next one.)
        if currentPlan == nil { await rebuildAndApply() }
        // The first read was taken with everything on the bar, the Hidden apps among it, so it judged nothing: apps that are Shown may
        // have been pushed out of the bar by icons that are about to be hidden. The bar is read again, collapsed, and judged at once.
        _ = await requestScan(.refresh)
        // Quitting that began while the session was starting has stopped the reads: they are not started again (`start()` of the scheduler
        // would), nor is the minute's check for room.
        guard !isQuitting else { return }
        await scheduler.start()
        // A quit can begin while the scheduler starts: its stop is queued behind the start, and no check for room is made for it.
        guard !isQuitting else { return }
        periodicTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: AutoOverflowTracker.periodicInterval) } catch { return }
                await self?.tryTrial(.periodic)
            }
        }
    }

    /// The states the session reaches, each when it changes. Only the newest is kept for a reader that is behind, and the one there is
    /// now (if there is one) comes first.
    public func states() -> AsyncStream<MenuBarState> {
        let (stream, continuation) = AsyncStream.makeStream(of: MenuBarState.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        if let lastPublished { continuation.yield(lastPublished) }
        return stream
    }

    private func dropSubscriber(_ id: Int) {
        subscribers[id] = nil
    }

    // MARK: Events

    /// Some apps started or quit. The plan is made again at once, with the apps that are running now, and applied: an app that
    /// has just started is where the new-items section says before it has drawn anything, so a new app that is meant to be hidden is
    /// never seen. A read follows (with the others that come at the same moment), and when it lists the new app's icons the app is put
    /// in its section.
    public func runningAppsChanged(_ change: RunningAppsChange) async {
        guard !change.isEmpty else { return }
        await rebuildAndApply()
        await scheduler?.request(.appsChanged)
    }

    /// The displays changed. The menu bar is read again, and with it as it is now, the apps automatic overflow moved out are asked
    /// whether they fit.
    public func displaysChanged(_ layout: DisplayLayout) async {
        // No display at all (they are asleep, or all unplugged for a moment): there is no bar to read, and nothing to judge a trial by.
        guard !layout.displays.isEmpty else { return }
        knownDisplays = Set(layout.displays.map(\.uuid))
        knownLayout = layout
        placesBeforeTrials.removeAll()
        // What was seen before the change, and the front app's menus (they are where they were), are of the displays as they were: the
        // read taken for the change is marked without menus, and counts for nothing towards the reads in a row.
        tracker.displaysAreChanging()
        frontMenuFrames = []
        _ = await requestScan(.displaysChanged)
        // What is known of the front app's menus is where they were. (The front app is asked about after the read: another may have come
        // to the front while it was taken.)
        if let pid = frontPID { await refreshFrontMenus(pid: pid) }
        await tryTrial(.displaysChanged)
    }

    /// A different app came to the front, on a screen of this width (in points). A wide enough screen shows everything (when the
    /// person asked for that); the front app's menus change how much of the bar is free, so the apps that were moved out for want of
    /// room are asked whether they fit.
    public func frontAppChanged(pid: pid_t, activeScreenWidth: CGFloat) async {
        let widthChanged = activeScreenWidth != self.activeScreenWidth
        self.activeScreenWidth = activeScreenWidth
        if pid != frontPID { await refreshFrontMenus(pid: pid) }
        if widthChanged { await rebuildAndApply() }
        await tryTrial(.frontAppChanged)
    }

    /// Where the menus of the front app are (CoreGraphics global points), as they were read when the front app last changed or the
    /// displays did. They are what the pointer's whereabouts are classified by (`EmptySpace`): the app keeps its own copy, taken after
    /// each of those events. Empty until a front app is known, and for an app that has no menus.
    public func frontAppMenuFrames() -> [CGRect] {
        frontMenuFrames
    }

    private func refreshFrontMenus(pid: pid_t) async {
        frontPID = pid
        let frames = await scanner.appMenuFrames(pid: pid)
        // Another app may have come to the front while this one's menus were read.
        if frontPID == pid { frontMenuFrames = frames }
    }

    // MARK: Revealing

    /// Shows what the state shows, or hides it again, and says what is left to do about icons that have no room: `applyReveal`, then
    /// `followUp`.
    public func setReveal(_ state: RevealState) async -> NoRoomAction {
        await followUp(applyReveal(state))
    }

    /// Puts the plan for the state on the bar and returns, whatever the state is. It does nothing else: nothing is looked for and
    /// nothing is read, so this takes as long as the engines do, and a change that comes after it can be applied at once.
    ///
    /// It ends any follow-up that is under way for an earlier change: that one is stale from here on.
    public func applyReveal(_ state: RevealState) async -> AppliedReveal {
        revealGeneration += 1
        let generation = revealGeneration
        revealState = state
        swapConcealed = []
        await rebuildAndApply()
        return AppliedReveal(state: state, generation: generation)
    }

    /// What follows a reveal that was applied: the bar is looked at every 250 ms until it has a place for every revealed icon, or the
    /// look can't tell (nothing to look with, or a read timed out: waiting wouldn't help, so the wait ends at once), or the confirmation
    /// wait is over (never a failure: not seeing the icons is logged, and the session goes on), and then the whole menu bar is read.
    /// If revealed icons are piled up in the « overflow, the person's no-room policy decides: the session itself makes room by concealing
    /// Shown apps, right-most first, and reads again, up to three times (`SwapCalculator.maximumRounds`); what is left for the app comes
    /// back as the answer, which is never `.swap`.
    ///
    /// A follow-up that is overtaken by a newer change of reveal stops, wherever it is, and answers `.none`. A collapse has nothing to
    /// follow up.
    public func followUp(_ applied: AppliedReveal) async -> NoRoomAction {
        let generation = applied.generation
        guard generation == revealGeneration, !isQuitting else { return .none }

        let revealed = revealedApps()
        guard !revealed.isEmpty else { return .none }
        await confirmReveal(generation: generation)
        return await settleRoom(for: revealed, generation: generation, menuBarTakenOver: false)
    }

    /// The app has made room itself (it took the menu bar over): the menu bar is read, and what is left to do is answered as at the end of
    /// `setReveal`, knowing that it has. (Should the policy be to swap, the swap is made here too: the answer is never `.swap`.)
    public func recheckRoom(menuBarTakenOver: Bool) async -> NoRoomAction {
        let revealed = revealedApps()
        guard !revealed.isEmpty else { return .none }
        return await settleRoom(for: revealed, generation: revealGeneration, menuBarTakenOver: menuBarTakenOver)
    }

    /// Reads the bar and answers what is left to do about the revealed apps that have no room, making room itself where the policy is
    /// to swap: Shown apps are concealed, the bar is read again, and so on up to the most rounds there are. Stops, answering `.none`,
    /// when another reveal has overtaken this one.
    private func settleRoom(for revealed: Set<String>, generation: Int, menuBarTakenOver: Bool) async -> NoRoomAction {
        var round = 0
        while generation == revealGeneration {
            guard let read = await requestScan(.reveal), generation == revealGeneration else { return .none }
            let check = roomCheck(revealed: revealed, in: read, round: round)
            let action = decide(check, menuBarTakenOver: menuBarTakenOver)
            guard case .swap = action else { return action }

            let concealed = appsToConceal(forRevealed: check.overflowedRevealedApps, in: read)
            guard !concealed.subtracting(swapConcealed).isEmpty else {
                // Every Shown app there is has been tried: nothing more can be made.
                Log.warning("session", NoRoomResponse.giveUpText)
                return .giveUp(NoRoomResponse.giveUpText)
            }
            swapConcealed.formUnion(concealed)
            await rebuildAndApply()
            round += 1
        }
        return .none
    }

    /// The apps that a reveal brings onto the bar: running apps whose icons are in a section the state shows, and aren't Shown anyway.
    private func revealedApps() -> Set<String> {
        let shown: Set<MenuBarSection> = switch revealState.level {
        case .off: []
        case .hidden: [.hidden]
        case .all: [.hidden, .alwaysHidden]
        }
        guard !shown.isEmpty else { return [] }
        let running = Set(runningBundleIDs())
        return Set(inventory.appsWithItems.filter { running.contains($0) && shown.contains(sections.section(ofApp: $0)) })
    }

    /// What a look at the bar makes of a reveal.
    private enum BarVerdict {
        /// The bar has a place for every icon the plan draws.
        case seen
        /// Not yet: this many icons are there of this many.
        case notYet(drawn: Int, expected: Int)
        /// The bar couldn't be looked at (no Accessibility, no MenuBarAgent or window, a read that timed out): waiting won't help.
        case cantTell
    }

    /// Looks at the bar every 250 ms until the revealed icons are on it or the wait is over. Never fails: not seeing them is logged,
    /// and the session goes on. Stops when another change of reveal has overtaken this one (and says nothing then).
    ///
    /// - **The wait is time on the clock,** from the first look, so the time a look takes counts: a look that takes longer than the wait
    ///   is the last.
    /// - **A look that can't tell ends it at once** (nothing to look with, or the read timed out): another look would only wait.
    ///   The log says so, once for as long as Mantel runs.
    private func confirmReveal(generation: Int) async {
        let started = clock.now()
        let wait = Double(confirmationWait.components.seconds) + Double(confirmationWait.components.attoseconds) / 1e18
        while generation == revealGeneration {
            switch await lookForReveal() {
            case .seen:
                return
            case .cantTell:
                if generation == revealGeneration, !couldNotLookLogged {
                    couldNotLookLogged = true
                    Log.info("session", Self.couldNotLookLogLine)
                }
                return
            case .notYet(let drawn, let expected):
                guard clock.now().timeIntervalSince(started) < wait else {
                    if generation == revealGeneration { Log.info("session", Self.notSeenLogLine(drawn: drawn, expected: expected)) }
                    return
                }
                do { try await clock.sleep(for: Self.confirmationInterval) } catch { return }
            }
        }
    }

    /// A look at the main display's bar: whether it has a place for every icon the plan draws now, counted against how many the last
    /// read says there should be (`BarExpectation`). The apps aren't asked for anything. A look that was cut short is only believed
    /// when it saw enough.
    private func lookForReveal() async -> BarVerdict {
        guard let look = await scanner.lookAtBar() else { return .cantTell }
        let expected = expectedSlots(drawnBy: buildPlan(), on: look.displayUUID)
        if look.drawnSlots >= expected { return .seen }
        return look.isComplete ? .notYet(drawn: look.drawnSlots, expected: expected) : .cantTell
    }

    /// How many slots the bar of this display should have for the plan: what the last read holds that the plan draws there.
    private func expectedSlots(drawnBy plan: VisibilityPlan, on displayUUID: String) -> Int {
        let off: Set<String> = if case .apps(let bundleIDs) = turnedOffList { Set(bundleIDs) } else { [] }
        return expectation.slotCount(drawnBy: plan, in: inventory, on: displayUUID, turnedOff: off)
    }

    /// What one look at the bar makes of a plan that has just been applied: whether the bar has no more slots than the plan draws (an icon
    /// that is hidden has none). It is how the controller of the engines confirms a switch of engine, the way a reveal is confirmed:
    /// the main display's bar is looked at, one window of MenuBarAgent's, and nobody else's reads. A look that was cut short is not
    /// believed, either way: what it saw is what was read before the read that timed out.
    public func lookForHiding(of plan: VisibilityPlan) async -> PlanConfirmation {
        guard !isQuitting, let look = await scanner.lookAtBar(), look.isComplete else { return .cantTell }
        return look.drawnSlots <= expectedSlots(drawnBy: plan, on: look.displayUUID) ? .seen : .notYet
    }

    /// What the read says of the revealed apps: which of them have no room (they are piled in the « overflow, or behind the notch, on any
    /// display), and how much room they need, from the widths they had when last on the bar.
    private func roomCheck(revealed: Set<String>, in read: Inventory, round: Int) -> RoomCheck {
        let overflowed = OverflowInputs.overflowedApps(in: read).intersection(revealed)
        let needed = overflowed.reduce(into: CGFloat.zero) { $0 += widths.width(ofApp: $1, in: read) ?? 0 }
        return RoomCheck(overflowedRevealedApps: overflowed, neededWidth: needed, round: round)
    }

    /// What to do about the revealed apps that have no room, by the person's policy. Says in the log, once for as long as Mantel runs,
    /// that the « menu is keeping them.
    private func decide(_ check: RoomCheck, menuBarTakenOver: Bool) -> NoRoomAction {
        let action = NoRoomResponse.decide(policy: settings.noRoomPolicy, check: check, alreadyLogged: alreadyLogged,
                                           menuBarTakenOver: menuBarTakenOver)
        switch action {
        case .leaveOverflow(let logOnce):
            if logOnce {
                Log.info("session", NoRoomResponse.overflowLogLine)
                alreadyLogged = true
            }
        case .giveUp(let text):
            Log.warning("session", text)
        case .none, .swap, .takeOverMenuBar:
            break
        }
        return action
    }

    /// The Shown apps to conceal to make room for the revealed apps that have none, on each display that is short of room: the
    /// right-most first, until what they draw is as wide as what the revealed apps need there.
    ///
    /// Only apps that are in the Shown section are candidates, and only those that are on that display's bar now: an app that is
    /// visible for another reason (a rule, a wide screen, or because it is revealed) isn't Shown, and isn't concealed to make room.
    private func appsToConceal(forRevealed overflowed: Set<String>, in read: Inventory) -> Set<String> {
        var concealed: Set<String> = []
        for bar in read.bars {
            let display = bar.displayUUID
            let short = overflowed.filter { app in read.items(ofApp: app).contains { $0.overflowedOn.contains(display) } }
            guard !short.isEmpty else { continue }
            let needed = short.reduce(into: CGFloat.zero) { $0 += widths.width(ofApp: $1, in: read) ?? 0 }

            var candidates: [(bundleID: String, right: CGFloat, width: CGFloat)] = []
            for app in read.appsWithItems where sections.section(ofApp: app) == .shown && !swapConcealed.contains(app) {
                let drawn = read.items(ofApp: app).compactMap { item -> CGRect? in
                    item.overflowedOn.contains(display) ? nil : item.frames[display]
                }
                guard let right = drawn.map(\.maxX).max() else { continue }
                candidates.append((app, right, widths.width(ofApp: app, in: read) ?? drawn.reduce(0) { $0 + $1.width }))
            }
            candidates.sort { $0.right > $1.right }
            concealed.formUnion(SwapCalculator.appsToConceal(needed: needed, shownRightToLeft: candidates.map { ($0.bundleID, $0.width) },
                                                             never: [ownBundleID]))
        }
        return concealed
    }

    // MARK: The person's changes

    /// The settings changed. A new way of hiding is switched to, and the plan is made again for the rest.
    public func setSettings(_ new: HidingSettings) async {
        let old = settings
        settings = new
        // A reset makes the choice again when it is done, from the settings as they are then.
        if old.method != new.method, !resetting { await chooseEngine() }
        await rebuildAndApply()
    }

    /// The person moves one icon (its whole app, or a system item by itself) to a section.
    public func move(item: ItemID, to section: MenuBarSection) async {
        let before = sections
        sections.move(item: item, to: section)
        await changedSections(from: before)
    }

    /// The person moves an app to a section.
    public func move(app bundleID: String, to section: MenuBarSection) async {
        let before = sections
        sections.move(app: bundleID, to: section)
        await changedSections(from: before)
    }

    /// Where apps that are new go.
    public func setNewItemsSection(_ section: MenuBarSection) async {
        let before = sections
        sections.newItems = section
        await changedSections(from: before)
    }

    /// Drops what is known of an app. It is placed again, in the new-items section, if it is seen again.
    public func forget(app bundleID: String) async {
        let before = sections
        sections.forget(app: bundleID)
        await changedSections(from: before)
    }

    private func changedSections(from before: SectionModel) async {
        await saveIfChanged(from: before)
        await rebuildAndApply()
    }

    /// Settings opened or closed: the menu bar is read every two seconds while it is open, and the list of apps macOS has turned off is
    /// read again when it opens.
    public func setSettingsOpen(_ open: Bool) async {
        await scheduler?.setSettingsOpen(open)
        if open {
            turnedOffList = await turnedOff()
            publish()
        }
    }

    /// The person gave Mantel a file, or put back what a platform test left in the system ("Replay now"): what depends on
    /// it is asked again. The list of apps macOS has turned off is read again, and the way of hiding is chosen again, which asks each
    /// engine whether it can be used now. A choice that comes out as before changes nothing (`HidingController.choose` switches only
    /// when the engine in charge is another one), so nothing flickers; one that now falls on another engine is a switch like any other.
    /// The state is published with the new reasons.
    ///
    /// Not before the session has started (its start asks both), not while a reset is under way, and not once quitting has begun: it
    /// does nothing then.
    public func permissionsChanged() async {
        guard isStarted, mayChangeEngines(forReset: false) else { return }
        turnedOffList = await turnedOff()
        guard mayChangeEngines(forReset: false) else { return }
        await chooseEngine()
        guard !isQuitting else { return }
        publish()
    }

    // MARK: Refreshing

    /// Starts over from what is true: the way of hiding is chosen again (what can be used may have changed: a leftover of a platform
    /// test was put back, say, and an engine that failed out is tried again), the plan is applied again whether or not it is the one that
    /// was applied (an engine that remembers what it applied makes it live once more), and the menu bar is read again.
    ///
    /// Nothing is done while a reset is under way (it does all of this when it is done) or once quitting has begun, and the answer says
    /// so.
    @discardableResult
    public func refresh() async -> RefreshOutcome {
        if await refreshNow() { return .done }
        return .refused(isQuitting ? CommandAnswers.quitting : CommandAnswers.resetUnderWay)
    }

    /// Whether the engines may be chosen or applied to now: not once quitting has begun, and not while a reset is under way, unless it
    /// is the reset itself that is asking.
    private func mayChangeEngines(forReset: Bool) -> Bool {
        !isQuitting && (forReset || !resetting)
    }

    /// `refresh`, saying whether it was made to the end. A reset can begin, or quitting, while the list of apps macOS has turned off is
    /// being asked for and while the choice of engine waits behind a plan that is being applied; what it began to do is not done after
    /// that, or it would put an engine back in charge in the middle of the reset.
    @discardableResult
    private func refreshNow(forReset: Bool = false) async -> Bool {
        guard mayChangeEngines(forReset: forReset) else { return false }
        turnedOffList = await turnedOff()
        guard mayChangeEngines(forReset: forReset) else { return false }
        await chooseEngine(forReset: forReset)
        guard mayChangeEngines(forReset: forReset) else { return false }
        await rebuildAndApply(force: true)
        _ = await requestScan(.refresh)
        return true
    }

    // MARK: Resetting

    /// Whether a reset is under way.
    public var isResetting: Bool {
        resetting
    }

    /// `reset(restarter:replayJournal:)` unless one is under way already, and what became of it as the commands and Settings say it.
    public func resetIfIdle(restarter: any MenuBarAgentRestarting,
                            replayJournal: @escaping @Sendable () async -> Void) async -> ResetOutcome {
        guard !isQuitting else { return .refused(CommandAnswers.quitting) }
        guard !resetting else { return .alreadyUnderWay }
        do throws(RestartError) {
            try await reset(restarter: restarter, replayJournal: replayJournal)
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Undoes everything Mantel did to the menu bar and restarts the process that draws it, for a bar that is stuck. Not to be called while
    /// one is under way (`resetIfIdle` says so).
    ///
    /// In this order:
    /// 1. The engine in charge is taken down: everything is shown, and what it changed in the system is put back. (It waits for a plan
    ///    that is being applied; plans that come after find nothing in charge and apply nothing.)
    /// 2. `replayJournal` puts back what the journal still holds.
    /// 3. `restarter` has the menu bar's process start again.
    /// 4. The reveal is collapsed.
    /// 5. The menu bar is read until the agent answers, for up to 5 seconds (it isn't an error if it doesn't: hiding is tried anyway).
    /// 6. The way of hiding is chosen again and the plan is applied: a reset doesn't stop hiding.
    ///
    /// **If the process doesn't come back** (or wasn't running) the reset ends at 3: it throws, and everything stays shown. Nothing hides
    /// again until a refresh, since there is no menu bar to hide icons on; the reveal is collapsed all the same.
    ///
    /// **While it runs** the session reads the bar and goes on making plans, but applies none, doesn't judge what it reads (an empty bar
    /// is a reset's doing), starts no trial, and ignores a refresh and a change of hiding method (step 6 makes the choice again), also one
    /// that began before the reset did and is waiting for something. The plan that waits to be applied is dropped when it begins, and the
    /// controller of the engines is told to forget its choice when it is taken down (only an explicit choice puts an engine in charge).
    /// It is carried out by a task of its own, so that a caller that is cancelled doesn't leave it half done.
    public func reset(restarter: any MenuBarAgentRestarting,
                      replayJournal: @escaping @Sendable () async -> Void) async throws(RestartError) {
        resetting = true
        // What waits to be applied is not applied after the engine is down (as at quit): the plan that is being applied is let finish.
        pendingApply = nil
        let outcome = await Task { await self.runReset(restarter: restarter, replayJournal: replayJournal) }.value
        resetting = false
        try outcome.get()
    }

    private func runReset(restarter: any MenuBarAgentRestarting,
                          replayJournal: @escaping @Sendable () async -> Void) async -> Result<Void, RestartError> {
        Log.info("session", "resetting the menu bar")
        await hiding.tearDown()
        await replayJournal()

        do throws(RestartError) {
            try await restarter.restart()
        } catch {
            Log.warning("session", "the menu bar couldn't be restarted: everything stays shown")
            collapseReveal()
            // The plan says what is wanted, and nothing is in charge to apply it.
            await rebuildAndApply()
            return .failure(error)
        }

        collapseReveal()
        await waitForAgent()
        await refreshNow(forReset: true)
        return .success(())
    }

    /// The reveal is over: what was shown is put away, and a reveal that is under way is overtaken.
    private func collapseReveal() {
        revealGeneration += 1
        revealState = .collapsed
        swapConcealed = []
    }

    /// Reads the bar until the agent answers it, for up to `agentWait`.
    private func waitForAgent() async {
        guard scheduler != nil else { return }
        var waited: Duration = .zero
        while !isQuitting {
            if let read = await requestScan(.refresh), read.agentAnswered { return }
            guard waited < Self.agentWait else {
                let seconds = Self.agentWait.components.seconds
                Log.warning("session", "MenuBarAgent hadn't answered \(seconds) seconds after it restarted; going on")
                return
            }
            do { try await clock.sleep(for: Self.agentPollInterval) } catch { return }
            waited += Self.agentPollInterval
        }
    }

    // MARK: Quitting

    /// Ends what the session does to the menu bar, for the app is quitting: no plan is applied from now on (the one that waits for the
    /// engine is dropped, the one the engine is applying is let finish), nothing is read, and the engine in charge is taken down, which
    /// shows everything and puts back what it changed in the system.
    ///
    /// The engine is waited for for 1.5 seconds at most (`quitTeardownLimit`): its teardown can queue behind a plan it is applying, and
    /// the app can't wait for that. It goes on after that, unwatched, and the journal's replay puts back what is left; macOS lets go of an
    /// allowlist by itself shortly after Mantel has quit.
    public func tearDownForQuit() async {
        if await !tearDownEngineForQuit() { Log.warning("quit", Self.quitStillBusyLogLine) }
    }

    /// `tearDownForQuit`, saying whether the engine was taken down within the limit.
    func tearDownEngineForQuit() async -> Bool {
        isQuitting = true
        pendingApply = nil
        periodicTask?.cancel()
        periodicTask = nil
        await scheduler?.stop()
        // A read that was asked for and won't be taken is answered with nothing, so that whoever waits for it goes on.
        for id in Array(tickets.keys) { abandon(id) }
        let hiding = hiding
        return await TimeBound.finishes(within: Self.quitTeardownLimit, clock: clock) { await hiding.shutDown() }
    }

    /// How icons are hidden now, and why.
    public func engineStatus() async -> EngineStatus {
        await hiding.status()
    }

    /// Has the controller choose the engine for the person's method again. A new choice is a switch: the plan is applied with the new
    /// engine and the old one taken down. A read that comes in the middle of it shows a bar in transition, so it is not judged by
    /// automatic overflow, and neither is one taken before it ended.
    private func chooseEngine(forReset: Bool = false) async {
        // A choice made after quitting began, or during a reset that isn't the one making it, would put an engine in charge again, with
        // the plan applied: they took them down.
        guard mayChangeEngines(forReset: forReset) else { return }
        switchesUnderway += 1
        // On a task of its own, as the plans are applied (`drainPlans`): the switch applies the plan with the new engine and then takes
        // the old one down, and a caller that is cancelled while it runs mustn't cut the new engine's activation short, which would leave
        // the old one taken down and the new one with nothing applied: a bar that is fully shown.
        // The epoch is read now, with the guard just passed: a teardown (a reset's, or the quit's) that comes before the call gets to the
        // controller makes it a choice of the time before, and it is dropped there.
        let hiding = hiding, method = settings.method, epoch = hiding.epoch
        await Task { await hiding.choose(method: method, expectedEpoch: epoch) }.value
        switchesUnderway -= 1
        // Before the first plan was applied a switch has changed nothing on the bar, and the first read stays the one that judges nothing.
        if lastApplyEndedAt != nil { lastApplyEndedAt = clock.now() }
        lastStatus = await hiding.status()
    }

    // MARK: Reading the menu bar

    /// Asks for a read and waits for the one that answers it: one that began now or later.
    private func requestScan(_ reason: ScanScheduler.Reason) async -> Inventory? {
        guard let scheduler, !isQuitting else { return nil }
        let id = nextTicketID
        nextTicketID += 1
        // The ticket is out before the request is made: a read that is quick can be over before this call is back.
        tickets[id] = ScanTicket(since: clock.now())
        await scheduler.request(reason)
        return await answer(of: id)
    }

    private func answer(of id: Int) async -> Inventory? {
        guard let ticket = tickets[id] else { return nil }
        if ticket.isDone {
            tickets[id] = nil
            return ticket.result
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Inventory?, Never>) in
                if Task.isCancelled {
                    tickets[id] = nil
                    continuation.resume(returning: nil)
                } else {
                    tickets[id]?.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: Int) {
        tickets.removeValue(forKey: id)?.continuation?.resume(returning: nil)
    }

    /// What the scheduler runs when a read is due: reads, takes in what was read, and tells those who waited for it.
    private func scan(_ reasons: Set<ScanScheduler.Reason>) async {
        let read = await ingest(await scanner.scan(reasons: reasons, concealed: appsNotDrawn()), afterDisplayChange: reasons.contains(.displaysChanged))
        scansIngested += 1
        for (id, ticket) in tickets where !ticket.isDone && read.capturedAt >= ticket.since {
            if let continuation = ticket.continuation {
                tickets[id] = nil
                continuation.resume(returning: read)
            } else {
                tickets[id]?.result = read
                tickets[id]?.isDone = true
            }
        }
        considerRefreshing(after: read, reasons: reasons)
    }

    /// Asks the auto-refresh policy whether this read calls for a refresh, and starts one if it does. It isn't asked during a reset (the
    /// bar is empty for a moment then, and what is read says nothing of a bar that is stuck) or after quitting has begun.
    ///
    /// The refresh is a task of its own: it asks for a read, and a read can't be taken while this one, which is what the scheduler is
    /// running, hasn't returned.
    private func considerRefreshing(after read: Inventory, reasons: Set<ScanScheduler.Reason>) {
        // A read that couldn't be taken because Accessibility isn't granted says nothing of any display.
        let canTell = !read.problems.contains(.accessibilityNotGranted)
        let hadABar = displaysWithABar
        if read.agentAnswered, canTell { displaysWithABar = Set(read.bars.map(\.displayUUID)).union(read.displaysWithSlots) }
        guard !resetting, !isQuitting else { return }
        // Only a display that had a bar in the read before can be left with an empty one: with "Displays have separate Spaces" off the
        // other displays have none at all, and a display change brings them without it being a bar that went empty.
        let displays = canTell ? knownDisplays.intersection(hadABar) : []
        let verdict = autoRefresh.scanFinished(agentAnswered: read.agentAnswered, displaysWithSlots: read.displaysWithSlots,
                                               displays: displays, afterDisplayChange: reasons.contains(.displaysChanged),
                                               now: clock.now())
        guard case .refresh(let reason) = verdict else { return }
        Log.info("session", "refreshing the menu bar: \(reason)")
        Task { await self.refresh() }
    }

    /// What every read of the menu bar comes to, whoever asked for it.
    ///
    /// - The spacer engine is told where the bars are, whichever engine is in charge, so that it has its widths when it takes over.
    /// - What is learned of how wide each icon is, and which icons the layout editor lists, is kept.
    /// - While the bar is collapsed (a reveal moves icons for a reason of its own), apps that don't fit move to Hidden, and the apps
    ///   on trial are judged. Not by a read that was taken before the engines last finished with a plan (the bar was as the plan before
    ///   it left it, and for a trial that is the plan that began it; the first read of all is taken before any plan, with everything
    ///   on the bar), nor while a plan is being applied or the engine is being switched, nor after an engine failed to apply the plan.
    /// - Mantel's own dots are judged by the same reads. A dot in the « menu of a bar that is shown gets room from the left-most Shown
    ///   apps (the tracker moves them to Hidden), and the read that follows says whether that was enough; with automatic overflow off,
    ///   or when the « menu is showing and it can't be told what is in it, the log says so and nothing is moved.
    ///   The read taken for a change of displays is of a bar that is being made again, so what it says of a dot that can't be placed is
    ///   not said in the log: the next read says it, if it agrees.
    /// - Apps that were never placed are put in the new-items section, and what changed is saved.
    /// - The plan is made again and applied if it is another one, and the state is published.
    ///
    /// Returns the read as it was taken in, with the icons that are out of the way marked (`BarRegion`): what is answered to whoever asked
    /// for it, and what everything else here reads.
    private func ingest(_ raw: Inventory, afterDisplayChange: Bool = false) async -> Inventory {
        // Which bars are shown is looked at only when a read has something to say of a place or of the dots.
        var shown: Set<String>?
        if raw.items.contains(where: { !$0.strayFrames.isEmpty }) { shown = shownBars(of: raw) }
        let read = markingWhatIsOutOfTheWay(raw, shownBars: shown)
        inventory = read
        // A read that says nothing of any bar (Accessibility isn't granted, MenuBarAgent isn't there) says nothing of the icons either.
        guard !read.bars.isEmpty else {
            await rebuildAndApply()
            return read
        }
        await hiding.spacer?.setBars(read.bars)
        widths.update(from: read)
        barOrder.update(from: read)

        // A place that has changed is new evidence: what was kept of it goes. (Changed as the comparison with what was kept counts it: a
        // place that has moved a fraction of a point is the same place.)
        for item in read.items {
            guard let before = placesBeforeTrials[item.id], !OverflowInputs.isSamePlaces(item.strayFrames, before) else { continue }
            placesBeforeTrials[item.id] = nil
        }

        let before = sections
        sections.note(read.items)
        let showsThePlan = readShowsThePlan(read)
        // What a read shows is what the plan in force makes of the bar: the icons it finds with no place on the bar, though the plan
        // draws them, are ones macOS isn't drawing, and a reveal isn't waited for to bring them.
        if showsThePlan, let currentPlan { expectation.learn(from: read, plan: currentPlan) }
        var madeRoomForTheDots = false
        if revealState == .collapsed, showsThePlan, !planIsTheSections {
            // A wide screen's plan draws every icon whatever the sections say: what a read finds says nothing of whether the icons the
            // sections show fit, so nothing is judged, and the reads counted before it don't carry over to when it is over.
            tracker.forgetSightings()
        } else if revealState == .collapsed, showsThePlan {
            let verdict = dotsVerdict(of: read, shownBars: &shown)
            var outcome: AutoOverflowTracker.Outcome?
            // Where the dots sit under the wide spacer is the spacer's doing (it pushes icons off the bar on purpose): none is made room for.
            let underTheSpacer = lastStatus?.kind == .spacer
            if settings.automaticOverflow {
                let trapped = underTheSpacer ? [] : DotsRoom.trappedBars(verdict.trapped, inferred: verdict.inferred, in: read,
                                                                          sections: sections, widths: widths, order: barOrder)
                let overflowed = OverflowInputs.overflowedApps(in: read, ignoringUnchangedPlaces: placesBeforeTrials)
                let result = tracker.arrived(
                    AutoOverflowTracker.Read(overflowedApps: overflowed, unansweredApps: read.unansweredApps, trappedBars: trapped,
                                             inferredApps: overflowed.intersection(OverflowInputs.inferredOnlyApps(in: read))),
                    sections: &sections, now: clock.now())
                // A move asks for the read that says whether it was enough; dots (or apps) found out of the way for the first time ask for the
                // read that confirms it.
                madeRoomForTheDots = !result.movedForDots.isEmpty || !result.awaitingConfirmation.isEmpty || !result.awaitingApps.isEmpty
                outcome = result
            } else {
                // Nothing is made of this read: the reads in a row that were counted don't carry over to when it is on again.
                tracker.forgetSightings()
            }
            sayAboutTheDots(verdict: verdict, outcome: outcome, underTheSpacer: underTheSpacer, afterDisplayChange: afterDisplayChange)
        }
        sections.assignNew(apps: read.appsWithItems)
        await saveIfChanged(from: before)
        await rebuildAndApply()
        // The read that says whether the room that was made was enough is one taken after the plan that made it was applied.
        if madeRoomForTheDots { await scheduler?.request(.trial) }
        return read
    }

    /// macOS 27 lists no slot for an icon it isn't drawing and shows no «: an icon that is out of the way says where it would be, behind the
    /// notch or under the front app's menus, and `BarRegion` takes it to be overflowed there. An app that the plan in force conceals isn't
    /// asked (`MatchInput.concealedApps`) and isn't judged: it can report a stale place, and is concealed, not overflowed.
    private func markingWhatIsOutOfTheWay(_ read: Inventory, shownBars: Set<String>?) -> Inventory {
        let notDrawn = appsNotDrawn()
        return BarRegion.marking(read, menuFrames: frontMenuFrames, shownBars: shownBars, draws: { !notDrawn.contains($0.ownerBundleID) })
    }

    /// What a read says of the dots on the bars that are shown. The window list is read only when the read has a « in it.
    private func dotsVerdict(of read: Inventory, shownBars shown: inout Set<String>?) -> DotsRoom.Verdict {
        guard DotsRoom.mayHaveAVerdict(in: read) else { return DotsRoom.Verdict() }
        let bars = shown ?? shownBars(of: read)
        shown = bars
        return DotsRoom.verdict(in: read, shownBars: bars)
    }

    /// The displays whose bar is on screen (a full-screen app hides one), from the window list.
    private func shownBars(of read: Inventory) -> Set<String> {
        BarVisibility.shownBars(windows.onScreenWindows(), bars: read.bars)
    }

    /// The apps the scanner isn't to believe the places of, and that are not judged: the ones the plan in force conceals, and the ones whose
    /// switch is off in System Settings (macOS doesn't draw them, whatever the plan says).
    private func appsNotDrawn() -> Set<String> {
        var apps = currentPlan?.concealedBundleIDs ?? []
        if case .apps(let off) = turnedOffList { apps.formUnion(off) }
        return apps
    }

    private func displayKind(of uuid: String) -> DisplayKind {
        knownLayout?.display(uuid: uuid)?.isBuiltIn == true ? .builtIn : .other
    }

    private func sayAboutTheDots(verdict: DotsRoom.Verdict, outcome: AutoOverflowTracker.Outcome?, underTheSpacer: Bool,
                                 afterDisplayChange: Bool) {
        // A read taken for a change of displays is of a bar that is being made again: where a dot can't be placed on it is no finding yet.
        var verdict = verdict
        if afterDisplayChange { verdict.cantTell = [:] }
        let lines = dotsLog.lines(verdict: verdict, outcome: outcome, automaticOverflowIsOn: settings.automaticOverflow,
                                  underTheSpacer: underTheSpacer, now: clock.now(), kind: { displayKind(of: $0) },
                                  hasNotch: { knownLayout?.display(uuid: $0)?.notch != nil })
        for line in lines {
            Log.info("session", line)
            dotsLogLines.append(line)
        }
        if dotsLogLines.count > 100 { dotsLogLines.removeFirst(dotsLogLines.count - 100) }
    }

    /// Whether the plan in force is made of the person's sections (and what the rules show of them), which is what automatic overflow and
    /// the room for the dots judge a read by. Not a wide screen's, which draws every icon: Hidden apps are on the bar though they are in
    /// Hidden, and Shown apps that don't fit the laptop's bar say nothing of the sections.
    private var planIsTheSections: Bool {
        switch currentPlan?.source {
        case .sections?, .rules?: true
        default: false
        }
    }

    /// Whether the read shows the bar as the plan in force makes it, so that what it finds is a verdict on the plan.
    ///
    /// Not a read taken before the first plan was applied: nothing is hidden yet (nil), the bar is not what the sections make of it.
    /// Nor one taken after an engine failed to apply the plan: the engine showed everything, and a bar that is fully shown says nothing
    /// of whether the apps fit once the plan is hidden. Nor one taken while a reset has everything shown, or while a plan is being
    /// applied or the engine switched, or one that began before the engines last finished.
    private func readShowsThePlan(_ read: Inventory) -> Bool {
        !isApplying && switchesUnderway == 0 && !resetting && lastStatus?.lastError == nil
            && (lastApplyEndedAt.map { read.capturedAt >= $0 } ?? false)
    }

    // MARK: Room may have returned

    /// Asks the tracker whether the apps it moved out may fit again, and if some are put on trial, applies the plan that shows them and
    /// then asks for a read of the bar: the read that judges the trial is one taken after the plan was applied.
    private func tryTrial(_ trigger: AutoOverflowTracker.Trigger) async {
        // Not while a reset has everything shown, nor once quitting has begun.
        guard !resetting, !isQuitting else { return }
        let mayTry = settings.automaticOverflow && revealState == .collapsed && planIsTheSections
        // A change of displays is told to the tracker whatever else is going on: what it knows of the room is out of date, and it
        // forgets which apps overflowed again.
        guard mayTry || trigger == .displaysChanged else { return }

        var proposed = sections
        let shown = mayTry && DotsRoom.mayHaveAVerdict(in: inventory) ? shownBars(of: inventory) : []
        let started = tracker.roomMayHaveReturned(trigger, sections: &proposed, predictedFits: { mayTry && predictedFits($0, shownBars: shown) },
                                                  now: clock.now())
        guard !started.isEmpty else { return }
        // What the apps said of where they were is what a place after the trial is told from.
        placesBeforeTrials.merge(OverflowInputs.strayPlaces(ofApps: started, in: inventory)) { _, new in new }
        let before = sections
        sections = proposed
        await saveIfChanged(from: before)
        await rebuildAndApply()
        await scheduler?.request(.trial)
    }

    /// Whether these apps, all on the bar at once, are predicted to have room on every bar: what they were last seen to take is no
    /// more than what is free of it (and, on a bar that is shown and has a dot of Mantel's out of the way, the room the dot needs too).
    /// False when any of them has never been seen, or the bars aren't known.
    private func predictedFits(_ apps: Set<String>, shownBars: Set<String>) -> Bool {
        var needed: CGFloat = 0
        for app in apps {
            guard let width = widths.width(ofApp: app, in: inventory) else { return false }
            needed += width
        }
        guard !inventory.bars.isEmpty else { return false }
        return inventory.bars.allSatisfy { bar in
            let menus = frontMenuFrames.filter { bar.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            let free = RoomEstimate.freeWidth(bar: bar, appMenusMaxX: menus.map(\.maxX).max(),
                                              visibleItemFrames: OverflowInputs.occupiedFrames(in: inventory, display: bar.displayUUID))
            // The dots that are out of the way on this bar need room on it too, if the bar is shown (what they were pushed out by is what
            // is on it).
            return free >= needed + DotsRoom.neededWidth(on: bar.displayUUID, in: inventory, widths: widths, shownBars: shownBars)
        }
    }

    // MARK: The plan

    private func runningBundleIDs() -> [String] {
        Array(Set(runningApps().compactMap(\.bundleID))).sorted()
    }

    private func buildPlan() -> VisibilityPlan {
        PlanBuilder.build(PlanInputs(
            ownBundleID: ownBundleID, runningBundleIDs: runningBundleIDs(), sections: sections, reveal: revealState.level,
            focusMode: revealState == .focusMode, allowHidingClockAndControlCenter: settings.allowHidingClockAndControlCenter,
            wideScreen: WideScreenInput(enabled: settings.showEverythingOnWideScreens, threshold: settings.wideScreenThreshold,
                                        activeScreenWidth: activeScreenWidth),
            swapConcealed: swapConcealed))
    }

    private func saveIfChanged(from before: SectionModel) async {
        guard sections != before else { return }
        await saveSections(sections)
    }

    /// Makes the plan from what is true now, and has it applied if it isn't the one that was asked for last. Returns when the plan, or
    /// a newer one, has been applied.
    private func rebuildAndApply(force: Bool = false) async {
        // After quitting has begun no plan reaches the engines: what is applied is what quitting takes down.
        guard !isQuitting else { return }
        let plan = buildPlan()
        currentPlan = plan
        if !force, plan == lastSubmitted {
            // It is the plan that is applied, or on its way.
            if isApplying { await withCheckedContinuation { applyWaiters.append($0) } }
        } else {
            await submit(plan, force: force)
        }
        publish()
    }

    /// Hands the plan to the engines. While another plan is being applied this one is only kept, in place of the one that was kept
    /// before it, and the call returns when the engines are done with whichever plan is the newest.
    ///
    /// The plans are applied by a task of the session's own (`drainPlans`), not by the task of whoever asked: a caller that is cancelled
    /// doesn't cut the engines short, and nothing it asked for, or what other callers merged into the plan after it, is dropped on the
    /// way (an engine whose activation is cancelled gives up on the plan, and the plan would be lost with it). Cancelling the caller
    /// doesn't end its wait, either: every caller waits until the engines have finished with the newest plan.
    private func submit(_ plan: VisibilityPlan, force: Bool) async {
        guard !isQuitting else { return }
        lastSubmitted = plan
        pendingApply = (plan, force || (pendingApply?.force ?? false))
        if !isApplying {
            isApplying = true
            Task { await self.drainPlans() }
        }
        await withCheckedContinuation { applyWaiters.append($0) }
    }

    /// Applies the pending plan, and the one that replaces it while it is applied, until there is none; then tells those who waited.
    private func drainPlans() async {
        while true {
            while let next = pendingApply {
                pendingApply = nil
                await hiding.apply(next.plan, force: next.force)
            }
            let status = await hiding.status()
            lastStatus = status
            // A plan an engine failed to apply is sent again when the next one is made, even if it is the same: the engine is tried again.
            if status.lastError != nil { lastSubmitted = nil }
            // A plan that came while the status was read is applied before anyone is told that the newest is.
            if pendingApply == nil { break }
        }
        isApplying = false
        lastApplyEndedAt = clock.now()
        let waiting = applyWaiters
        applyWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    // MARK: Publishing

    private func publish() {
        guard let lastStatus, let currentPlan else { return }
        let state = MenuBarState(
            inventory: inventory, sections: sections,
            lists: ReadOnlyLists.make(inventory: inventory, sections: sections, running: Set(runningBundleIDs()), turnedOff: turnedOffList),
            plan: currentPlan, engine: lastStatus, alwaysHiddenHasApps: alwaysHiddenHasApps())
        guard state != lastPublished else { return }
        lastPublished = state
        for continuation in subscribers.values { continuation.yield(state) }
    }

    /// Whether anything that is running is in Always Hidden, or a system item that can be put there is.
    private func alwaysHiddenHasApps() -> Bool {
        let running = Set(runningBundleIDs())
        if sections.apps.contains(where: { $0.value.section == .alwaysHidden && running.contains($0.key) }) { return true }
        return sections.systemItems.contains { module, section in
            guard section == .alwaysHidden, SystemItemTable.number(of: module) != nil else { return false }
            return !SystemItemTable.unmovable.contains(module) || settings.allowHidingClockAndControlCenter
        }
    }
}
