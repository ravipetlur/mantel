import Foundation
import MKCommands
import MKCore

/// Runs the probes, one at a time where they change something, and writes each one's report.
///
/// - **Reports.** Each probe's report goes to `<root>/Probes/<name>-<yyyyMMdd-HHmmss>.json` and comes back from `run`. A
///   probe that wasn't run (Mantel is quitting, another probe is busy changing the menu bar, a safety rule said no) comes
///   back as a report with its reason in `errors`, and isn't written.
/// - **The probes that change things.** `allowlist-activate`, `approvals-toggle`, `layout-move`, `click-replay`, `reveal-latency`
///   and `approvals-flip` change the person's menu bar for a while (`changesState`, `stateChangingProbes`). Each one:
///   - runs only from the copy in `/Applications` (macOS honours the allowlist for no other copy);
///   - runs only while the person has turned on "Enable platform test" in Settings › Diagnostics (`stateChangingAllowed`; the
///     switch is off at every launch and isn't saved), also when it is asked for from the command line;
///   - is refused while a reset of the menu bar is under way (`resetUnderWay`): the reset puts back the journal and restarts the menu bar's
///     process, in the middle of what the probe measures;
///   - is refused while another of them runs. The probes that only read go on running meanwhile, and are never refused for
///     any of the first three reasons.
/// - **Quitting.** `shutDown()` (the app calls it as quitting begins) refuses anything new, and cancels what runs: a probe
///   that changed something puts it back on its way out, and the journal covers a crash. Requests that were queued on the
///   control socket can still reach `run` after the socket stopped, so `run` checks too.
public actor ProbeRunner {
    private let paths: MantelPaths
    private let reader: MenuBarReader
    private let plist: PlistFileAccess
    private let grants: FileGrantStore
    private let layoutProvider: @Sendable () async -> DisplayLayout
    private let clock: any Clock
    private let platform: ProbePlatform
    private let stateChangingAllowed: @Sendable () -> Bool
    private let resetUnderWay: @Sendable () -> Bool
    private let store: ProbeReportStore

    private var isShuttingDown = false
    /// The probe that is changing the menu bar now, if one is.
    private var changing: ProbeName?
    private var running: [UUID: Task<ProbeReport, Never>] = [:]

    /// - Parameters:
    ///   - platform: everything a probe reaches the system through. There is no default: the app passes `.live`, and a
    ///     test passes its fakes, so that a test that forgets one doesn't run against the real system.
    ///   - stateChangingAllowed: whether the person has turned on "Enable platform test". Asked each time a probe that changes
    ///     the menu bar is about to run. There is no default either: the app passes what its switch says.
    ///   - resetUnderWay: whether a reset of the menu bar is under way (`ResetActivity.isUnderWay`), asked at the same moment. The app
    ///     passes what its reset says; the default is that none is.
    public init(paths: MantelPaths, reader: MenuBarReader, plist: PlistFileAccess, grants: FileGrantStore,
                layoutProvider: @escaping @Sendable () async -> DisplayLayout, clock: any Clock = SystemClock(),
                platform: ProbePlatform, stateChangingAllowed: @escaping @Sendable () -> Bool,
                resetUnderWay: @escaping @Sendable () -> Bool = { false }) {
        self.paths = paths
        self.reader = reader
        self.plist = plist
        self.grants = grants
        self.layoutProvider = layoutProvider
        self.clock = clock
        self.platform = platform
        self.stateChangingAllowed = stateChangingAllowed
        self.resetUnderWay = resetUnderWay
        store = ProbeReportStore(folder: paths.probes)
    }

    /// Whether a probe is changing the person's menu bar right now: what is journaled is then that probe's, and replaying the
    /// journal would undo it from under the probe.
    public var isChangingMenuBar: Bool {
        changing != nil
    }

    /// Whether the probe changes the person's menu bar while it runs.
    public static func changesState(_ name: ProbeName) -> Bool {
        switch name {
        case .allowlistActivate, .approvalsToggle, .layoutMove, .clickReplay, .revealLatency, .approvalsFlip: true
        case .allowlistInfo, .inventory, .approvalsRead, .layoutRead, .capture, .overflow, .screenShare, .menuBarHeight,
             .grantPersistence, .approvalsDecode, .notchCoordinates: false
        }
    }

    /// The probes that change the person's menu bar: the ones that run only from the installed copy, and only while "Enable platform
    /// test" is on.
    public static let stateChangingProbes: [ProbeName] = ProbeName.allCases.filter(changesState)

    // MARK: Running

    /// The text of the refusal when "Enable platform test" is off.
    static let platformTestOffMessage = "Turn on “Enable platform test” in Settings › Diagnostics first."

    /// The text of the refusal while a reset of the menu bar is under way.
    static let resetUnderWayMessage = CommandAnswers.resetUnderWay

    public func run(_ name: ProbeName, options: ProbeOptions) async -> ProbeReport {
        if isShuttingDown { return notRun(name, "Mantel is quitting") }
        let changes = Self.changesState(name)
        if changes {
            // Only the copy in /Applications: macOS honours the allowlist for no other, so a probe from another copy would
            // measure nothing and leave the person's files changed all the same.
            if !platform.isInstalledCopy {
                return notRun(name, "Run this probe from the copy in /Applications. This copy is at \(platform.copyPath).")
            }
            // Not while the menu bar is being reset: that would put back what the probe has changed and restart what it reads.
            if resetUnderWay() { return notRun(name, Self.resetUnderWayMessage) }
            // And only when the person has said so: these change the menu bar, in a way that is seen.
            if !stateChangingAllowed() { return notRun(name, Self.platformTestOffMessage) }
            if changing != nil { return notRun(name, "Another probe is changing the menu bar; try again when it finishes") }
            changing = name
        }
        defer { if changes { changing = nil } }

        let work = Work(paths: paths, reader: reader, plist: plist, grants: grants, layoutProvider: layoutProvider,
                        clock: clock, platform: platform, store: store, options: options)
        let id = UUID()
        let task = Task { await Self.execute(name, work) }
        running[id] = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running[id] = nil
        return keep(report)
    }

    /// Refuses new probes from now on, cancels the ones that run, and returns when they have put back what they changed.
    public func shutDown() async {
        isShuttingDown = true
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
    }

    // MARK: Reports

    /// The newest report of a probe, from the Probes folder (so also one from before a relaunch).
    public func latestReport(of name: ProbeName) -> ProbeReport? {
        store.latest(name)
    }

    public func latestReports() -> [ProbeName: ProbeReport] {
        store.all()
    }

    private func notRun(_ name: ProbeName, _ reason: String) -> ProbeReport {
        ProbeReport(name: name, startedAt: clock.now(), durationMs: 0, environment: [:], measurements: [:], notes: [],
                    restored: true, errors: [reason])
    }

    private func keep(_ report: ProbeReport) -> ProbeReport {
        do {
            try store.save(report)
            return report
        } catch {
            Log.error("probes", "the report of \(report.name.rawValue) couldn't be written: \(error.localizedDescription)")
            return ProbeReport(name: report.name, startedAt: report.startedAt, durationMs: report.durationMs,
                               environment: report.environment, measurements: report.measurements, notes: report.notes,
                               restored: report.restored,
                               errors: report.errors + ["The report couldn't be saved: \(error.localizedDescription)"])
        }
    }

    // MARK: Executing

    /// What a probe is given; the runner's own parts, and the options of this run.
    private struct Work: Sendable {
        let paths: MantelPaths
        let reader: MenuBarReader
        let plist: PlistFileAccess
        let grants: FileGrantStore
        let layoutProvider: @Sendable () async -> DisplayLayout
        let clock: any Clock
        let platform: ProbePlatform
        let store: ProbeReportStore
        let options: ProbeOptions
    }

    /// Runs the probe off the runner, so that the runner can answer other calls (and refuse a second probe that changes
    /// things) while it waits for the system.
    @concurrent
    private static func execute(_ name: ProbeName, _ work: Work) async -> ProbeReport {
        let started = work.clock.now()
        let context = ProbeContext(paths: work.paths, reader: work.reader, plist: work.plist, grants: work.grants,
                                   layoutProvider: work.layoutProvider, clock: work.clock, platform: work.platform,
                                   options: work.options, store: work.store, startedAt: started)
        var recorder = ProbeRecorder()
        Log.info("probes", "\(name.rawValue) starting")
        do {
            try await body(of: name)(context, &recorder)
        } catch let refusal as ProbeRefusal {
            recorder.fail(refusal.message)
        } catch is CancellationError {
            recorder.note("The probe was cut short.")
        } catch {
            recorder.fail(error.localizedDescription)
        }

        var environment = await work.platform.environment()
        environment["displays"] = await work.layoutProvider().fingerprint.uuids.joined(separator: ",")
        let report = ProbeReport(name: name, startedAt: started, durationMs: context.milliseconds(since: started),
                                 environment: environment, measurements: recorder.measurements, notes: recorder.notes,
                                 restored: recorder.restored, errors: recorder.errors)
        Log.info("probes", "\(name.rawValue) finished: \(report.errors.count) errors, restored \(report.restored)")
        return report
    }

    private static func body(of name: ProbeName) -> (ProbeContext, inout ProbeRecorder) async throws -> Void {
        switch name {
        case .allowlistInfo: AllowlistInfoProbe.run
        case .allowlistActivate: AllowlistActivateProbe.run
        case .inventory: InventoryProbe.run
        case .approvalsRead: ApprovalsReadProbe.run
        case .approvalsToggle: ApprovalsToggleProbe.run
        case .layoutRead: LayoutReadProbe.run
        case .layoutMove: LayoutMoveProbe.run
        case .capture: CaptureProbe.run
        case .clickReplay: ClickReplayProbe.run
        case .overflow: OverflowProbe.run
        case .screenShare: ScreenShareProbe.run
        case .menuBarHeight: MenuBarHeightProbe.run
        case .grantPersistence: GrantPersistenceProbe.run
        case .revealLatency: RevealLatencyProbe.run
        case .approvalsDecode: ApprovalsDecodeProbe.run
        case .approvalsFlip: ApprovalsFlipProbe.run
        case .notchCoordinates: NotchCoordinatesProbe.run
        }
    }
}
