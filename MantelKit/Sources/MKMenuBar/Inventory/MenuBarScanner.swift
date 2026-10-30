import CoreGraphics
import Foundation
import MKCore
import Synchronization

/// Asks one app for its status items. The real one reads Accessibility (`AXAppExtrasReader`); a test gives one that takes its time on
/// the test's clock.
protocol AppExtrasReading: Sendable {
    func read(_ app: RunningApp) async -> ExtrasOutcome
    /// The processes that are running now: what is remembered of the others goes.
    func keep(onlyProcesses pids: Set<pid_t>)
}

extension AppExtrasReading {
    func keep(onlyProcesses pids: Set<pid_t>) {}
}

struct AXAppExtrasReader: AppExtrasReading {
    let reader: AppExtrasReader

    @concurrent
    func read(_ app: RunningApp) async -> ExtrasOutcome {
        reader.read(app)
    }

    func keep(onlyProcesses pids: Set<pid_t>) {
        reader.names.keep(only: pids)
    }
}

/// Reads the menu bar into an `Inventory`.
///
/// - **One window per display.** MenuBarAgent has one window per display for every Space; one of them gives that display's slots,
///   and its frame is the bar's rectangle and height (`AgentWindowChooser`). They all show the same slots, but some lack the
///   identifiers of the others, and one can gain them later, so the one with the most is used. An ordinary scan reads the window
///   that had the most last time and one more of each display, in turn (so that a window that has gained names is found within a
///   few scans), and further ones only while neither has as many identifiers as a window of the display was last seen to have. A
///   scan for an app launching or quitting reads every window; one for a change of displays or a refresh reads every
///   window and compares them. A display that nothing is remembered of has every window read.
/// - **Each app's items** come from the app itself (its extras menu bar) and are matched to slots by where they are
///   (`InventoryMatcher`).
/// - **Apps are asked, at most eight at a time,** with 0.25 s for each call. Helper bundles are never asked. An app that has no
///   extras menu bar is not asked again for a minute (it is told by its process, so a relaunch asks at once; one that started in the
///   last ten seconds, and so may not have made its items yet, is asked again after two), and so is an app that refuses Accessibility
///   while Mantel has the grant (`ReachStatus.refused`: it is not Mantel's grant that is missing). An app that times out three times in a
///   row is left alone for 30 seconds.
/// - **Accessibility is checked on every scan,** not once at launch.
///
/// The reads block, so they run off the actor (`@concurrent`), and the actor only keeps what is remembered between scans. Scans are
/// asked for through `ScanScheduler`, which lets one run at a time. A call that comes while one is under way (a probe asks for a scan of
/// its own) is not another scan, and not lost: its reasons are kept. If it asks for more than the scan under way covers (`Coverage`: every
/// window of MenuBarAgent for apps launching or quitting, every window compared for a change of displays, a refresh or no reason given)
/// there is one more scan after the one that is running, with all the reasons that came meanwhile, whose result it is given; the scan
/// that waits covers the most any of them asked. A call that asks for no more than the scan under way is given that scan's result: its
/// reasons are covered by it.
///
/// The scanner is also what finds where one item is now (`ItemLocating`) and presses it (`ItemPressing`), in `ItemLocator.swift`.
public actor MenuBarScanner {
    /// How long an app that has no extras is left alone.
    static let noExtrasRecheck: TimeInterval = 60
    /// How long an app that started a moment ago and has no extras is left alone, and how long a start is a moment ago.
    static let youngNoExtrasRecheck: TimeInterval = 2
    static let youngAppAge: TimeInterval = 10
    /// How long an app that has timed out too often is left alone.
    static let skipDuration: TimeInterval = 30
    /// How many timeouts in a row make an app one that is left alone.
    static let timeoutsBeforeSkip = 3
    /// A read that takes this long or longer is slow.
    static let slowMilliseconds = 100.0

    // What the locator and the presser (`ItemLocator.swift`) read as well.
    let ax: any AXReading
    let agentReader: AgentWindowReader
    private let extrasReader: any AppExtrasReading
    /// Reads an app's items with their elements, which a press needs. In the app it is the reader the scans use, and remembers what it
    /// does for them.
    let elementReader: AppExtrasReader
    let runningApps: @Sendable () -> [RunningApp]
    let layout: @Sendable () -> DisplayLayout
    let ownBundleID: String
    let isTrusted: @Sendable () -> Bool
    let clock: any Clock

    private(set) var memory = IndexMemory()

    /// Mantel changed the order of these apps' items in macOS's table: where their items sat from left to right is learned again.
    func forgetPlaces(ofApps apps: [String]) {
        for app in apps { memory.forgetPlaces(ofApp: app) }
    }
    /// The apps the plan concealed when a scan was last asked for, which `locate` (`ItemLocator.swift`) matches with: a frame an app that is
    /// concealed leaves behind may lie in another app's slot, and must not claim it.
    var concealedApps: Set<String> = []
    /// The apps (by bundle ID) that had an item on each display's bar at the last scan, from the inventory it made: the apps whose frames
    /// `locate` asks for besides the item's own, so that a frame the item's app left behind in another app's slot finds that app's own
    /// claim on it. An app with nothing drawn on the display has no slot there to claim.
    var appsOnBar: [String: Set<String>] = [:]
    /// Whether the scans have found this process to have no items (or to refuse Accessibility), and are leaving it alone for a while.
    func isKnownToHaveNoItems(_ app: RunningApp) -> Bool {
        noExtras[app.pid] != nil
    }

    /// When an app (by process) was found to have no extras, or to refuse Accessibility (`refused`), and how long it is then left alone.
    private var noExtras: [pid_t: (checkedAt: Date, recheckAfter: TimeInterval, refused: Bool)] = [:]
    /// When each process was first seen running; `distantPast` for those that were there at the first scan.
    private var firstSeen: [pid_t: Date] = [:]
    /// What holds the blocking reads of apps to eight at once, a scan's and a look at one item's together (`ItemLocator`).
    let readGate: ReadGate
    private let readLimit: Int
    /// How long Accessibility queries wait for an app, and how much of a read one app may take (`AXPatience`).
    let patience: AXPatience
    private var hasScanned = false
    private var timeoutStreaks: [pid_t: Int] = [:]
    private var skippedUntil: [pid_t: Date] = [:]
    private var failureStreak = 0
    /// For each display, what was seen of its windows by the last read: how many identifiers the best had, and which it was. A quick read
    /// that settles on another window moves `best` to it.
    var windowMemory: [String: WindowMemory] = [:]
    /// Whether the last thorough scan found a display whose windows disagree, and whether two in a row did.
    private var lastThoroughDisagreed = false
    private var windowsDisagree = false

    /// The scan that is under way (or, while one more is waiting for it, that one).
    private var inFlight: Task<Inventory, Never>?
    /// What the calls that came while a scan was under way asked for: every reason they gave, and the apps the plan conceals as the latest
    /// of them said them. Nil when none came.
    private var late: (reasons: Set<ScanScheduler.Reason>, concealed: Set<String>, notVoting: Set<String>)?
    /// How much the scan that is executing covers.
    private var runningCoverage = Coverage.steady
    /// What the one more scan covers, while one waits for the scan that is under way because a call that came meanwhile asked for more
    /// than it covers. Nil when none waits.
    private var followUp: Coverage?
    /// The reasons of every scan that was made, the last twenty. For tests.
    private(set) var scanReasons: [Set<ScanScheduler.Reason>] = []
    /// How much each of those scans covered (`steady`, `allWindows` or `thorough`). For tests.
    private(set) var scanCoverages: [String] = []
    /// The reasons that calls gave while a scan was under way, which the scan after it will have. For tests.
    var waitingReasons: Set<ScanScheduler.Reason> { late?.reasons ?? [] }
    /// Whether one more scan waits for the one that is under way. For tests.
    var hasFollowUp: Bool { followUp != nil }

    /// - Parameters:
    ///   - runningApps: the apps to ask (MenuBarAgent among them, which is where the slots are read).
    ///   - layout: the displays as they are now.
    ///   - ownBundleID: Mantel's, so that its own items are marked.
    ///   - isTrusted: whether Accessibility is granted now. It is asked on every scan.
    public init(ax: any AXReading, runningApps: @escaping @Sendable () -> [RunningApp], layout: @escaping @Sendable () -> DisplayLayout,
                ownBundleID: String, isTrusted: @escaping @Sendable () -> Bool, clock: any Clock = SystemClock()) {
        let reader = AppExtrasReader(ax: ax)
        self.init(ax: ax, extrasReader: AXAppExtrasReader(reader: reader), elementReader: reader, runningApps: runningApps, layout: layout,
                  ownBundleID: ownBundleID, isTrusted: isTrusted, clock: clock)
    }

    init(ax: any AXReading, extrasReader: any AppExtrasReading, elementReader: AppExtrasReader? = nil,
         runningApps: @escaping @Sendable () -> [RunningApp], layout: @escaping @Sendable () -> DisplayLayout, ownBundleID: String,
         isTrusted: @escaping @Sendable () -> Bool, clock: any Clock, patience: AXPatience = .standard,
         readLimit: Int = MenuBarReader.concurrency) {
        self.patience = patience
        self.readLimit = readLimit
        self.readGate = ReadGate(limit: readLimit)
        self.ax = ax
        self.agentReader = AgentWindowReader(ax: ax)
        self.extrasReader = extrasReader
        self.elementReader = elementReader ?? AppExtrasReader(ax: ax)
        self.runningApps = runningApps
        self.layout = layout
        self.ownBundleID = ownBundleID
        self.isTrusted = isTrusted
        self.clock = clock
    }

    /// How many scans in a row found MenuBarAgent missing or without windows.
    public var agentFailureStreak: Int { failureStreak }

    // MARK: Scan

    /// Reads the menu bar.
    ///
    /// Call it through `ScanScheduler`, which says why a scan is wanted, runs one at a time and spaces them out. A call that comes
    /// while another is under way isn't another scan at once: its reasons are kept, and it is given the result of the one that is under
    /// way; unless it asks for more than that one reads (see `Coverage`), when it waits for one more scan that has the reasons of every call
    /// that came meanwhile.
    ///
    /// - Parameter reasons: why the scan is wanted. A scan for a change of displays or a refresh (or for no reason given)
    ///   is a thorough one: it reads all of MenuBarAgent's windows, to find the one with the most identifiers and to see whether they
    ///   disagree. One for apps launching or quitting reads them all too, to find the one with the most, but doesn't compare them.
    ///   The others read two windows of each display (and more only if they have fewer identifiers than is known).
    ///
    /// - Parameter concealed: the apps the plan in force conceals. What they say of where their icons are is not believed, and the scanner
    ///   keeps the set for finding an item (`locate`) until the next scan is asked for.
    ///
    /// - Parameter notVoting: the apps whose frames don't count towards which display is active (`MatchInput.notVoting`).
    public func scan(reasons: Set<ScanScheduler.Reason> = [], concealed: Set<String> = [], notVoting: Set<String> = []) async -> Inventory {
        concealedApps = concealed
        guard let running = inFlight else {
            // Said before the scan starts (it starts a moment later), so that a call that comes in between is judged against this one.
            runningCoverage = Coverage(reasons)
            let task = Task { await self.performScan(reasons: reasons, concealed: concealed, notVoting: notVoting) }
            inFlight = task
            return await task.value
        }
        // One is under way. What this call asks for is kept. It is given the result of the scan under way, unless it asks for more than that
        // covers: then there is one more after it (one for every such call that comes before it starts, covering the most any of them
        // asked), and the result is that scan's.
        let wanted = Coverage(reasons)
        late = (reasons: (late?.reasons ?? []).union(reasons), concealed: concealed, notVoting: notVoting)
        if let waiting = followUp {
            followUp = max(waiting, wanted)
            return await running.value
        }
        guard wanted > runningCoverage else { return await running.value }
        followUp = wanted
        let next = Task {
            _ = await running.value
            return await self.performFollowUp()
        }
        inFlight = next
        return await next.value
    }

    /// How much of MenuBarAgent's windows a scan reads, as the reasons for it ask. A scan covers the ones before it.
    private enum Coverage: Int, Comparable {
        /// The window that was best and one more, of each display (and more only if they have fewer identifiers than is known).
        case steady
        /// Every window, for apps launching or quitting: the one with the most identifiers is used.
        case allWindows
        /// Every window, compared: a change of displays or a refresh, or no reason given.
        case thorough

        init(_ reasons: Set<ScanScheduler.Reason>) {
            if reasons.isEmpty || !reasons.isDisjoint(with: [.displaysChanged, .refresh]) {
                self = .thorough
            } else if reasons.contains(.appsChanged) {
                self = .allWindows
            } else {
                self = .steady
            }
        }

        static func < (a: Coverage, b: Coverage) -> Bool { a.rawValue < b.rawValue }
    }

    /// The scan that waited for the one before it, with every reason that came meanwhile, covering what the most demanding of them asked.
    private func performFollowUp() async -> Inventory {
        let reasons = late ?? (reasons: [], concealed: [], notVoting: [])
        late = nil
        let coverage = followUp ?? .thorough
        followUp = nil
        return await performScan(reasons: reasons.reasons, concealed: reasons.concealed, notVoting: reasons.notVoting, atLeast: coverage)
    }

    private func performScan(reasons: Set<ScanScheduler.Reason>, concealed: Set<String>, notVoting: Set<String>,
                             atLeast: Coverage = .steady) async -> Inventory {
        defer {
            // The scan that waits for this one is the next in flight: a call that comes between the two is joined to it, not made a third.
            if followUp == nil {
                inFlight = nil
                late = nil
            }
        }
        let coverage = max(Coverage(reasons), atLeast)
        runningCoverage = coverage
        scanReasons.append(reasons)
        scanCoverages.append("\(coverage)")
        if scanReasons.count > 20 {
            scanReasons.removeFirst(scanReasons.count - 20)
            scanCoverages.removeFirst(scanCoverages.count - 20)
        }
        let now = clock.now()
        // Asked every time: the grant can be given or taken away while Mantel runs.
        guard isTrusted() else { return problem(.accessibilityNotGranted, at: now) }
        let running = runningApps()
        guard let agent = menuBarAgent(in: running) else {
            failureStreak += 1
            return problem(.agentNotRunning, at: now)
        }
        let displays = layout()
        noteApps(running, at: now)

        let thorough = coverage == .thorough
        let plan: AgentReadPlan = thorough ? .thorough : coverage == .allWindows ? .allWindows : .steady(memory: windowMemory)
        let (toAsk, skipped) = partition(running, now: now)
        // MenuBarAgent's windows are read beside the apps (and take their turns at the gate as the apps do): its own retries, when it comes
        // back with no window, overlap the apps' reads and don't wait for them.
        let (reads, bars) = await inScope(AXPatience.scanBudget, excusesGateWait: false) {
            async let agentRead = self.readAgent(agent, layout: displays, plan: plan, scanBegan: now)
            let reads = await self.readExtras(of: toAsk)
            return (reads, await agentRead)
        }

        if bars.notTrusted { return problem(.accessibilityNotGranted, at: now) }
        if bars.bars.isEmpty {
            failureStreak += 1
            return problem(.agentHasNoWindows, at: now)
        }
        failureStreak = 0
        windowMemory = bars.memory
        if thorough {
            // A clock tick can move the slots of one window and not another's for a moment, so one disagreement is not a doubt:
            // two scans in a row are.
            windowsDisagree = bars.isAmbiguous && lastThoroughDisagreed
            lastThoroughDisagreed = bars.isAmbiguous
        }

        var problems: [InventoryProblem] = []
        if windowsDisagree { problems.append(.ambiguousSpace) }
        var answered: [AppExtras] = []
        var reach = skipped
        for read in reads {
            switch read.outcome {
            case .items(let extras) where !extras.timedOut:
                timeoutStreaks[read.app.pid] = 0
                answered.append(extras)
                reach.append(AppReach(bundleID: read.app.bundleID ?? "", name: read.app.name,
                                      status: extras.itemTimeouts == 0 && read.milliseconds < Self.slowMilliseconds ? .fine : .slow,
                                      readMs: read.milliseconds))
            case .items where read.notAsked, .timedOut where read.notAsked:
                // The scan's time was over before it came to this app: it was asked nothing, and that is no timeout of its own.
                reach.append(AppReach(bundleID: read.app.bundleID ?? "", name: read.app.name, status: .skipped, readMs: 0))
            case .items, .timedOut:
                recordTimeout(of: read.app, at: now)
                reach.append(AppReach(bundleID: read.app.bundleID ?? "", name: read.app.name, status: .timedOut, readMs: read.milliseconds))
            case .noExtras:
                timeoutStreaks[read.app.pid] = nil
                noExtras[read.app.pid] = (now, recheckPause(for: read.app, at: now), false)
            case .notTrusted:
                timeoutStreaks[read.app.pid] = nil
                if isTrusted() {
                    // Mantel has the grant, so this app is the one that says no (Apple's authentication agent answers every read so).
                    noExtras[read.app.pid] = (now, recheckPause(for: read.app, at: now), true)
                    reach.append(AppReach(bundleID: read.app.bundleID ?? "", name: read.app.name, status: .refused, readMs: read.milliseconds))
                } else if !problems.contains(.accessibilityNotGranted) {
                    // The grant was taken away while the apps were asked.
                    problems.append(.accessibilityNotGranted)
                }
            }
        }
        reach.sort { ($0.bundleID, $0.name ?? "") < ($1.bundleID, $1.name ?? "") }

        let input = MatchInput(capturedAt: now, layout: displays, bars: bars.bars, apps: answered, ownBundleID: ownBundleID,
                               reach: reach, problems: problems, concealedApps: concealed, notVoting: notVoting)
        let result = InventoryMatcher.matchCounting(input, memory: &memory)
        if result.unmatchedSlots > 0 || result.segmentsNotAligned > 0 {
            Log.logger("inventory").debug("\(result.unmatchedSlots) slots matched no app, \(result.segmentsNotAligned) segments not aligned")
        }
        var onBar: [String: Set<String>] = [:]
        for item in result.inventory.items where !item.id.isSystem {
            for uuid in item.frames.keys { onBar[uuid, default: []].insert(item.id.bundleID) }
        }
        appsOnBar = onBar
        // Which apps run is what the apps' bundle IDs say here, not which of them have an item in the read.
        let read = result.inventory.withRunningApps(Set(running.compactMap(\.bundleID)))
        return bars.cut ? read.markingAgentReadCut() : read
    }

    /// MenuBarAgent's windows, read through the gate. MenuBarAgent runs and Accessibility is granted, so a read that found no window of it was
    /// one whose queries timed out: it is asked again before anything acts on it (`EmptyReadRetry`). Each new try is a read of its own,
    /// with a scope of its own, so that what the first spent doesn't leave the next nothing to ask with; and none begins once the scan
    /// has had its whole time.
    private func readAgent(_ agent: RunningApp, layout displays: DisplayLayout, plan: AgentReadPlan, scanBegan: Date) async -> AgentRead {
        let reader = agentReader, gate = readGate, clock = clock
        var read = await gate.run { await reader.read(agent: agent, layout: displays, plan: plan) }
        var attempt = 0
        while read.bars.isEmpty, !read.notTrusted, let wait = EmptyReadRetry.wait(afterAttempt: attempt) {
            guard !isStopping.withLock({ $0 }) else { break }
            do { try await clock.sleep(for: wait) } catch { break }
            guard clock.now().timeIntervalSince(scanBegan) < AXPatience.scanBudget, !isStopping.withLock({ $0 }) else { break }
            read = await inScope(AXPatience.lookBudget) { await gate.run { await reader.read(agent: agent, layout: displays, plan: plan) } }
            attempt += 1
        }
        return read
    }

    /// The MenuBarAgent among these apps, which Accessibility is told to expect answers from: it is what the bar is read from, and a busy
    /// Mac makes it late, which is not silence.
    func menuBarAgent(in running: [RunningApp]) -> RunningApp? {
        guard let agent = running.first(where: { $0.bundleID == MenuBarReader.menuBarAgentBundleID }) else { return nil }
        ax.expectAnswers(fromProcess: agent.pid)
        return agent
    }

    /// A quick look at the main display's bar: how many of its slots have a place on it now. It is for confirming a reveal, which is
    /// looked for every quarter of a second, so it is as cheap as a look can be: one window of MenuBarAgent's, the role and the frame
    /// of each slot in it, and nobody else's reads (an app's own frames often stay where they were when its icon is shown or hidden).
    /// It takes about three reads of Accessibility for each slot, and nothing it learns is kept.
    ///
    /// Nil when Accessibility isn't granted, MenuBarAgent isn't running, its list of windows didn't come (it timed out), or it has no
    /// window on that display. A read of the window that was used timing out ends the look there, and it says so (`BarLook.isComplete`);
    /// a timeout on a window that wasn't used is nothing to it.
    public func lookAtBar() async -> BarLook? {
        guard isTrusted() else { return nil }
        guard let agent = menuBarAgent(in: runningApps()) else { return nil }
        let agentReader = agentReader, displays = layout(), gate = readGate
        return await inScope(AXPatience.lookBudget) { await gate.run { await agentReader.look(agent: agent, layout: displays) } }
    }

    /// Runs one read of Accessibility with its own budget: every query in it, and every task it starts, waits for an app as long as
    /// `AXPatience` allows and no longer than the read has left (`AXReadScope`).
    ///
    /// - Parameters:
    ///   - quick: the apps that are asked with the first wait only (the bystanders of the read).
    ///   - excusesGateWait: whether a turn at the gate that is waited for doesn't count against the read's time (`AXReadScope`): it is so
    ///     for a short read, which isn't to spend its time queueing behind a scan; a scan's own time covers all of it.
    ///
    /// A read that is asked for within a scope of its own (the still-current check gives each round the time it has left) has no more
    /// than what is left of that scope's time.
    func inScope<Result: Sendable>(_ budget: TimeInterval, quick: Set<pid_t> = [], excusesGateWait: Bool = true,
                                   _ read: @Sendable () async -> Result) async -> Result {
        let allowed = AXReadScope.current.map { min(budget, $0.timeLeft) } ?? budget
        let scope = AXReadScope(budget: allowed, perAppBudget: patience.perAppBudget, clock: clock, quick: quick, excusesGateWait: excusesGateWait)
        return await AXReadScope.run(scope, read)
    }

    /// Quitting has begun: no query waits for an app from now on (`AXReading.stopWaiting`), so the reads that are under way end with the
    /// call they are in and take nobody's thread, nor the main thread's turn for Mantel's own items, while the app is taking itself down.
    ///
    /// Not isolated to the scanner: it only turns a switch over, and needs no turn on the actor, which a quit that is hard pressed may
    /// not get in time.
    public nonisolated func stopWaiting() {
        isStopping.withLock { $0 = true }
        ax.stopWaiting()
    }

    /// Set by `stopWaiting()`: a read of MenuBarAgent that comes back empty isn't asked again (it would only sleep through its tries).
    private nonisolated let isStopping = Mutex(false)

    /// The frames these apps report for their items now: the apps (every process of each) are asked together, as a scan asks them, and
    /// nothing is kept. An app that didn't answer in full (it timed out, or some of its reads did), isn't running, or has no items is not in
    /// the answer: nothing is known of where its items are. What a picture's slot is checked against once the strip is taken
    /// (`ItemFrameCheck`). Empty when Accessibility isn't granted.
    func itemFrames(ofApps bundleIDs: Set<String>) async -> [String: [CGRect]] {
        guard isTrusted() else { return [:] }
        let apps = runningApps().filter { app in
            guard let bundleID = app.bundleID else { return false }
            return bundleIDs.contains(bundleID) && !HelperBundles.isHelper(bundleID)
        }.sorted { $0.pid < $1.pid }
        var frames: [String: [CGRect]] = [:]
        var unknown: Set<String> = []
        for read in await inScope(AXPatience.checkBudget, { await readExtras(of: apps) }) {
            guard let bundleID = read.app.bundleID else { continue }
            guard case .items(let extras) = read.outcome, !extras.timedOut, extras.itemTimeouts == 0 else {
                unknown.insert(bundleID)
                continue
            }
            frames[bundleID, default: []] += extras.items.compactMap(\.frame)
        }
        for bundleID in unknown { frames[bundleID] = nil }
        return frames
    }

    /// How many blocking reads hold a turn at the gate and how many wait for one: for the log of a quit that overran.
    public nonisolated var readGateCounts: (running: Int, waiting: Int) { (readGate.running, readGate.waiting) }

    /// The process MenuBarAgent has now; nil when it isn't running.
    func menuBarAgentPID() -> pid_t? {
        runningApps().first { $0.bundleID == MenuBarReader.menuBarAgentBundleID }?.pid
    }

    /// The displays as they are now, which the log names the kind of display by.
    public func currentLayout() -> DisplayLayout {
        layout()
    }

    /// The frames of the menus of this app (its `AXMenuBar` children), in CoreGraphics global points: where the front app's own
    /// menus take room in the bar.
    ///
    /// Read like a look: in a scope of its own, and through the gate, so that a front app that doesn't answer holds the session's events up
    /// for no longer than a look takes.
    public func appMenuFrames(pid: pid_t) async -> [CGRect] {
        let reader = agentReader, gate = readGate
        return await inScope(AXPatience.lookBudget) { await gate.run { await reader.menuFrames(pid: pid) } }
    }

    // MARK: Which apps are asked

    /// The apps to ask, and the reach of those left alone because they timed out or refuse Accessibility.
    private func partition(_ running: [RunningApp], now: Date) -> (ask: [RunningApp], skipped: [AppReach]) {
        var ask: [RunningApp] = []
        var skipped: [AppReach] = []
        for app in running.sorted(by: { $0.pid < $1.pid }) {
            guard let bundleID = app.bundleID, bundleID != MenuBarReader.menuBarAgentBundleID, !HelperBundles.isHelper(bundleID) else {
                continue
            }
            if let until = skippedUntil[app.pid] {
                if now < until {
                    skipped.append(AppReach(bundleID: bundleID, name: app.name, status: .skipped, readMs: 0))
                    continue
                }
                skippedUntil[app.pid] = nil
            }
            if let known = noExtras[app.pid], now.timeIntervalSince(known.checkedAt) < known.recheckAfter {
                if known.refused { skipped.append(AppReach(bundleID: bundleID, name: app.name, status: .refused, readMs: 0)) }
                continue
            }
            ask.append(app)
        }
        return (ask, skipped)
    }

    /// How long an app that has no extras (or refuses Accessibility) is left alone: longer unless it started a moment ago.
    private func recheckPause(for app: RunningApp, at now: Date) -> TimeInterval {
        now.timeIntervalSince(firstSeen[app.pid] ?? .distantPast) < Self.youngAppAge ? Self.youngNoExtrasRecheck : Self.noExtrasRecheck
    }

    private func recordTimeout(of app: RunningApp, at now: Date) {
        let streak = (timeoutStreaks[app.pid] ?? 0) + 1
        timeoutStreaks[app.pid] = streak
        if streak >= Self.timeoutsBeforeSkip { skippedUntil[app.pid] = now.addingTimeInterval(Self.skipDuration) }
    }

    /// What is kept of apps that are no longer running goes, and the ones that are new are noted. Those that were there at the first
    /// scan aren't new: Mantel has just started, not they.
    private func noteApps(_ running: [RunningApp], at now: Date) {
        let pids = Set(running.map(\.pid))
        noExtras = noExtras.filter { pids.contains($0.key) }
        timeoutStreaks = timeoutStreaks.filter { pids.contains($0.key) }
        skippedUntil = skippedUntil.filter { pids.contains($0.key) }
        firstSeen = firstSeen.filter { pids.contains($0.key) }
        for pid in pids where firstSeen[pid] == nil { firstSeen[pid] = hasScanned ? now : .distantPast }
        extrasReader.keep(onlyProcesses: pids)
        ax.keep(onlyProcesses: pids)
        hasScanned = true
    }

    // MARK: Reading

    private struct AppRead: Sendable {
        let app: RunningApp
        let outcome: ExtrasOutcome
        let milliseconds: Double
        /// The read's time had passed when this app's turn came, so that nobody was asked: what it gave is no answer of the app's.
        let notAsked: Bool
    }

    /// Asks the apps, eight at a time, and times each one on the clock.
    private func readExtras(of apps: [RunningApp]) async -> [AppRead] {
        let reader = extrasReader, clock = clock
        return await ConcurrentMap.map(apps, limit: readLimit, gate: readGate) { app in
            let started = clock.now()
            let notAsked = AXReadScope.current?.timeLeft == 0
            let outcome = await reader.read(app)
            return AppRead(app: app, outcome: outcome, milliseconds: clock.now().timeIntervalSince(started) * 1000, notAsked: notAsked)
        }
    }

    private func problem(_ problem: InventoryProblem, at date: Date) -> Inventory {
        Inventory(capturedAt: date, bars: [], items: [], chevrons: [:], reach: [], problems: [problem])
    }
}
