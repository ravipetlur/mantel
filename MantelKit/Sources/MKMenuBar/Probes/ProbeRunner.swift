import Foundation
import MKCommands
import MKCore

/// Runs the probes, one at a time where they change something, and writes each one's report.
///
/// - **Reports.** Each probe's report goes to `<root>/Probes/<name>-<yyyyMMdd-HHmmss>.json` and comes back from `run`. A
///   probe that wasn't run (Mantel is quitting, another probe is busy changing the menu bar, the safety rule said no) comes
///   back as a report with its reason in `errors`, and isn't written.
/// - **One that changes things at a time.** `allowlist-activate`, `approvals-toggle`, `layout-move` and `click-replay`
///   change the person's menu bar for a while; a second of them while one runs is refused. The probes that only read go on
///   running meanwhile.
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
    private let store: ProbeReportStore

    private var isShuttingDown = false
    /// The probe that is changing the menu bar now, if one is.
    private var changing: ProbeName?
    private var running: [UUID: Task<ProbeReport, Never>] = [:]

    /// - Parameter platform: everything a probe reaches the system through. There is no default: the app passes `.live`, and a
    ///   test passes its fakes, so that a test that forgets one doesn't run against the real system.
    public init(paths: MantelPaths, reader: MenuBarReader, plist: PlistFileAccess, grants: FileGrantStore,
                layoutProvider: @escaping @Sendable () async -> DisplayLayout, clock: any Clock = SystemClock(),
                platform: ProbePlatform) {
        self.paths = paths
        self.reader = reader
        self.plist = plist
        self.grants = grants
        self.layoutProvider = layoutProvider
        self.clock = clock
        self.platform = platform
        store = ProbeReportStore(folder: paths.probes)
    }

    /// Whether the probe changes the person's menu bar while it runs.
    public static func changesState(_ name: ProbeName) -> Bool {
        switch name {
        case .allowlistActivate, .approvalsToggle, .layoutMove, .clickReplay: true
        case .allowlistInfo, .inventory, .approvalsRead, .layoutRead, .capture, .overflow, .screenShare, .menuBarHeight,
             .grantPersistence: false
        }
    }

    /// The probes that change the person's menu bar: the ones that run only from the installed copy.
    public static let stateChangingProbes: [ProbeName] = ProbeName.allCases.filter(changesState)

    // MARK: Running

    public func run(_ name: ProbeName, options: ProbeOptions) async -> ProbeReport {
        if isShuttingDown { return notRun(name, "Mantel is quitting") }
        let changes = Self.changesState(name)
        if changes {
            // Only the copy in /Applications: macOS honours the allowlist for no other, so a probe from another copy would
            // measure nothing and leave the person's files changed all the same.
            if !platform.isInstalledCopy {
                return notRun(name, "Run this probe from the copy in /Applications. This copy is at \(platform.copyPath).")
            }
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
        }
    }
}
