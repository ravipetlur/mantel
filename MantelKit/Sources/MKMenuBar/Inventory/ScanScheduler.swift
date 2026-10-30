import Foundation
import MKCore

/// Decides when the menu bar is read again.
///
/// - **Requests** come from whatever notices a change: an app launching or quitting, the displays changing, a reveal, the person
///   asking for a refresh. Those that come within 100 ms of the first are one scan, which is told all their reasons. A refresh or a
///   reveal doesn't wait for that.
/// - **Polling** asks for a scan every 10 seconds, or every 2 seconds while Settings is open, for what nothing announces.
/// - **One scan at a time.** What is asked for while a scan runs is one more scan after it.
///
/// Every wait goes through the clock, so a test moves time itself.
public actor ScanScheduler {
    /// Why a scan is wanted, for the log and for what the scan then does.
    public enum Reason: String, Sendable {
        case appsChanged, displaysChanged, reveal, refresh, trial, poll
        /// A read that checks the bar against a layout write, and one that follows a ⌘-drag: each is waited for.
        case layoutCheck, layoutFollow

        /// The reasons that are acted on at once, not after the wait that lets requests that come together be one scan.
        fileprivate var isImmediate: Bool {
            switch self {
            case .reveal, .refresh, .layoutCheck, .layoutFollow: true
            case .appsChanged, .displaysChanged, .trial, .poll: false
            }
        }
    }

    public static let idleInterval: Duration = .seconds(10)
    public static let settingsInterval: Duration = .seconds(2)
    public static let coalescing: Duration = .milliseconds(100)

    private let clock: any Clock
    private let scan: @Sendable (Set<Reason>) async -> Void

    private var pending: Set<Reason> = []
    private var isScanning = false
    private var settingsOpen = false
    private var isStopped = false
    private var coalescingTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    /// - Parameter scan: runs one scan, given the reasons it was asked for. It is never called twice at once.
    public init(clock: any Clock, scan: @escaping @Sendable (Set<Reason>) async -> Void) {
        self.clock = clock
        self.scan = scan
    }

    /// Asks for a scan. Ignored after `stop()`, until `start()`.
    public func request(_ reason: Reason) {
        guard !isStopped else { return }
        pending.insert(reason)
        if reason.isImmediate {
            coalescingTask?.cancel()
            coalescingTask = nil
            runPending()
        } else if coalescingTask == nil {
            coalescingTask = Task { [clock] in
                do { try await clock.sleep(for: Self.coalescing) } catch { return }
                self.coalescingElapsed()
            }
        }
    }

    /// Settings opened or closed: the polling goes at the pace that suits.
    public func setSettingsOpen(_ open: Bool) {
        guard open != settingsOpen else { return }
        settingsOpen = open
        if pollingTask != nil { startPolling() }
    }

    /// Starts polling.
    public func start() {
        isStopped = false
        startPolling()
    }

    /// Whether polling is set going. For tests.
    var isPolling: Bool { pollingTask != nil }

    /// Stops polling and drops what was waiting for a scan. A scan that is running finishes.
    public func stop() {
        isStopped = true
        pollingTask?.cancel()
        pollingTask = nil
        coalescingTask?.cancel()
        coalescingTask = nil
        pending = []
    }

    /// Returns once no scan is running or about to. For a test that has to know a scan is over before it asks for the next.
    func waitUntilIdle() async {
        while isScanning, !Task.isCancelled { await Task.yield() }
    }

    // MARK: Inside

    private func startPolling() {
        pollingTask?.cancel()
        let interval = settingsOpen ? Self.settingsInterval : Self.idleInterval
        pollingTask = Task { [clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                self.request(.poll)
            }
        }
    }

    private func coalescingElapsed() {
        coalescingTask = nil
        runPending()
    }

    /// Runs the scans that are asked for, one after the other, until none is. A request that comes while one runs is picked up
    /// here, as one scan with all its reasons.
    private func runPending() {
        guard !isScanning, !pending.isEmpty else { return }
        isScanning = true
        Task {
            await self.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty, !isStopped {
            let reasons = pending
            pending = []
            await scan(reasons)
        }
        isScanning = false
    }
}
