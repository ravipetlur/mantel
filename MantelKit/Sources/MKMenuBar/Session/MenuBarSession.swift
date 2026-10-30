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
    /// How wide each icon's slot was when it was last on the bar: what the second bar's cells and the layout editor's tokens are sized by.
    public let widths: ItemWidthCache
    /// The running apps whose icon macOS doesn't tie to them, so that the allowlist gives it no slot and hides it whenever anything is
    /// hidden (`UnattachedIconTracker`).
    public let unattachedApps: Set<String>
    /// What the layout writer is doing and has done; nil until a writer is set (`setLayout`).
    public let layout: LayoutStatus?
    /// The menu bar was left stuck by a change of displays and restarting MenuBarAgent didn't put it right (`StuckBarWatch`).
    public let stuckBarNotRecovered: Bool
    /// The icons each running app had in its last whole read in this run. The sections can hold more records of an app than it has icons
    /// (`SectionModel.staleRecords`): what lists icons shows these.
    public let currentIDs: [String: Set<ItemID>]

    public init(inventory: Inventory, sections: SectionModel, lists: ReadOnlyLists, plan: VisibilityPlan, engine: EngineStatus,
                alwaysHiddenHasApps: Bool, widths: ItemWidthCache = ItemWidthCache(), unattachedApps: Set<String> = [],
                layout: LayoutStatus? = nil, stuckBarNotRecovered: Bool = false, currentIDs: [String: Set<ItemID>] = [:]) {
        self.inventory = inventory
        self.sections = sections
        self.lists = lists
        self.plan = plan
        self.engine = engine
        self.alwaysHiddenHasApps = alwaysHiddenHasApps
        self.widths = widths
        self.unattachedApps = unattachedApps
        self.layout = layout
        self.stuckBarNotRecovered = stuckBarNotRecovered
        self.currentIDs = currentIDs
    }

    /// The records the places that list icons leave out.
    public var staleRecords: StaleRecords {
        sections.staleRecords(current: currentIDs, listed: inventory.items.map(\.id))
    }
}

/// What the session needs to restart MenuBarAgent by itself when a change of displays leaves the menu bar stuck (`StuckBarWatch`).
public struct StuckBarRecovery: Sendable {
    let restarter: any MenuBarAgentRestarting
    let activity: ResetActivity

    /// - Parameters:
    ///   - restarter: what Reset restarts MenuBarAgent with.
    ///   - activity: what a Reset sets: only one of a Reset and a recovery is under way at a time.
    public init(restarter: any MenuBarAgentRestarting, activity: ResetActivity) {
        self.restarter = restarter
        self.activity = activity
    }
}

/// A reveal whose plan the engines have applied, and which has yet to be followed up (`MenuBarSession.followUp`).
public struct AppliedReveal: Sendable, Equatable {
    /// The state that was applied.
    public let state: RevealState
    /// Where the revealed icons are shown: on the bar, or in the second bar (which leaves the bar as the sections make it).
    public let presentation: RevealPresentation
    /// The number of changes of reveal the session had made when this one was applied. A later change makes this one stale.
    let generation: Int

    init(state: RevealState, presentation: RevealPresentation = .inline, generation: Int) {
        self.state = state
        self.presentation = presentation
        self.generation = generation
    }
}

/// What `MenuBarSession.revealIcons` gives back: the icons that were asked for and the room made for them end with it
/// (`endIconReveal`).
public struct IconRevealTicket: Sendable, Hashable {
    let id: Int
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
/// - **A reveal is shown inline or in the second bar** (`RevealPresentation`). In the second bar the menu bar itself keeps what the
///   sections say: the plan is built with nothing revealed, and the session still holds the reveal state (for the dots, the machine and
///   the apps that are revealed). Reads taken then are judged as a collapsed bar's are. Its follow-up looks for nothing. An inline reveal
///   that turns out not to fit is answered with `NoRoomAction.openSecondBar`, which corrects the prediction (`predictedFits(_:)`).
/// - **Refresh, reset and auto-refresh** are in `refresh()`, `reset(restarter:replayJournal:)` and `scan`: a refresh applies the plan
///   again whether or not it is the one that was applied, a reset takes everything down and restarts the menu bar's process, and the
///   session refreshes by itself (each time logged) when the agent hasn't answered three reads in a row, at most four times in an
///   outage and each after a longer wait, or when a display change left a bar empty (`AutoRefreshPolicy`). It doesn't while the displays
///   are asleep, the screen is locked or another user's session is on screen (`SessionState`); a refresh that is asked for is never held.
/// - **An icon macOS doesn't tie to its app** gets no slot while the allowlist is live. Every read goes to `UnattachedIconTracker`, which
///   flags a running Shown app whose icon has none in two reads 10 seconds apart, with an assertion live through both and the rest of the bar
///   drawn (`UnattachedIcons`); Automatic then uses the System Settings switches while such an app is in Shown. A bar that is stuck
///   after a lid cycle looks the same, so a read of one, a change of displays and a wake each start every run again, and an app that
///   had a slot before a change isn't flagged until it has one again or is started again. A manual refresh and a reset forget the flags,
///   an auto-refresh doesn't.
/// - **A bar a change of displays left stuck** (`StuckBarWatch`): two or more apps, or one of Mantel's own items, that had a slot in the
///   last read before a change (a slot, or out of the way behind the notch: `StuckBar.appsPlaced`) and have none after it, with room for
///   them, on two reads at least 5 seconds apart and 10 seconds or more after the change, have MenuBarAgent restarted, once for that
///   change and 3 times an hour at most; never while a reset, a layout write, quitting, the lock screen or sleep is in
///   the way. One app alone with Mantel's dots drawn is never restarted by itself: a read can't tell it from an app that is switched off
///   in System Settings, and the person's Reset covers it. It is a reset's restart (`runReset`) without the hiding being taken down or
///   the journal replayed: the person's hiding and layout stay. An app that had no slot in the last read before the change, one that is
///   flagged or one that is turned off in System Settings is never a reason (the list is read again just before; Mantel's own items
///   aren't looked at while Mantel is turned off), and when what is left after that isn't the shape, nothing is decided again until the
///   next change. The tracker forgets what it knew as on a reset, and the flags are held back until a read finds the bar whole. A
///   restart that didn't help is said in the log once and in Diagnostics, and no other is made until the bar is seen whole or a reset is
///   done.
/// - **The layout** (`MenuBarSession+Layout.swift`): the person's changes ask `LayoutApplier` to write macOS's order table, which runs on a
///   task of its own. The session is pending from before it asks until the applier says verification is over, and settling from the write
///   until then (`setLayoutPhase`): a read taken then follows nothing (a drop waits to be written), judges nothing, and no picture is taken.
///   Every other read follows the order macOS shows, and what the follower finds is never written back.
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
    /// The most that writing a change of the order that is still in its debounce waits for at quit: it must fit in the quit timer.
    static let quitLayoutLimit: Duration = .milliseconds(500)
    static let quitStillBusyLogLine = "the hiding method was still busy at quit; macOS releases its hold shortly after Mantel quits"
    static let couldNotLookLogLine = "the reveal couldn't be confirmed on the bar (Device control and data access, MenuBarAgent or its window didn't answer); going on"

    /// What the log says when a reveal isn't seen on the bar within the wait: how many icons were there of how many there should be.
    /// Counts only: nothing here names an app.
    static func notSeenLogLine(drawn: Int, expected: Int) -> String {
        "the reveal wasn't seen on the bar within the wait (\(drawn) of \(expected) icons on the main bar); going on"
    }

    let scanner: MenuBarScanner
    private let hiding: HidingController
    let runningApps: @Sendable () -> [RunningApp]
    private let loadSections: @Sendable () async -> SectionModel
    private let saveSections: @Sendable (SectionModel) async -> Void
    private let turnedOff: @Sendable () async -> TurnedOffList
    let ownBundleID: String
    let clock: any Clock
    let confirmationWait: Duration
    /// The windows on screen, which say whether a display's bar is shown (`BarVisibility`). Read only when a read of the menu bar has a «.
    let windows: any WindowListReading

    private var settings: HidingSettings
    /// Where everything is. (Readable by the tests of the session.)
    private(set) var sections = SectionModel()
    private(set) var inventory = Inventory.empty
    /// The apps the scanner was told not to believe the places of when `inventory` was read (`appsNotDrawn()` then): it was read under
    /// that plan, whatever the plan in force is by now.
    private(set) var concealedAtRead: Set<String> = []
    private(set) var widths = ItemWidthCache()
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
    private(set) var turnedOffList: TurnedOffList = .apps([])
    /// Which running Shown apps have an icon macOS doesn't tie to the app (`UnattachedIcons`). An app that hides its own icon lists none,
    /// so a sighting is needed only while the list of the apps macOS has turned off can't be read. (Readable by the tests of the session.)
    private(set) var unattached = UnattachedIconTracker(sighting: .whileTurnedOffIsUnknown)
    /// The apps the engine chooser was last told have such an icon and are in Shown (`UnattachedIconTracker.forAutomatic`).
    private var toldAutomatic: Set<String> = []
    /// When the displays last changed: a read that began before it is of a bar that is being made again.
    private(set) var lastDisplayChangeAt: Date?
    /// Whether a bar that a change of displays left stuck is restarted, and why it hasn't been put right (`StuckBarWatch`).
    private(set) var stuckWatch = StuckBarWatch()
    /// What restarts MenuBarAgent for a stuck bar; nil restarts nothing.
    private var stuckRecovery: StuckBarRecovery?
    /// A recovery of a stuck bar has begun and isn't over: a second one isn't begun.
    private(set) var recoveryUnderWay = false
    /// How many recoveries of a stuck bar the watch has decided on, begun or not. (Readable by the tests of the session.)
    private(set) var stuckRecoveriesDecided = 0
    /// Bumped by a change of displays, a wake and a reset: a recovery decided before one is of a bar that was made again since.
    private var stuckBarStamp = 0
    /// How icons are hidden and why, as of the last time the engines were asked or switched.
    private var lastStatus: EngineStatus?

    var revealState: RevealState = .collapsed
    /// Whether the reveal that is in force is shown in the second bar and not on the menu bar. Always `.inline` while nothing is revealed.
    var revealPresentation: RevealPresentation = .inline
    /// Bumped by every `applyReveal` and `collapseReveal`, so that a follow-up that is under way knows it has been overtaken.
    var revealGeneration = 0
    /// The Shown apps that are concealed to make room for a reveal. Cleared by every `applyReveal` and `collapseReveal`: a swap lasts as long as its reveal.
    var swapConcealed: Set<String> = []

    // Icons asked for (`MenuBarSession+Icons.swift`).
    /// The icons each ticket asked to have shown, by the ticket's number. A ticket ends with `endIconReveal`, a reset or the quit.
    var iconTickets: [Int: Set<ItemID>] = [:]
    /// The Shown apps concealed to make room for each ticket's icons, by the ticket's number: they come back when the ticket ends.
    var iconRoomByTicket: [Int: Set<String>] = [:]
    var nextIconTicket = 0
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

    // Which icons an app has (`MenuBarSession+Records.swift`).
    /// What tells which apps a read names the icons of for certain.
    var wholeReads = WholeReads()
    /// The icons of each running app's last whole read in this run: its other records in the sections are of icons that aren't there now.
    /// An app that quits has none.
    var currentIDs: [String: Set<ItemID>] = [:]
    /// What the app does with the settings of the icons whose records a check of an app's saved icons took out: it is asked once for
    /// each app, and says what it moved and left. Set when the session is made.
    let recordsChecked: @Sendable (String, SectionModel.Reconciled) async -> SettingsMoved
    /// The task that moves those settings and says so in the log; the session doesn't wait on it. The next one starts when it is done, so
    /// that the moves are made in the order the checks were.
    var settingsMoves: Task<Void, Never>?

    private var scheduler: ScanScheduler?
    private var periodicTask: Task<Void, Never>?
    private(set) var isStarted = false
    /// Whether `start()` is still reading the menu bar for the first time: the reads it makes are the launch's, taken before macOS has
    /// placed Mantel's own icons (the dots).
    private(set) var isReadingAtLaunch = false
    /// When `start()` began, and whether a read has had Mantel's dots on a bar since (`DotsRoom.dotsArePlaced`): until one has, or
    /// `dotsPlacementWait` has gone by, where a dot has no place isn't said in the log (`dotsHaveHadTheirPlaces`).
    private var launchBeganAt: Date?
    private var dotsHavePlaced = false
    /// How long after the launch a dot that macOS hasn't placed is said to have no place all the same: it may never be placed.
    static let dotsPlacementWait: Duration = .seconds(60)

    // Capturing the icons (`MenuBarSession+Capture.swift`).
    /// What takes the pictures of the icons at the moments that call for them; nil takes none.
    var imageCollector: ItemImageCollector?
    /// Whether the launch's capture has been made: it is made once, by the first read that has a bar.
    var launchCaptureDone = false
    /// Whether a recapture is under way: a second one is turned away.
    var isRecapturing = false
    /// Whether the log has said that the recording indicator is ignored for a while after a capture.
    var indicatorQuietLogged = false
    /// How many times a capture that is taken from a read of its own is taken when the bar changes under it (`captureForSettings`).
    var captureTries = 3
    /// How long a plan is given to be drawn after the engines have applied it, before a capture reads the bar: the platform check found the
    /// apps a plan asks for drawn within 452 ms (`ClickRouteRules.drawnWait`), so this is a little more.
    var barDrawnWait: Duration = .milliseconds(500)
    /// Bumped whenever the bar is changed (a plan is handed to the engines and when they are done with it, the engine is switched, a
    /// reset or the quit takes the engines down). A read, and the pictures taken from it, are of the bar as it was when this was what
    /// it is now (`TakenRead`): a picture isn't kept when it has moved since.
    var barChanges = 0
    /// What the last of those was, in words for the log (`noteBarChange`): what a check that found the count moved says Mantel did.
    private(set) var lastBarChange = "nothing"
    /// The apps the plan before the one in force concealed, when the two differ: they have just been drawn again, and don't say which
    /// display is active.
    var concealedBeforeThePlan: Set<String> = []
    /// The captures that run on a task of their own, by number; each takes itself out when it is done.
    var captureTasks: [Int: Task<Void, Never>] = [:]
    var nextCaptureTask = 0

    // The layout writer (`MenuBarSession+Layout.swift`).
    /// What writes macOS's order table; nil leaves the order to the person's ⌘-drags and writes nothing.
    var layoutApplier: LayoutApplier?
    var layoutRules = LayoutRules.unmeasured
    var layoutSettings = LayoutSettings()
    var layoutDots = DotSettings()
    /// The applier says a write is pending and its verification isn't over: nothing follows the table or the bar.
    var layoutPending = false
    /// How many requests the session has begun and the applier hasn't taken yet: the session is pending from before it asks.
    var layoutRequestsInFlight = 0
    /// The revision of the last request the applier took (`LayoutApplier.request` answers it), and the newest revision its phase
    /// callbacks have told: a request newer than the phase told keeps the session pending, whatever order the two arrive in.
    var layoutRequestedRevision = 0
    var layoutPhaseRevision = 0
    /// What a request was for when it wasn't sent because the layout file can't be written (not granted, or reordering is off), or the
    /// last read had no bars: it is sent again, with the arrangement as it is then, when that changes, or with the next read that has bars.
    var layoutDeferredCause: LayoutChangeCause?
    /// A ⌘-drag's follow was refused because a write was pending or settling: it is taken when that ends.
    var layoutFollowWaits = false
    /// The bar is being re-sorted by a write or a restore: nothing is judged or captured.
    var layoutSettling = false
    /// The keys the resolver matched by distance, for the next resolution: the report of each write brings the new ones back.
    var layoutMemory: [ItemID: String] = [:]
    /// The items no key was found for at the last resolution: what the lists show as not reorderable.
    var layoutUnresolved: [ItemID] = []
    var layoutStatus: LayoutStatus?
    var layoutStatusTask: Task<Void, Never>?
    /// The order macOS showed when the ⌘-drag began: what the read that follows the drag compares with.
    var dragBefore: ObservedOrder?
    /// How the follow of the ⌘-drag that is being followed went, as `followedSections` found it; nil until a read has been judged.
    var dragFollow: CommandDragLog.Follow?
    /// The ⌘-drag whose follow is under way or waiting. For the line that says how the follow ended.
    var dragDrop: DragDrop?
    /// How many ⌘-drags have ended: each is told apart from the next by it (`DragDrop.number`).
    var dragsEnded = 0

    struct DragDrop: Equatable {
        /// Which drag it is: a follow a write deferred ends by this, and writes its line only if the drag is still the one it was taken for.
        let number: Int
        /// When the mouse went up, as the monitor saw it (or, with no mouse-up seen, when the drag was taken as ended).
        let dropped: Date
        /// When the session began the follow's wait.
        let begun: Date
        let end: CommandDragLog.End
    }
    /// Which reads are whole enough for the order to be followed from them, and whether the last one that would have been followed wasn't.
    var followTrust = FollowTrust()
    /// The order table as it was last read, and when: it is read at most every two seconds.
    var tableRead: (at: Date, table: LayoutTableSnapshot)?
    /// The report of the last write the session has taken in.
    var lastTakenReport: LayoutWriteReport?

    /// Whether a reset is under way. Set before the reset awaits anything, so that a second one finds it set.
    private(set) var resetting = false
    /// Set when quitting begins: no plan is applied and nothing is read from then on.
    private(set) var isQuitting = false
    private var autoRefresh = AutoRefreshPolicy()
    /// The displays, as the session was last told they are (`displaysChanged`).
    private var knownDisplays: Set<String> = []
    /// The displays that had a bar, or slots, in the last read the agent answered while refreshing wasn't held back: only a display that
    /// had one can be left with none.
    private var displaysWithABar: Set<String> = []

    // What holds auto-refresh back while nobody is looking at the menu bar (the displays asleep, the screen locked, another user's session
    // on screen).
    /// Where the state of the session comes from.
    private let sessionState: any SessionStateSource
    /// The state of the session as the session was last told. Auto-refresh is held back unless it is awake. (Readable by the tests of the
    /// session.)
    private(set) var sessionNow: SessionState = .awake
    /// What passes the changes of `sessionState` on to `sessionChanged`. Ended by quitting.
    private var sessionTask: Task<Void, Never>?
    /// What the log has said about auto-refresh, the last hundred lines: each refresh, and the state of the session going from awake to
    /// held back and back. (Readable by the tests of the session.)
    private(set) var autoRefreshLogLines: [String] = []

    // The plan that is applied, and the one that is asked for.
    private(set) var currentPlan: VisibilityPlan?
    /// The plan that was asked for last. (Readable by the tests of the session.)
    private(set) var lastSubmitted: VisibilityPlan?
    private var pendingApply: (plan: VisibilityPlan, force: Bool)?
    private var isApplying = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []

    /// A read, and how many times the bar had been changed (`barChanges`) when it began.
    struct TakenRead {
        let inventory: Inventory
        let barChanges: Int
        /// The apps the scanner was told not to believe the places of when it read.
        var concealed: Set<String> = []
        /// The process MenuBarAgent had when the read began; nil when it wasn't known. A bar that MenuBarAgent has drawn again since isn't
        /// the one the read was of (`isStillCurrent`).
        var agentPID: pid_t?
        /// The order of the icons wasn't followed from this read because it was empty or partial (`FollowTrust`): a drag's follow reads
        /// again. It is the verdict of this read, and not of the one that came last.
        var followNeedsAnotherRead = false
    }

    // Reads that someone waits for.
    private struct ScanTicket {
        /// The read that answers is one that began at this moment or later.
        let since: Date
        /// When set, only a read taken for this reason answers (a ⌘-drag's follow: a scan whose reasons were fixed before it was asked for
        /// can't).
        var needs: ScanScheduler.Reason?
        var result: TakenRead?
        var isDone = false
        var continuation: CheckedContinuation<TakenRead?, Never>?
    }
    private var tickets: [Int: ScanTicket] = [:]
    private var nextTicketID = 0
    /// How many reads someone is waiting for. For tests.
    var readsWaitedFor: Int { tickets.count }
    /// How many reads have been through `ingest`. For tests.
    private(set) var scansIngested = 0
    /// How long the last read took, retries included, on the session's clock: what the checks that follow a read (a strip's) take about as
    /// long as (`CaptureRules.launchBudget(forShownBars:readTook:)`).
    private(set) var lastReadTook: TimeInterval = 0
    /// How many refreshes the auto-refresh policy has started: counted when a read is taken in, so a test that has seen the read knows.
    /// For tests.
    private(set) var autoRefreshesStarted = 0
    /// Whether `start` has set the bar's polling and the minute's check for room going: both are set in the same stretch as the call
    /// that starts them, so a test that has seen `start` return knows. For tests.
    var isPollingTheBar: Bool { get async { await scheduler?.isPolling ?? false } }
    var checksForRoomEveryMinute: Bool { periodicTask != nil }

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
    ///   - sessionState: whether the displays are asleep, the screen is locked or another user's session is on screen, which hold
    ///     auto-refresh back. Steady (always awake) unless the app gives the system's.
    ///   - recordsChecked: what moves the settings (shortcuts, names) of the icons whose records the check of an app's saved icons took
    ///     out. It moves nothing unless the app gives it.
    public init(scanner: MenuBarScanner, hiding: HidingController, runningApps: @escaping @Sendable () -> [RunningApp],
                loadSections: @escaping @Sendable () async -> SectionModel,
                saveSections: @escaping @Sendable (SectionModel) async -> Void,
                turnedOff: @escaping @Sendable () async -> TurnedOffList,
                settings: HidingSettings, ownBundleID: String, clock: any Clock, windows: any WindowListReading,
                confirmationWait: Duration = .seconds(2), sessionState: any SessionStateSource = SteadySessionState(),
                recordsChecked: @escaping @Sendable (String, SectionModel.Reconciled) async -> SettingsMoved = { _, _ in SettingsMoved() }) {
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
        self.sessionState = sessionState
        self.recordsChecked = recordsChecked
    }

    deinit {
        periodicTask?.cancel()
        sessionTask?.cancel()
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
        isReadingAtLaunch = true
        launchBeganAt = clock.now()
        startWatchingTheSession()
        knownLayout = await scanner.currentLayout()
        sections = await loadSections()
        revealState = .collapsed
        await chooseEngine()
        await readTurnedOffList()

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
        isReadingAtLaunch = false
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
        unattached.displaysAreChanging()
        lastDisplayChangeAt = clock.now()
        stuckBarChangeHappened()
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

    // MARK: While nobody is looking

    /// Takes the state of the session, says in the log that auto-refresh is held back if it is, and has the changes that come passed on
    /// to `sessionChanged`. The changes are asked for before the state, so that none falls between the two.
    private func startWatchingTheSession() {
        guard !isQuitting else { return }
        let changes = sessionState.changes()
        sessionNow = sessionState.current()
        if let reason = sessionNow.pauseReason { sayAboutAutoRefresh("auto-refresh paused: \(reason)") }
        sessionTask = Task { [weak self] in
            for await change in changes {
                await self?.sessionChanged(change)
            }
        }
    }

    /// The displays went to sleep or woke, the screen was locked or unlocked, this user's session left the screen or came back, or the
    /// Mac woke.
    ///
    /// - The log says once when auto-refresh goes from running to held back, and once when it goes back: never for a change that leaves it
    ///   as it was (the screen locks while the displays are asleep).
    /// - What auto-refresh has counted starts over (`AutoRefreshPolicy.woke`) when the Mac wakes, and when it goes from held back to
    ///   running (the screen unlocked, this session on screen again, the displays on): whichever of the notifications comes first, and
    ///   whether or not the others come at all.
    ///
    /// Nothing is read or refreshed because of it: the reads go on as they were, and the next one is judged.
    public func sessionChanged(_ change: SessionChange) async {
        guard !isQuitting else { return }
        let before = sessionNow
        sessionNow = before.applying(change)
        if before.isAwake != sessionNow.isAwake {
            sayAboutAutoRefresh(sessionNow.pauseReason.map { "auto-refresh paused: \($0)" } ?? "auto-refresh resumed")
        }
        if change == .systemWoke || (!before.isAwake && sessionNow.isAwake) {
            autoRefresh.woke()
            // A run of reads can't span a sleep or the lock screen: the bar may be made again as it wakes.
            unattached.displaysAreChanging()
            stuckBarChangeHappened()
        }
    }

    /// Writes a line about auto-refresh in the log, and keeps it for the tests of the session.
    private func sayAboutAutoRefresh(_ line: String) {
        Log.info("session", line)
        autoRefreshLogLines.append(line)
        if autoRefreshLogLines.count > 100 { autoRefreshLogLines.removeFirst(autoRefreshLogLines.count - 100) }
    }

    // MARK: Revealing

    /// Shows what the state shows, or hides it again, and says what is left to do about icons that have no room: `applyReveal`, then
    /// `followUp`.
    public func setReveal(_ state: RevealState, presentation: RevealPresentation = .inline) async -> NoRoomAction {
        await followUp(applyReveal(state, presentation: presentation))
    }

    /// Puts the plan for the state on the bar and returns, whatever the state is. It does nothing else: nothing is looked for and
    /// nothing is read, so this takes as long as the engines do, and a change that comes after it can be applied at once.
    ///
    /// With `.secondBar` the plan is the one for nothing revealed: the icons are shown in the second bar, and the menu bar is left as
    /// the sections make it. The state is kept all the same (the dots, the machine and the apps that are revealed go by it). A state
    /// that reveals nothing (a collapse, Focus Mode) has no second bar, and is applied as it always is.
    ///
    /// It ends any follow-up that is under way for an earlier change: that one is stale from here on.
    public func applyReveal(_ state: RevealState, presentation: RevealPresentation = .inline) async -> AppliedReveal {
        revealGeneration += 1
        let generation = revealGeneration
        revealState = state
        revealPresentation = state.level == .off ? .inline : presentation
        swapConcealed = []
        await rebuildAndApply()
        return AppliedReveal(state: state, presentation: revealPresentation, generation: generation)
    }

    /// What follows a reveal that was applied: the bar is looked at every 250 ms until it has a place for every revealed icon, or the
    /// look can't tell (nothing to look with, or a read timed out: waiting wouldn't help, so the wait ends at once), or the confirmation
    /// wait is over (never a failure: not seeing the icons is logged, and the session goes on), and then the whole menu bar is read.
    /// If revealed icons are piled up in the « overflow, the person's no-room policy decides: the session itself makes room by concealing
    /// Shown apps, right-most first, and reads again, up to three times (`SwapCalculator.maximumRounds`); what is left for the app comes
    /// back as the answer, which is never `.swap`.
    ///
    /// When the look saw the revealed icons on the bar, the pictures of them are taken (`captureRevealed`), on a task of its own, from the
    /// read after which no more room is made.
    ///
    /// A follow-up that is overtaken by a newer change of reveal stops, wherever it is, and answers `.none`. A collapse has nothing to
    /// follow up, and neither has a reveal that is shown in the second bar: the menu bar isn't asked to hold the icons, so nothing is
    /// looked for. An inline reveal that finds icons without room answers `.openSecondBar` when that is the person's choice (the
    /// prediction that they would fit was wrong).
    public func followUp(_ applied: AppliedReveal) async -> NoRoomAction {
        let generation = applied.generation
        guard generation == revealGeneration, !isQuitting, applied.presentation == .inline else { return .none }

        let revealed = revealedApps()
        guard !revealed.isEmpty else { return .none }
        let verdict = await confirmReveal(generation: generation)
        return await settleRoom(for: revealed, generation: generation, menuBarTakenOver: false, capturing: verdict == .seen)
    }

    /// The app has made room itself (it took the menu bar over): the menu bar is read, and what is left to do is answered as at the end of
    /// `setReveal`, knowing that it has. (Should the policy be to swap, the swap is made here too: the answer is never `.swap`.)
    public func recheckRoom(menuBarTakenOver: Bool) async -> NoRoomAction {
        let revealed = revealedApps()
        guard !revealed.isEmpty, revealPresentation == .inline else { return .none }
        return await settleRoom(for: revealed, generation: revealGeneration, menuBarTakenOver: menuBarTakenOver)
    }

    /// Reads the bar and answers what is left to do about the revealed apps that have no room, making room itself where the policy is
    /// to swap: Shown apps are concealed, the bar is read again, and so on up to the most rounds there are. Stops, answering `.none`,
    /// when another reveal has overtaken this one.
    private func settleRoom(for revealed: Set<String>, generation: Int, menuBarTakenOver: Bool, capturing: Bool = false) async -> NoRoomAction {
        var round = 0
        while generation == revealGeneration {
            guard let taken = await requestRead(.reveal), generation == revealGeneration else { return .none }
            let read = taken.inventory
            let check = roomCheck(revealed: revealed, in: read, round: round)
            let action = decide(check, menuBarTakenOver: menuBarTakenOver)
            // The pictures are of the read after which no more room is made: before that the icons are still moving. Where the swap
            // made room, it is the last round's.
            guard case .swap = action else {
                if capturing { startCapturingRevealed(revealed, taken: taken, generation: generation) }
                return action
            }

            let concealed = appsToConceal(forRevealed: check.overflowedRevealedApps, in: read)
            guard !concealed.subtracting(swapConcealed).isEmpty else {
                // Every Shown app there is has been tried: nothing more can be made.
                if capturing { startCapturingRevealed(revealed, taken: taken, generation: generation) }
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
    /// (Grouped apps are in Always Hidden, so only a reveal of everything shows them.)
    private func revealedApps() -> Set<String> {
        revealedApps(at: revealState.level)
    }

    private func revealedApps(at level: RevealLevel) -> Set<String> {
        let shown: Set<MenuBarSection> = switch level {
        case .off: []
        case .hidden: [.hidden]
        case .all: [.hidden, .alwaysHidden]
        }
        guard !shown.isEmpty else { return [] }
        let running = Set(runningBundleIDs())
        return Set(inventory.appsWithItems.filter { running.contains($0) && shown.contains(sections.section(ofApp: $0)) })
    }

    /// What a look at the bar makes of a reveal.
    enum BarVerdict: Equatable {
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
    ///
    /// Says what the last look made of it: `.seen`, `.notYet` when the wait ran out, `.cantTell` when the look couldn't tell, and also
    /// when another change of reveal overtook this one, even during its last look (the reveal is over, and nothing was seen).
    @discardableResult
    func confirmReveal(generation: Int, wait limit: Duration? = nil) async -> BarVerdict {
        let started = clock.now()
        let limit = limit ?? confirmationWait
        let wait = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        while generation == revealGeneration {
            let verdict = await lookForReveal()
            switch verdict {
            case .seen:
                return generation == revealGeneration ? verdict : .cantTell
            case .cantTell:
                if generation == revealGeneration, !couldNotLookLogged {
                    couldNotLookLogged = true
                    Log.info("session", Self.couldNotLookLogLine)
                }
                return verdict
            case .notYet(let drawn, let expected):
                guard clock.now().timeIntervalSince(started) < wait else {
                    if generation == revealGeneration { Log.info("session", Self.notSeenLogLine(drawn: drawn, expected: expected)) }
                    return verdict
                }
                do { try await clock.sleep(for: Self.confirmationInterval) } catch { return .cantTell }
            }
        }
        return .cantTell
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
        case .none, .swap, .takeOverMenuBar, .openSecondBar:
            break
        }
        return action
    }

    /// The Shown apps to conceal to make room for the revealed apps that have none, on each display that is short of room: the
    /// right-most first, until what they draw is as wide as what the revealed apps need there.
    ///
    /// Only apps that are in the Shown section are candidates, and only those that are on that display's bar now: an app that is
    /// visible for another reason (a rule, a wide screen, or because it is revealed) isn't Shown, and isn't concealed to make room.
    func appsToConceal(forRevealed overflowed: Set<String>, in read: Inventory, alreadyConcealed: Set<String>? = nil) -> Set<String> {
        let alreadyConcealed = alreadyConcealed ?? swapConcealed
        var concealed: Set<String> = []
        for bar in read.bars {
            let display = bar.displayUUID
            let short = overflowed.filter { app in read.items(ofApp: app).contains { $0.overflowedOn.contains(display) } }
            guard !short.isEmpty else { continue }
            let needed = short.reduce(into: CGFloat.zero) { $0 += widths.width(ofApp: $1, in: read) ?? 0 }

            var candidates: [(bundleID: String, right: CGFloat, width: CGFloat)] = []
            for app in read.appsWithItems where sections.section(ofApp: app) == .shown && !alreadyConcealed.contains(app) {
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

    // MARK: The second bar

    /// Whether the icons that the state would reveal are predicted to fit on the menu bar beside what is drawn there now: the answer
    /// `RevealPresentationPolicy` goes by. It is made from what the session already knows (the widths icons had when they were last on
    /// the bar, the last read and the front app's menus), so it takes no read of the bar and asks nothing of Accessibility; the one thing
    /// it asks for is the window list, which says which bars are shown. True when the state reveals nothing.
    ///
    /// Apps that macOS has turned off are left out: they take no room. An app whose width isn't known counts as fitting, and the
    /// follow-up of the reveal corrects the prediction (`RoomPrediction`).
    public func predictedFits(_ state: RevealState) async -> Bool {
        let off: Set<String> = if case .apps(let bundleIDs) = turnedOffList { Set(bundleIDs) } else { [] }
        let apps = revealedApps(at: state.level).subtracting(off)
        guard !apps.isEmpty, !inventory.bars.isEmpty else { return true }
        return RoomPrediction.fits(apps, inventory: inventory, widths: widths, menuFrames: frontMenuFrames,
                                   shownBars: shownBars(of: inventory))
    }

    /// The reveal the plan is built with. A reveal that is shown in the second bar leaves the menu bar as the sections make it.
    private var revealLevelOnTheBar: RevealLevel {
        revealPresentation == .secondBar ? .off : revealState.level
    }

    /// Whether the menu bar is as the sections make it, so that what a read of it finds is a verdict on them: nothing is revealed, or the
    /// reveal is in the second bar. (Focus Mode, and a reveal on the bar, change the bar for a reason of their own.)
    private var barIsCollapsed: Bool {
        revealState == .collapsed || revealPresentation == .secondBar
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
        await editSections(.person) { $0.move(item: item, to: section) }
    }

    /// The person moves an app to a section.
    public func move(app bundleID: String, to section: MenuBarSection) async {
        await editSections(.person) { $0.move(app: bundleID, to: section) }
    }

    /// Where apps that are new go.
    public func setNewItemsSection(_ section: MenuBarSection) async {
        let before = sections
        sections.newItems = section
        await changedSections(from: before, by: .person)
    }

    /// Drops what is known of an app. It is placed again, in the new-items section, if it is seen again.
    public func forget(app bundleID: String) async {
        let before = sections
        sections.forget(app: bundleID)
        await changedSections(from: before, by: .person)
    }

    private func changedSections(from before: SectionModel, by cause: SectionChangeLog.Cause) async {
        await saveIfChanged(from: before, by: cause)
        await rebuildAndApply()
        await tellAutomaticIfChanged()
    }

    /// The person's change to the sections, as the layout API makes it: applied, saved and planned like any other, and, when it changed
    /// anything, written to macOS's order table (`cause`). The session is pending before the writer is asked, so that no read between
    /// them follows the order and puts the change back.
    func editSections(_ cause: LayoutChangeCause, _ change: (inout SectionModel) -> Void) async {
        let before = sections
        change(&sections)
        guard sections != before else { return }
        let began = beginLayoutRequest()
        await changedSections(from: before, by: .person)
        await sendLayoutRequest(cause, began: began)
    }

    /// Settings opened or closed: the menu bar is read every two seconds while it is open, and the list of apps macOS has turned off is
    /// read again when it opens. Opening it is a moment the Shown icons are captured at (`startCapturingForSettings`).
    public func setSettingsOpen(_ open: Bool) async {
        await scheduler?.setSettingsOpen(open)
        if open {
            await readTurnedOffList()
            await tellAutomaticIfChanged()
            publish()
            startCapturingForSettings()
        }
    }

    /// The person gave Mantel a file, or put back what is left in the system ("Replay now"): what depends on
    /// it is asked again. The list of apps macOS has turned off is read again, and the way of hiding is chosen again, which asks each
    /// engine whether it can be used now. A choice that comes out as before changes nothing (`HidingController.choose` switches only
    /// when the engine in charge is another one), so nothing flickers; one that now falls on another engine is a switch like any other.
    /// The state is published with the new reasons.
    ///
    /// Not before the session has started (its start asks both), not while a reset is under way, and not once quitting has begun: it
    /// does nothing then.
    public func permissionsChanged() async {
        guard isStarted, mayChangeEngines(forReset: false) else { return }
        await layoutAvailabilityChanged()
        await readTurnedOffList()
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
    /// so. Auto-refresh doesn't hold this back (the screen can be locked, and it still works), and doesn't count it as one of its own: only
    /// the read it makes can tell auto-refresh something, as any read does.
    @discardableResult
    public func refresh() async -> RefreshOutcome {
        // A manual refresh starts over from what is true, the icons macOS doesn't tie to their apps included (an app may have been fixed):
        // what was found is found again. What is known of a stuck bar is kept: only a reset restarts MenuBarAgent. Not one that is refused,
        // and not an auto-refresh, which goes by `refreshNow`.
        if mayChangeEngines(forReset: false) { unattached.forgetFlags() }
        // Whether the order table can be written is looked at again (the layout file may have been given, or have moved).
        await layoutAvailabilityChanged()
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
        await readTurnedOffList()
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
        noteBarChange("a reset began")
        // Step 1: no icon is asked for any more, and no room made for one is kept (the plan of step 6 is made without them).
        endAllIconReveals()
        // What waits to be applied is not applied after the engine is down (as at quit): the plan that is being applied is let finish.
        pendingApply = nil
        let outcome = await Task { await self.runReset(restarter: restarter, replayJournal: replayJournal) }.value
        resetting = false
        noteBarChange("a reset ended")
        try outcome.get()
    }

    private func runReset(restarter: any MenuBarAgentRestarting,
                          replayJournal: @escaping @Sendable () async -> Void) async -> Result<Void, RestartError> {
        Log.info("session", "resetting the menu bar")
        await hiding.tearDown()
        noteBarChange("the engine was taken down for a reset")
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
        unattached.forgetAll()
        stuckBarStamp += 1
        stuckWatch.resetDone()
        await refreshNow(forReset: true)
        return .success(())
    }

    /// The reveal is over: what was shown is put away, and a reveal that is under way is overtaken.
    private func collapseReveal() {
        revealGeneration += 1
        revealState = .collapsed
        revealPresentation = .inline
        swapConcealed = []
    }

    /// Reads the bar until the agent answers it, for up to `agentWait`: time on the clock from the start, so that the reads (each a scan,
    /// which takes seconds on a busy Mac) count, and a MenuBarAgent that doesn't come back is given up on after the wait and one read.
    private func waitForAgent() async {
        guard scheduler != nil else { return }
        let began = clock.now()
        let limit = Self.seconds(Self.agentWait)
        while !isQuitting {
            if let read = await requestScan(.refresh), read.agentAnswered { return }
            guard clock.now().timeIntervalSince(began) < limit else {
                let seconds = Self.agentWait.components.seconds
                Log.warning("session", "MenuBarAgent hadn't answered \(seconds) seconds after it restarted; going on")
                return
            }
            do { try await clock.sleep(for: Self.agentPollInterval) } catch { return }
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
        noteBarChange("the quit began")
        // Icons asked for end with the app: the engine's teardown shows everything, and what was concealed for room comes back with it.
        endAllIconReveals()
        pendingApply = nil
        periodicTask?.cancel()
        periodicTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        layoutStatusTask?.cancel()
        layoutStatusTask = nil
        layoutFollowWaits = false
        // Reads that are under way give up waiting for apps at once, so that none holds a thread or the main thread's turn while the app
        // takes itself down.
        scanner.stopWaiting()
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
        noteBarChange("the way of hiding was being chosen")
        // On a task of its own, as the plans are applied (`drainPlans`): the switch applies the plan with the new engine and then takes
        // the old one down, and a caller that is cancelled while it runs mustn't cut the new engine's activation short, which would leave
        // the old one taken down and the new one with nothing applied: a bar that is fully shown.
        // The epoch is read now, with the guard just passed: a teardown (a reset's, or the quit's) that comes before the call gets to the
        // controller makes it a choice of the time before, and it is dropped there.
        let hiding = hiding, method = settings.method, epoch = hiding.epoch
        let unattachedShown = unattached.forAutomatic(sections: sections)
        toldAutomatic = unattachedShown
        await Task { await hiding.choose(method: method, unattachedShownApps: unattachedShown, expectedEpoch: epoch) }.value
        switchesUnderway -= 1
        noteBarChange("the way of hiding was chosen")
        // Before the first plan was applied a switch has changed nothing on the bar, and the first read stays the one that judges nothing.
        if lastApplyEndedAt != nil { lastApplyEndedAt = clock.now() }
        lastStatus = await hiding.status()
    }

    // MARK: Reading the menu bar

    /// Asks for a read and waits for the one that answers it: one that began now or later.
    func requestScan(_ reason: ScanScheduler.Reason) async -> Inventory? {
        await requestRead(reason)?.inventory
    }

    /// The slots drawn on a display's bar now, from one window of MenuBarAgent's: no app is asked, and no inventory is made (the scanner
    /// may go on to read the window it used first next time). Nil when they can't be read. What a read's slots are compared with once a
    /// strip of the bar has been taken (`isStillCurrent`).
    func slotsNow(on display: String) async -> SlotSnapshot? {
        await scanner.slotSnapshot(on: display)
    }

    /// The frames these apps report for their items now: only these apps are asked, together, and nothing is learned. An app that doesn't
    /// answer is not in the answer. What a read's ties are compared with once a strip of the bar has been taken (`isStillCurrent`).
    func itemFramesNow(ofApps apps: Set<String>) async -> [String: [CGRect]] {
        await scanner.itemFrames(ofApps: apps)
    }

    /// `requestScan`, with what the bar had been through when the read began.
    func requestRead(_ reason: ScanScheduler.Reason) async -> TakenRead? {
        guard let scheduler, !isQuitting else { return nil }
        let id = nextTicketID
        nextTicketID += 1
        // The ticket is out before the request is made: a read that is quick can be over before this call is back.
        tickets[id] = ScanTicket(since: clock.now(), needs: reason == .layoutFollow ? reason : nil)
        await scheduler.request(reason)
        return await answer(of: id)
    }

    private func answer(of id: Int) async -> TakenRead? {
        guard let ticket = tickets[id] else { return nil }
        if ticket.isDone {
            tickets[id] = nil
            return ticket.result
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TakenRead?, Never>) in
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
        let changesBefore = barChanges
        // Whether the allowlist is live is looked at on both sides of the read: only one that is live throughout says an icon has no slot.
        let armedBefore = hiding.allowlist?.isArmed ?? false
        let concealed = appsNotDrawn()
        let began = clock.now()
        let agentPID = await scanner.menuBarAgentPID()
        let raw = await scanner.scan(reasons: reasons, concealed: concealed, notVoting: concealedBeforeThePlan)
        lastReadTook = max(0, clock.now().timeIntervalSince(began))
        let armedAfter = hiding.allowlist?.isArmed ?? false
        let (read, followNeedsAnotherRead) = await ingest(raw, afterDisplayChange: reasons.contains(.displaysChanged), atLaunch: isReadingAtLaunch,
                                                          armed: (before: armedBefore, after: armedAfter), reasons: reasons, concealed: concealed,
                                                          agentPID: agentPID)
        scansIngested += 1
        let taken = TakenRead(inventory: read, barChanges: changesBefore, concealed: concealed, agentPID: agentPID,
                              followNeedsAnotherRead: followNeedsAnotherRead)
        for (id, ticket) in tickets where !ticket.isDone && read.capturedAt >= ticket.since && (ticket.needs.map(reasons.contains) ?? true) {
            if let continuation = ticket.continuation {
                tickets[id] = nil
                continuation.resume(returning: taken)
            } else {
                tickets[id]?.result = taken
                tickets[id]?.isDone = true
            }
        }
        considerRefreshing(after: read, reasons: reasons)
    }

    /// Asks the auto-refresh policy whether this read calls for a refresh, and starts one if it does. It isn't asked during a reset (the
    /// bar is empty for a moment then, and what is read says nothing of a bar that is stuck) or after quitting has begun. While the
    /// displays are asleep, the screen is locked or another user's session is on screen, the policy is told it may not refresh, and
    /// the read teaches nothing of which displays have a bar: it is of a bar nobody sees.
    ///
    /// The refresh is a task of its own: it asks for a read, and a read can't be taken while this one, which is what the scheduler is
    /// running, hasn't returned.
    private func considerRefreshing(after read: Inventory, reasons: Set<ScanScheduler.Reason>) {
        // A read that couldn't be taken because Accessibility isn't granted says nothing of any display.
        let canTell = !read.problems.contains(.accessibilityNotGranted)
        let hadABar = displaysWithABar
        // Not a read taken while nobody looks: the bar of a display that is asleep is empty, and the read that judges the display change
        // read in the meantime (`AutoRefreshPolicy`) has to be compared with the bars there were before it.
        if read.agentAnswered, canTell, sessionNow.isAwake {
            displaysWithABar = Set(read.bars.map(\.displayUUID)).union(read.displaysWithSlots)
        }
        guard !resetting, !isQuitting else { return }
        // Only a display that had a bar in the read before can be left with an empty one: with "Displays have separate Spaces" off the
        // other displays have none at all, and a display change brings them without it being a bar that went empty.
        let displays = canTell ? knownDisplays.intersection(hadABar) : []
        let verdict = autoRefresh.scanFinished(agentAnswered: read.agentAnswered, displaysWithSlots: read.displaysWithSlots,
                                               displays: displays, afterDisplayChange: reasons.contains(.displaysChanged),
                                               mayRefresh: sessionNow.isAwake, now: clock.now())
        guard case .refresh(let reason) = verdict else { return }
        sayAboutAutoRefresh("refreshing the menu bar: \(reason)")
        autoRefreshesStarted += 1
        Task { await self.refreshNow() }
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
    ///   not said in the log: the next read says it, if it agrees. So are the reads of the launch (`atLaunch`): macOS may not have placed
    ///   the dots yet.
    /// - **The order macOS shows is followed** (`followedSections`), before the icons that are new are listed: not while a write of the
    ///   order table is pending or settling, from the table when it is granted and can be matched, else from the bar. Sections change only
    ///   for the read that follows a ⌘-drag. Nothing that is followed is written back.
    /// - Apps that were never placed are put in the new-items section, and what changed is saved. Apps that appear while Mantel runs, with the
    ///   new-items marker placed, ask for a write of the order.
    /// - The plan is made again and applied if it is another one, and the state is published.
    /// - While the recording indicator is being ignored after a capture (`droppingTheIndicator`), it isn't in what is judged.
    ///
    /// Returns the read as it was taken in, with the icons that are out of the way marked (`BarRegion`): what is answered to whoever asked
    /// for it, and what everything else here reads; and whether the order of the icons wasn't followed from it because it was empty or
    /// partial (`FollowTrust`), which is the verdict of this read, taken at the moment it was made.
    private func ingest(_ taken: Inventory, afterDisplayChange: Bool = false, atLaunch: Bool = false,
                        armed: (before: Bool, after: Bool) = (false, false), reasons: Set<ScanScheduler.Reason> = [],
                        concealed: Set<String> = [], agentPID: pid_t? = nil) async -> (read: Inventory, followNeedsAnotherRead: Bool) {
        let raw = await droppingTheIndicator(from: taken)
        // Which bars are shown is looked at only when a read has something to say of a place or of the dots.
        var shown: Set<String>?
        if raw.items.contains(where: { !$0.strayFrames.isEmpty }) { shown = shownBars(of: raw) }
        let read = markingWhatIsOutOfTheWay(raw, shownBars: shown)
        inventory = read
        concealedAtRead = concealed
        // A read that says nothing of any bar (Accessibility isn't granted, MenuBarAgent isn't there) says nothing of the icons either.
        guard !read.bars.isEmpty else {
            // Quits are counted all the same, while MenuBarAgent is down.
            let unattachedChanges = noteUnattached(read, armed: armed, afterDisplayChange: afterDisplayChange, atLaunch: atLaunch)
            await rebuildAndApply()
            await settleUnattached(unattachedChanges)
            return (read, false)
        }
        // The pictures of the icons are taken at the first read that has a bar, while everything is on the bar, and before a plan hides any
        // of it: at the launch's, or, when the launch's reads had none and a plan that hides nothing was applied, the first that comes
        // after. It is bounded: past its budget the capture is left to finish, and the plan applies. The first read that has a bar and comes
        // after a plan has hidden icons (two empty reads at the launch can have the plan applied before any read with a bar) can't have
        // it: it is counted as lost, and the moments that follow (a reveal that is seen, Settings opening) take the pictures.
        if !launchCaptureDone, imageCollector != nil {
            if currentPlan?.concealsNothing ?? true {
                await captureAtLaunch(read, agentPID: agentPID)
            } else {
                launchCaptureDone = true
                Log.info("session", Self.launchCaptureLostLogLine)
            }
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

        // Every read is looked at for the dots' places, not only the ones that judge the bar.
        let dotsHavePlaces = dotsHaveHadTheirPlaces(in: read)
        // A change the person made while the last read had no bars is written from this one, which has them.
        await sendDeferredLayoutChange(after: read)

        let before = sections
        var changes = SectionChangeLog(from: before)
        let follow = await followedSections(in: read, reasons: reasons)
        // A change someone made while the follow was being worked out saved itself, and says so in its own line.
        changes.skip(to: sections)
        if let followed = follow.sections { sections = followed }
        changes.took(sections, by: reasons.contains(.layoutFollow) ? .commandDrag : .barOrder)
        let previousIDs = currentIDs
        let wholeApps = takeInWholeReads(of: read)
        sections.noteIcons(iconsToNote(in: read, wholeApps: wholeApps, previous: previousIDs))
        changes.took(sections, by: .newIcons)
        let checked = sections.checkUnchecked(apps: wholeApps, in: read)
        changes.took(sections, by: .check)
        await reportChecked(checked, in: read)
        changes.skip(to: sections)
        let showsThePlan = readShowsThePlan(read)
        // What a read shows is what the plan in force makes of the bar: the icons it finds with no place on the bar, though the plan
        // draws them, are ones macOS isn't drawing, and a reveal isn't waited for to bring them.
        if showsThePlan, let currentPlan { expectation.learn(from: read, plan: currentPlan) }
        // With the sections as they were when the plan in force was made, before this read changes them.
        let unattachedChanges = noteUnattached(read, armed: armed, afterDisplayChange: afterDisplayChange, atLaunch: atLaunch)
        var madeRoomForTheDots = false
        if barIsCollapsed, showsThePlan, !planIsTheSections {
            // A wide screen's plan draws every icon whatever the sections say: what a read finds says nothing of whether the icons the
            // sections show fit, so nothing is judged, and the reads counted before it don't carry over to when it is over.
            tracker.forgetSightings()
        } else if barIsCollapsed, showsThePlan {
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
                changes.took(sections, by: .overflowTracker)
                // A move asks for the read that says whether it was enough; dots (or apps) found out of the way for the first time ask for the
                // read that confirms it.
                madeRoomForTheDots = !result.movedForDots.isEmpty || !result.awaitingConfirmation.isEmpty || !result.awaitingApps.isEmpty
                outcome = result
            } else {
                // Nothing is made of this read: the reads in a row that were counted don't carry over to when it is on again.
                tracker.forgetSightings()
            }
            sayAboutTheDots(verdict: verdict, outcome: outcome, underTheSpacer: underTheSpacer,
                            beingMadeAgain: afterDisplayChange || atLaunch || !dotsHavePlaces)
        }
        let placedNew = sections.assignNew(apps: read.appsWithItems)
        changes.took(sections, by: .newApps)
        await saveIfChanged(from: before, changes: changes)
        await rebuildAndApply()
        await settleUnattached(unattachedChanges)
        // Apps that appear while Mantel runs go to the marker's place, when the person has placed it; the launch's go in the next write.
        if !placedNew.isEmpty, !atLaunch, before.newItemsIndex != nil { await requestLayoutWrite(.newApps) }
        // The read that says whether the room that was made was enough is one taken after the plan that made it was applied.
        if madeRoomForTheDots { await scheduler?.request(.trial) }
        return (read, follow.needsAnotherRead)
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
    func shownBars(of read: Inventory) -> Set<String> {
        BarVisibility.shownBars(windows.onScreenWindows(), bars: read.bars)
    }

    /// The apps the scanner isn't to believe the places of, and that are not judged: the ones the plan in force conceals, and the ones whose
    /// switch is off in System Settings (macOS doesn't draw them, whatever the plan says).
    func appsNotDrawn() -> Set<String> {
        var apps = currentPlan?.concealedBundleIDs ?? []
        if case .apps(let off) = turnedOffList { apps.formUnion(off) }
        return apps
    }

    /// The apps the layout resolver isn't to believe the frames of: the ones not drawn now, and the ones the last read was taken while the
    /// plan concealed (whose frames in it are where they were last drawn).
    func appsNotDrawnForLayout() -> Set<String> {
        concealedAtRead.union(appsNotDrawn())
    }

    private func displayKind(of uuid: String) -> DisplayKind {
        knownLayout?.display(uuid: uuid)?.isBuiltIn == true ? .builtIn : .other
    }

    /// Whether the dots have been seen on a bar since the launch (this read included), or the wait for it is over: only then is a dot with
    /// no place a finding. At the launch macOS places Mantel's dots after the first reads (the log used to say that one had no place, and
    /// that the « menu couldn't be told, once at every launch). Nothing else waits for it: only what the log says of the dots is held back.
    private func dotsHaveHadTheirPlaces(in read: Inventory) -> Bool {
        if dotsHavePlaced { return true }
        let waited = launchBeganAt.map { clock.now().timeIntervalSince($0) >= Self.seconds(Self.dotsPlacementWait) } ?? true
        dotsHavePlaced = DotsRoom.dotsArePlaced(in: read) || waited
        return dotsHavePlaced
    }

    private func sayAboutTheDots(verdict: DotsRoom.Verdict, outcome: AutoOverflowTracker.Outcome?, underTheSpacer: Bool,
                                 beingMadeAgain: Bool) {
        // A read taken for a change of displays, or at launch, is of a bar that is being made: where a dot can't be placed on it is no
        // finding yet.
        var verdict = verdict
        if beingMadeAgain { verdict.cantTell = [:] }
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
    /// applied or the engine switched, or while the bar is being re-sorted by a write of the order table, or one that began before the
    /// engines last finished.
    private func readShowsThePlan(_ read: Inventory) -> Bool {
        !isApplying && switchesUnderway == 0 && !resetting && !layoutSettling && lastStatus?.lastError == nil
            && (lastApplyEndedAt.map { read.capturedAt >= $0 } ?? false)
    }

    // MARK: Icons macOS doesn't tie to their apps

    /// Gives the tracker what a read says (`UnattachedIcons`), whichever engine is in charge: it keeps count of quits and of apps that
    /// list nothing, and of the sightings and the runs. An app that is flagged is expected on the bar again, since the switches will
    /// draw it. Nothing is logged or told here: `settleUnattached` does that once the plan has been applied.
    private func noteUnattached(_ read: Inventory, armed: (before: Bool, after: Bool), afterDisplayChange: Bool,
                                atLaunch: Bool) -> [UnattachedIconTracker.Change] {
        // A read that began before the last change of displays, or the one that was taken for it, is of a bar that is being made again.
        let beforeTheChange = lastDisplayChangeAt.map { read.capturedAt <= $0 } ?? false
        let gate = UnattachedReadGate(
            allowlistInCharge: lastStatus?.kind == .allowlist && lastStatus?.lastError == nil, armedBefore: armed.before,
            armedAfter: armed.after, showsThePlan: readShowsThePlan(read), collapsed: revealState == .collapsed && planIsTheSections,
            awake: sessionNow.isAwake, beingMadeAgain: afterDisplayChange || atLaunch || beforeTheChange,
            layoutWriteInProgress: layoutIsPending || layoutSettling)
        let running = Set(runningBundleIDs())
        var shown: Set<String>?
        let fits: (String) -> Bool = { app in
            if shown == nil { shown = DotsRoom.mayHaveAVerdict(in: read) ? self.shownBars(of: read) : [] }
            return self.trialFits([app], shownBars: shown ?? [])
        }
        let assessment = currentPlan.map { plan in
            UnattachedIcons.assess(read, gate: gate, plan: plan, sections: sections, running: running, notDrawn: appsNotDrawn(),
                                   ownBundleID: ownBundleID, fits: fits)
        }
        var evidence: UnattachedIconEvidence?
        if case .evidence(let found) = assessment { evidence = found }
        var processes: [String: Set<pid_t>] = [:]
        for app in runningApps() { if let bundleID = app.bundleID { processes[bundleID, default: []].insert(app.pid) } }
        let changes = unattached.readTaken(read, gate: gate, evidence: evidence, barLooksStuck: assessment == .stuck,
                                           holdingFlags: stuckWatch.holdsFlags, processes: processes)
        let flaggedNow = changes.compactMap { if case .flagged(let app) = $0 { app } else { nil } }
        // The switches' look at the bar then expects the icon, and is confirmed without waiting for one the allowlist never draws.
        if !flaggedNow.isEmpty { expectation.forget(apps: Set(flaggedNow)) }
        // After the tracker has taken the read: an app placed in it is no longer a suspect of the last change, and is one of the next.
        if let plan = currentPlan {
            var look = StuckBar.Look.none
            var suspects: [String: Set<pid_t>] = [:]
            let notDrawn = appsNotDrawn()
            if let placed = StuckBar.appsPlaced(in: read, gate: gate, plan: plan, sections: sections, running: running, notDrawn: notDrawn,
                                                ownBundleID: ownBundleID) {
                unattached.readPlaced(placed, processes: processes)
            }
            if let noSlot = StuckBar.appsWithNoSlot(in: read, gate: gate, plan: plan, sections: sections, running: running,
                                                    notDrawn: notDrawn, ownBundleID: ownBundleID, fits: fits) {
                suspects = stuckWatch.suspects(from: unattached.stuckBarSuspects)
                look = StuckBar.look(noSlot: noSlot, in: read, ownBundleID: ownBundleID, notDrawn: notDrawn, hadASlot: suspects,
                                     processes: processes, fits: fits)
            }
            noteStuckBar(stuckWatch.look(look, at: read.capturedAt), suspects: suspects)
        }
        return changes
    }

    /// Reads the list of the apps macOS has turned off, and has the tracker drop what it holds of them.
    private func readTurnedOffList() async {
        turnedOffList = await turnedOff()
        logUnattached(noteTurnedOffList())
    }

    private func noteTurnedOffList() -> [UnattachedIconTracker.Change] {
        if case .apps(let off) = turnedOffList { return unattached.turnedOffListRead(Set(off)) }
        return unattached.turnedOffListRead(nil)
    }

    /// What follows from the changes a read made: an app that was flagged is looked for in the list of the apps that are turned off, which
    /// is read again (a switch that was turned off while the app ran isn't what it was when the list was last read, and a turned-off app
    /// is never drawn), and then the changes are logged and Automatic is told.
    private func settleUnattached(_ changes: [UnattachedIconTracker.Change]) async {
        var changes = changes
        let flaggedNow = Set(changes.compactMap { if case .flagged(let app) = $0 { app } else { nil } })
        if !flaggedNow.isEmpty {
            turnedOffList = await turnedOff()
            let dropped = noteTurnedOffList()
            // An app flagged and dropped by that check is neither logged nor told.
            let droppedApps = Set(dropped.compactMap { if case .clearedTurnedOff(let app) = $0, flaggedNow.contains(app) { app } else { nil } })
            changes.removeAll { if case .flagged(let app) = $0 { droppedApps.contains(app) } else { false } }
            changes += dropped.filter { if case .clearedTurnedOff(let app) = $0 { !droppedApps.contains(app) } else { true } }
        }
        guard !isQuitting else { return }
        logUnattached(changes)
        publish()
        await tellAutomaticIfChanged()
    }

    private func logUnattached(_ changes: [UnattachedIconTracker.Change]) {
        for change in changes {
            switch change {
            case .flagged(let app):
                Log.info("session", "\(app): its icon gets no slot while the allowlist is live; macOS hasn't tied it to the app")
            case .clearedBySlot(let app):
                Log.info("session", "\(app): its icon has a slot under the allowlist again")
            case .clearedByQuit(let app):
                Log.info("session", "\(app) quit; its icon is no longer watched")
            case .clearedByNoItems(let app):
                Log.info("session", "\(app) lists no icon now; it is no longer watched")
            case .clearedTurnedOff(let app):
                Log.info("session", "\(app) is off in System Settings; its icon is no longer watched")
            }
        }
    }

    /// Chooses the engine again when the apps Automatic is to be told of aren't what it was last told. Not while a reset is under way or
    /// once quitting has begun (a reset's own choice picks the set up).
    private func tellAutomaticIfChanged() async {
        guard mayChangeEngines(forReset: false), unattached.forAutomatic(sections: sections) != toldAutomatic else { return }
        await chooseEngine()
        guard !isQuitting else { return }
        publish()
    }

    // MARK: A bar a change of displays left stuck

    /// Sets what restarts MenuBarAgent for a bar that a change of displays left stuck; nil takes it away, and nothing is restarted by
    /// the session then.
    public func setStuckBarRecovery(_ recovery: StuckBarRecovery?) {
        stuckRecovery = recovery
    }

    /// What the watch made of a read: the recovery begins (on a task of its own: it asks for reads, which can't be taken while this one,
    /// which is what the scheduler is running, hasn't returned), or a line is logged. A recovery that can't begin now ends the watch's
    /// run of looks (`StuckBarWatch.recoveryNotBegun`): two new looks are needed to decide it again, not one.
    private func noteStuckBar(_ verdict: StuckBarWatch.Verdict, suspects: [String: Set<pid_t>]) {
        switch verdict {
        case .nothing:
            break
        case .recover(let finding, let afterTheChange):
            guard stuckRecovery != nil, !recoveryUnderWay, mayRecoverStuckBar else {
                stuckWatch.recoveryNotBegun()
                return
            }
            recoveryUnderWay = true
            stuckRecoveriesDecided += 1
            let stamp = stuckBarStamp
            Task { await self.recoverStuckBar(finding: finding, suspects: suspects, afterTheChange: afterTheChange, stamp: stamp) }
        case .limitReached:
            Log.info("session", "the menu bar looks stuck after a change of displays, and MenuBarAgent was restarted \(StuckBarWatch.perHour) times in the last hour already: not restarting it again")
        case .didntHelp(let finding):
            Log.warning("session", "the menu bar is still stuck 10 seconds after MenuBarAgent restarted (\(describe(finding))); not restarting it again")
        }
    }

    /// The displays changed, or the Mac woke.
    private func stuckBarChangeHappened() {
        stuckBarStamp += 1
        stuckWatch.changeHappened(at: clock.now())
    }

    /// Whether the menu bar may be restarted now: not while a reset is under way, quitting has begun, the screen is locked or asleep, or
    /// a write of the order table is pending or settling.
    private var mayRecoverStuckBar: Bool {
        !resetting && !isQuitting && sessionNow.isAwake && !layoutIsPending && !layoutSettling
    }

    private func describe(_ finding: StuckBarFinding) -> String {
        var parts: [String] = []
        if !finding.apps.isEmpty { parts.append("no slot for \(finding.apps.sorted().joined(separator: ", "))") }
        if finding.ownItems { parts.append("no slot for Mantel's own items") }
        return parts.joined(separator: "; ")
    }

    /// What became of a recovery that was decided.
    private enum RecoveryOutcome {
        case restarted, failed
        /// Something forbade it before MenuBarAgent was asked to restart: nothing was done, and nothing is said of it.
        case notBegun
    }

    /// Restarts MenuBarAgent, as a Reset does, and puts the plan back and reads the bar: the plan stays as it is in force, with the
    /// engine in charge of it.
    ///
    /// What of `runReset` is kept, and what isn't:
    /// - **Kept:** the restart through the same `MenuBarAgentRestarting`; the wait for the agent to answer; the tracker forgetting what it
    ///   knew (`forgetAll`), though its hold on new flags stays until the bar is seen whole (`StuckBarWatch.holdsFlags`); the choice of
    ///   engine and the plan applied again by force (an assertion of the allowlist is made live once more), then a read; and the
    ///   session's own `resetting`, so that nothing is judged or captured, no trial starts and no refresh is made while the agent is down.
    /// - **Not kept:** the engine isn't taken down (that shows every icon, which is for a Reset's undoing everything: here the person's
    ///   hiding stays), and the journal isn't replayed (it undoes what Mantel changed in the system, which a Reset does so that nothing
    ///   of Mantel's is left behind, and which this leaves in place: the layout and the spacing are the person's choices). The reveal
    ///   isn't collapsed either: the gate for the recovery says nothing is revealed, and one that begins in the meantime is the person's.
    ///
    /// Just before it, in this order: the list of the apps macOS has turned off is read again (an app switched
    /// off in System Settings keeps listing its icon, and the list may be older than the switch): what it names is no reason, and when
    /// nothing else is left nothing is restarted; and, right before MenuBarAgent is asked, nothing may have changed since the decision (the
    /// displays, a reset) nor quitting begun.
    private func recoverStuckBar(finding: StuckBarFinding, suspects: [String: Set<pid_t>], afterTheChange: TimeInterval, stamp: Int) async {
        defer { recoveryUnderWay = false }
        guard let recovery = stuckRecovery, mayRecoverStuckBar else {
            stuckWatch.recoveryNotBegun()
            return
        }
        // A Reset has it: this isn't begun, and two new looks decide again.
        guard recovery.activity.begin() else {
            stuckWatch.recoveryNotBegun()
            return
        }
        defer { recovery.activity.end() }
        guard mayRecoverStuckBar, stuckRecovery != nil, stamp == stuckBarStamp else {
            stuckWatch.recoveryNotBegun()
            return
        }
        await readTurnedOffList()
        var off: Set<String> = []
        if case .apps(let apps) = turnedOffList { off = Set(apps) }
        let reasons = StuckBarFinding(apps: finding.apps.subtracting(off), ownItems: finding.ownItems && !off.contains(ownBundleID))
        guard mayRecoverStuckBar, stuckRecovery != nil, stamp == stuckBarStamp else {
            stuckWatch.recoveryNotBegun()
            return
        }
        // What the list says stays so until the next change: nothing is decided again before it.
        guard reasons.warrantsARestart else {
            Log.info("session", reasons.isEmpty
                ? "what had no slot after a change of displays is off in System Settings; not restarting MenuBarAgent"
                : "only one app is left with no slot after a change of displays once what is off in System Settings is out (\(describe(reasons))); not restarting MenuBarAgent")
            stuckWatch.recoveryRefused()
            return
        }

        resetting = true
        noteBarChange("a stuck bar's recovery began")
        pendingApply = nil
        let outcome = await Task {
            await self.runStuckBarRecovery(recovery, reasons: reasons, suspects: suspects, afterTheChange: afterTheChange, stamp: stamp)
        }.value
        resetting = false
        noteBarChange("a stuck bar's recovery ended")
        switch outcome {
        case .restarted:
            stuckWatch.recoveryEnded(at: clock.now(), suspects: suspects)
        case .failed:
            stuckWatch.recoveryFailed(at: clock.now(), suspects: suspects)
            await rebuildAndApply()
        case .notBegun:
            stuckWatch.recoveryNotBegun()
            await rebuildAndApply()
        }
        guard !isQuitting else { return }
        publish()
    }

    private func runStuckBarRecovery(_ recovery: StuckBarRecovery, reasons: StuckBarFinding, suspects: [String: Set<pid_t>],
                                     afterTheChange: TimeInterval, stamp: Int) async -> RecoveryOutcome {
        // The hop onto this task, and what came since the last check: quitting, a change of displays, a reset.
        guard !isQuitting, stamp == stuckBarStamp else { return .notBegun }
        stuckWatch.recoveryBegan(at: clock.now())
        Log.info("session", "the menu bar is stuck after a change of displays, \(Int(afterTheChange.rounded())) seconds on (\(describe(reasons))); restarting MenuBarAgent")
        do throws(RestartError) {
            try await recovery.restarter.restart()
        } catch {
            Log.warning("session", "MenuBarAgent couldn't be restarted for a stuck menu bar: \(error.localizedDescription)")
            return .failed
        }
        await waitForAgent()
        unattached.forgetAll()
        await refreshNow(forReset: true)
        return .restarted
    }

    // MARK: Room may have returned

    /// Asks the tracker whether the apps it moved out may fit again, and if some are put on trial, applies the plan that shows them and
    /// then asks for a read of the bar: the read that judges the trial is one taken after the plan was applied.
    private func tryTrial(_ trigger: AutoOverflowTracker.Trigger) async {
        // Not while a reset has everything shown, nor once quitting has begun.
        guard !resetting, !isQuitting else { return }
        let mayTry = settings.automaticOverflow && barIsCollapsed && planIsTheSections
        // A change of displays is told to the tracker whatever else is going on: what it knows of the room is out of date, and it
        // forgets which apps overflowed again.
        guard mayTry || trigger == .displaysChanged else { return }

        var proposed = sections
        let shown = mayTry && DotsRoom.mayHaveAVerdict(in: inventory) ? shownBars(of: inventory) : []
        let started = tracker.roomMayHaveReturned(trigger, sections: &proposed, predictedFits: { mayTry && trialFits($0, shownBars: shown) },
                                                  now: clock.now())
        guard !started.isEmpty else { return }
        // What the apps said of where they were is what a place after the trial is told from.
        placesBeforeTrials.merge(OverflowInputs.strayPlaces(ofApps: started, in: inventory)) { _, new in new }
        let before = sections
        sections = proposed
        await saveIfChanged(from: before, by: .overflowTracker)
        await rebuildAndApply()
        await scheduler?.request(.trial)
    }

    /// Whether these apps, all on the bar at once, are predicted to have room on every bar: what they were last seen to take is no
    /// more than what is free of it (and, on a bar that is shown and has a dot of Mantel's out of the way, the room the dot needs too).
    /// False when any of them has never been seen, or the bars aren't known: a trial of automatic overflow puts an app on the bar only
    /// when it is known to fit. (`predictedFits(_:)` answers the other way for an unknown width, which the reveal's follow-up corrects.)
    private func trialFits(_ apps: Set<String>, shownBars: Set<String>) -> Bool {
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

    func runningBundleIDs() -> [String] {
        Array(Set(runningApps().compactMap(\.bundleID))).sorted()
    }

    private func buildPlan() -> VisibilityPlan {
        PlanBuilder.build(PlanInputs(
            ownBundleID: ownBundleID, runningBundleIDs: runningBundleIDs(), sections: sections, reveal: revealLevelOnTheBar,
            focusMode: revealState == .focusMode, allowHidingClockAndControlCenter: settings.allowHidingClockAndControlCenter,
            wideScreen: WideScreenInput(enabled: settings.showEverythingOnWideScreens, threshold: settings.wideScreenThreshold,
                                        activeScreenWidth: activeScreenWidth),
            swapConcealed: swapConcealed, iconReveals: iconTickets.values.reduce(into: []) { $0.formUnion($1) },
            iconRoomConcealed: iconRoomByTicket.values.reduce(into: []) { $0.formUnion($1) }))
    }

    /// Saves the sections if they are not what they were, with a line in the log that says what changed and who changed it.
    private func saveIfChanged(from before: SectionModel, by cause: SectionChangeLog.Cause) async {
        var changes = SectionChangeLog(from: before)
        changes.took(sections, by: cause)
        await saveIfChanged(from: before, changes: changes)
    }

    /// `changes` has the steps of what was done to the sections since `before`: what it doesn't say yet is the sections as they are now,
    /// which someone else changed (and said so) while the session was waiting.
    private func saveIfChanged(from before: SectionModel, changes: SectionChangeLog) async {
        guard sections != before else { return }
        if let line = changes.line { Log.info("layout", line) }
        await saveSections(sections)
    }

    /// Counts a change of the bar (`barChanges`), and keeps what it was.
    func noteBarChange(_ what: String) {
        barChanges += 1
        lastBarChange = what
    }

    /// Makes the plan from what is true now, and has it applied if it isn't the one that was asked for last. Returns when the plan, or
    /// a newer one, has been applied.
    func rebuildAndApply(force: Bool = false) async {
        // After quitting has begun no plan reaches the engines: what is applied is what quitting takes down.
        guard !isQuitting else { return }
        let plan = buildPlan()
        if let currentPlan, currentPlan.concealedBundleIDs != plan.concealedBundleIDs {
            concealedBeforeThePlan = currentPlan.concealedBundleIDs
        }
        currentPlan = plan
        if !force, plan == lastSubmitted {
            // It is the plan that is applied, or on its way.
            if isApplying { await withCheckedContinuation { applyWaiters.append($0) } }
        } else {
            await submit(plan, force: force)
        }
        publish()
    }

    /// Where the engines are with the plans: whether one is being applied (or a switch of engine is under way), and how long ago the last
    /// one ended (nil when none has). What a plan has applied is drawn on screen some time later (`ClickRouteRules.drawnWait`), and the
    /// click path waits that out before it looks at the bar.
    var applyProgress: ApplyProgress {
        ApplyProgress(underway: isApplying || pendingApply != nil || switchesUnderway > 0,
                      since: lastApplyEndedAt.map { .seconds(max(0, clock.now().timeIntervalSince($0))) })
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
        noteBarChange("a plan was handed to the engines")
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
                noteBarChange("a plan was applied")
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

    func publish() {
        guard let lastStatus, let currentPlan else { return }
        let state = MenuBarState(
            inventory: inventory, sections: sections,
            lists: ReadOnlyLists.make(inventory: inventory, sections: sections, running: Set(runningBundleIDs()), turnedOff: turnedOffList,
                                      unresolved: layoutUnresolved),
            plan: currentPlan, engine: lastStatus, alwaysHiddenHasApps: alwaysHiddenHasApps(), widths: widths,
            unattachedApps: unattached.flagged.intersection(runningBundleIDs()), layout: layoutStatus,
            stuckBarNotRecovered: stuckWatch.didntHelp, currentIDs: currentIDs)
        guard state != lastPublished else { return }
        lastPublished = state
        for continuation in subscribers.values { continuation.yield(state) }
    }

    /// Whether anything that is running is in Always Hidden, or a system item that can be put there is.
    func alwaysHiddenHasApps() -> Bool {
        let running = Set(runningBundleIDs())
        if sections.apps.contains(where: { $0.value.section == .alwaysHidden && running.contains($0.key) }) { return true }
        return sections.systemItems.contains { module, section in
            guard section == .alwaysHidden, SystemItemTable.number(of: module) != nil else { return false }
            return !SystemItemTable.unmovable.contains(module) || settings.allowHidingClockAndControlCenter
        }
    }
}
