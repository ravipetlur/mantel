import CoreGraphics
import Foundation
import MKCore

/// Asks one app for its status items. The real one reads Accessibility (`AXAppExtrasReader`); a test gives one that takes its time on
/// the test's clock.
protocol AppExtrasReading: Sendable {
    func read(_ app: RunningApp) async -> ExtrasOutcome
}

struct AXAppExtrasReader: AppExtrasReading {
    let reader: AppExtrasReader

    @concurrent
    func read(_ app: RunningApp) async -> ExtrasOutcome {
        reader.read(app)
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
///   last ten seconds, and so may not have made its items yet, is asked again after two). An app that times out three times in a row
///   is left alone for 30 seconds.
/// - **Accessibility is checked on every scan,** not once at launch.
///
/// The reads block, so they run off the actor (`@concurrent`), and the actor only keeps what is remembered between scans. Scans are
/// asked for through `ScanScheduler`, which lets one run at a time; a call that comes while one is under way is given its result.
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

    private let agentReader: AgentWindowReader
    private let extrasReader: any AppExtrasReading
    private let runningApps: @Sendable () -> [RunningApp]
    private let layout: @Sendable () -> DisplayLayout
    private let ownBundleID: String
    private let isTrusted: @Sendable () -> Bool
    private let clock: any Clock

    private var memory = IndexMemory()
    /// When an app (by process) was found to have no extras, and how long it is then left alone.
    private var noExtras: [pid_t: (checkedAt: Date, recheckAfter: TimeInterval)] = [:]
    /// When each process was first seen running; `distantPast` for those that were there at the first scan.
    private var firstSeen: [pid_t: Date] = [:]
    private var hasScanned = false
    private var timeoutStreaks: [pid_t: Int] = [:]
    private var skippedUntil: [pid_t: Date] = [:]
    private var failureStreak = 0
    /// For each display, what was seen of its windows by the last read: how many identifiers the best had, and which it was.
    private var windowMemory: [String: WindowMemory] = [:]
    /// Whether the last thorough scan found a display whose windows disagree, and whether two in a row did.
    private var lastThoroughDisagreed = false
    private var windowsDisagree = false
    private var inFlight: Task<Inventory, Never>?

    /// - Parameters:
    ///   - runningApps: the apps to ask (MenuBarAgent among them, which is where the slots are read).
    ///   - layout: the displays as they are now.
    ///   - ownBundleID: Mantel's, so that its own items are marked.
    ///   - isTrusted: whether Accessibility is granted now. It is asked on every scan.
    public init(ax: any AXReading, runningApps: @escaping @Sendable () -> [RunningApp], layout: @escaping @Sendable () -> DisplayLayout,
                ownBundleID: String, isTrusted: @escaping @Sendable () -> Bool, clock: any Clock = SystemClock()) {
        self.init(ax: ax, extrasReader: AXAppExtrasReader(reader: AppExtrasReader(ax: ax)), runningApps: runningApps, layout: layout,
                  ownBundleID: ownBundleID, isTrusted: isTrusted, clock: clock)
    }

    init(ax: any AXReading, extrasReader: any AppExtrasReading, runningApps: @escaping @Sendable () -> [RunningApp],
         layout: @escaping @Sendable () -> DisplayLayout, ownBundleID: String, isTrusted: @escaping @Sendable () -> Bool,
         clock: any Clock) {
        self.agentReader = AgentWindowReader(ax: ax)
        self.extrasReader = extrasReader
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
    /// while another is under way isn't another scan: it is given the one that is.
    ///
    /// - Parameter reasons: why the scan is wanted. A scan for a change of displays or a refresh (or for no reason given)
    ///   is a thorough one: it reads all of MenuBarAgent's windows, to find the one with the most identifiers and to see whether they
    ///   disagree. One for apps launching or quitting reads them all too, to find the one with the most, but doesn't compare them.
    ///   The others read two windows of each display (and more only if they have fewer identifiers than is known).
    ///
    /// - Parameter concealed: the apps the plan in force conceals. What they say of where their icons are is not believed.
    public func scan(reasons: Set<ScanScheduler.Reason> = [], concealed: Set<String> = []) async -> Inventory {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.performScan(reasons: reasons, concealed: concealed) }
        inFlight = task
        return await task.value
    }

    private func performScan(reasons: Set<ScanScheduler.Reason>, concealed: Set<String>) async -> Inventory {
        defer { inFlight = nil }
        let now = clock.now()
        // Asked every time: the grant can be given or taken away while Mantel runs.
        guard isTrusted() else { return problem(.accessibilityNotGranted, at: now) }
        let running = runningApps()
        guard let agent = running.first(where: { $0.bundleID == MenuBarReader.menuBarAgentBundleID }) else {
            failureStreak += 1
            return problem(.agentNotRunning, at: now)
        }
        let displays = layout()
        noteApps(running, at: now)

        let thorough = reasons.isEmpty || !reasons.isDisjoint(with: [.displaysChanged, .refresh])
        let plan: AgentReadPlan = thorough ? .thorough : reasons.contains(.appsChanged) ? .allWindows : .steady(memory: windowMemory)
        let (toAsk, skipped) = partition(running, now: now)
        let agentReader = agentReader
        async let agentRead = agentReader.read(agent: agent, layout: displays, plan: plan)
        let reads = await readExtras(of: toAsk)
        let bars = await agentRead

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
            case .items, .timedOut:
                recordTimeout(of: read.app, at: now)
                reach.append(AppReach(bundleID: read.app.bundleID ?? "", name: read.app.name, status: .timedOut, readMs: read.milliseconds))
            case .noExtras:
                timeoutStreaks[read.app.pid] = nil
                let young = now.timeIntervalSince(firstSeen[read.app.pid] ?? .distantPast) < Self.youngAppAge
                noExtras[read.app.pid] = (now, young ? Self.youngNoExtrasRecheck : Self.noExtrasRecheck)
            case .notTrusted:
                if !problems.contains(.accessibilityNotGranted) { problems.append(.accessibilityNotGranted) }
            }
        }
        reach.sort { ($0.bundleID, $0.name ?? "") < ($1.bundleID, $1.name ?? "") }

        let input = MatchInput(capturedAt: now, layout: displays, bars: bars.bars, apps: answered, ownBundleID: ownBundleID,
                               reach: reach, problems: problems, concealedApps: concealed)
        let result = InventoryMatcher.matchCounting(input, memory: &memory)
        if result.unmatchedSlots > 0 || result.segmentsNotAligned > 0 {
            Log.logger("inventory").debug("\(result.unmatchedSlots) slots matched no app, \(result.segmentsNotAligned) segments not aligned")
        }
        return result.inventory
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
        guard let agent = runningApps().first(where: { $0.bundleID == MenuBarReader.menuBarAgentBundleID }) else { return nil }
        let agentReader = agentReader, displays = layout()
        return await agentReader.look(agent: agent, layout: displays)
    }

    /// The displays as they are now, which the log names the kind of display by.
    public func currentLayout() -> DisplayLayout {
        layout()
    }

    /// The frames of the menus of this app (its `AXMenuBar` children), in CoreGraphics global points: where the front app's own
    /// menus take room in the bar.
    public func appMenuFrames(pid: pid_t) async -> [CGRect] {
        await agentReader.menuFrames(pid: pid)
    }

    // MARK: Which apps are asked

    /// The apps to ask, and the reach of those left alone because they timed out.
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
            if let known = noExtras[app.pid], now.timeIntervalSince(known.checkedAt) < known.recheckAfter { continue }
            ask.append(app)
        }
        return (ask, skipped)
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
        hasScanned = true
    }

    // MARK: Reading

    private struct AppRead: Sendable {
        let app: RunningApp
        let outcome: ExtrasOutcome
        let milliseconds: Double
    }

    /// Asks the apps, eight at a time, and times each one on the clock.
    private func readExtras(of apps: [RunningApp]) async -> [AppRead] {
        let reader = extrasReader, clock = clock
        return await ConcurrentMap.map(apps, limit: MenuBarReader.concurrency) { app in
            let started = clock.now()
            let outcome = await reader.read(app)
            return AppRead(app: app, outcome: outcome, milliseconds: clock.now().timeIntervalSince(started) * 1000)
        }
    }

    private func problem(_ problem: InventoryProblem, at date: Date) -> Inventory {
        Inventory(capturedAt: date, bars: [], items: [], chevrons: [:], reach: [], problems: [problem])
    }
}
