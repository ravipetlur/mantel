import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// A list of times in milliseconds (a time that wasn't measured is nil), and what is said of the ones that were: the middle one, the
/// one that 19 in 20 are at or under, and the longest. (Nearest rank: with fewer than 20 times the 95th is the longest.)
struct LatencyStats: Equatable {
    let values: [Double?]

    private var measured: [Double] { values.compactMap { $0 } }
    var p50: Double? { percentile(0.5) }
    var p95: Double? { percentile(0.95) }
    var max: Double? { measured.max() }

    private func percentile(_ fraction: Double) -> Double? {
        let sorted = measured.sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
    }

    /// `{count, p50, p95, max}`, and with `includingValues` the times themselves in the order they were measured, `null` for one that
    /// wasn't.
    func json(includingValues: Bool = true) -> JSONValue {
        func number(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
        var object: [String: JSONValue] = ["count": .number(Double(measured.count)), "p50": number(p50), "p95": number(p95), "max": number(max)]
        if includingValues { object["values"] = .array(values.map(number)) }
        return .object(object)
    }
}

/// The allowlist assertions a probe has made and not let go of, so that whatever happens to the probe, they are let go.
private final class HeldAssertions {
    private var held: [any AllowlistAssertionHandle] = []

    func add(_ assertion: any AllowlistAssertionHandle) {
        held.append(assertion)
    }

    func releaseAll() {
        let all = held
        held = []
        for assertion in all { assertion.invalidate() }
    }
}

/// `reveal-latency`: how long it takes for one app's items to be concealed by an allowlist, and to come back, in the two ways
/// they can: by a new allowlist that allows every app (activated before the old one is let go of), and by letting the old one go.
///
/// - **What is read.** Only that app's own extras menu bar, every 10 ms: `MenuBarReader.extrasFrames(ofPID:)`. MenuBarAgent is
///   never read while a time is being taken (one read of its windows costs about 550 ms, which would be what was measured).
/// - **Each run**, `runs` of them (1 to 20, 10 by default): an allowlist without the app is activated and the frames are polled until
///   they differ from what they were (`hideMs`); then they are revealed, by a new allowlist that allows every running app in the
///   even runs (`revealSwapMs`: the new assertion is live before the old one is invalidated) and by invalidating in the odd ones
///   (`revealReleaseMs`), and the frames are polled until they are within 2 points of what they were. 2 seconds for each phase; a
///   phase that doesn't finish is `null` in the list and said in the notes.
/// - **Times** are from just before the call that changes the allowlist to the end of the poll that saw the change, so they include
///   the call. `pollReadMs` is what one read of the app's frames cost.
/// - **Always let go.** Every assertion the probe made is invalidated on every way out of it, a cancelled run included, and the
///   probe says whether the items came back (`restored`).
///
/// `app` is the test item unless `--allow-any` is given; it is never Mantel's own item, and system items are never hidden.
enum RevealLatencyProbe {
    static let pollInterval: Duration = .milliseconds(10)
    /// How long each phase of a run is given, in milliseconds.
    static let phaseTimeoutMs = 2000.0
    /// How far an item's frame may be from what it was and still count as back, in points.
    static let tolerance: CGFloat = 2
    /// How long the menu bar is left to settle between runs.
    static let settle: Duration = .milliseconds(250)

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let options = context.options
        let app = options.string("app") ?? context.fixtureBundleID
        let own = context.platform.ownBundleID
        guard app != own else {
            recorder.fail(ProbeSafety.ownItemMessage)
            return
        }
        if case .failure(let refusal) = ProbeSafety.permitted([app], options: options) {
            recorder.fail(refusal.message)
            return
        }
        let systemItems = AllowlistSupport.systemItems(options)
        if case .failure(let refusal) = ProbeSafety.permittedSystemItems(systemItems, options: options) {
            recorder.fail(refusal.message)
            return
        }
        let inspection = context.platform.allowlist.inspect()
        if let problem = inspection.problem {
            recorder.fail("macOS's allowlist wasn't called: \(problem)")
            return
        }
        let running = context.platform.runningApps()
        if let reason = AllowlistSupport.nothingToHide([app], running: running, fixture: context.fixtureBundleID) {
            recorder.fail(reason)
            return
        }
        guard let pid = running.first(where: { $0.bundleID == app })?.pid,
              let baseline = context.reader.extrasFrames(ofPID: pid), !baseline.isEmpty else {
            recorder.fail("\(app) has no items in the menu bar to watch. Open it, and see that it has one, first.")
            return
        }
        let runs = options.int("runs", default: 10, range: 1...20)
        recorder.measure("app", app)
        recorder.measure("runs", runs)
        recorder.measure("baselineItemCount", baseline.count)
        recorder.measure("baselineFrames", .array(baseline.map { $0.map(NotchCoordinatesProbe.rect) ?? .null }))

        var series = Series()
        let held = HeldAssertions()
        do {
            for index in 0..<runs {
                try await oneRun(index, context, pid: pid, app: app, baseline: baseline, systemItems: systemItems, held: held,
                                 into: &series, recorder: &recorder)
                try await context.clock.sleep(for: settle)
            }
        } catch is CancellationError {
            recorder.note("The probe was cut short; the allowlist was released.")
        } catch {
            recorder.fail("The probe stopped: \(error.localizedDescription)")
        }

        // Whatever happened above, everything is let go.
        held.releaseAll()
        recorder.measure("hideMs", LatencyStats(values: series.hide).json())
        recorder.measure("revealSwapMs", LatencyStats(values: series.revealSwap).json())
        recorder.measure("revealReleaseMs", LatencyStats(values: series.revealRelease).json())
        recorder.measure("pollReadMs", LatencyStats(values: series.reads).json(includingValues: false))
        let hideTimeouts = series.hide.filter { $0 == nil }.count
        let revealTimeouts = (series.revealSwap + series.revealRelease).filter { $0 == nil }.count
        if hideTimeouts + revealTimeouts > 0 {
            recorder.note("\(hideTimeouts) runs didn't see the items concealed, and \(revealTimeouts) didn't see them back, within 2 s; each is null in its list.")
        }
        recorder.note("The times are from just before the call that changed the allowlist to the end of the read that saw the change.")

        // A run that was cut short, or that failed, left its change to be put back: it is let go, and the items are waited for.
        if series.hasOpenChange {
            do {
                if try await waitUntilBack(context, pid: pid, baseline: baseline, since: context.clock.now()) != nil {
                    recorder.changeUndone()
                } else {
                    recorder.undoFailed("The items didn't come back within 2 s of releasing the allowlist.")
                }
            } catch {
                recorder.changeUndone()
            }
        }
        recorder.measure("restored", recorder.restored)
    }

    // MARK: One run

    private struct Series {
        /// The time of each run, nil for one that didn't see the change in time.
        var hide: [Double?] = []
        var revealSwap: [Double?] = []
        var revealRelease: [Double?] = []
        var reads: [Double?] = []
        /// Whether a change was made and not yet seen to be undone.
        var hasOpenChange = false
    }

    private static func oneRun(_ index: Int, _ context: ProbeContext, pid: pid_t, app: String, baseline: [CGRect?],
                               systemItems: [Int], held: HeldAssertions, into series: inout Series,
                               recorder: inout ProbeRecorder) async throws {
        let platform = context.platform
        let own = platform.ownBundleID
        let hiding = AllowlistSupport.allowedBundleIDs(hiding: [app], running: platform.runningApps(), own: own)

        // Conceal.
        let concealStarted = context.clock.now()
        let first = try await platform.allowlist.activate(systemItems: systemItems, bundleIDs: hiding)
        held.add(first)
        recorder.changeBegan()
        series.hasOpenChange = true
        series.hide.append(try await poll(context, pid: pid, since: concealStarted, series: &series) { !matches($0, baseline) })

        // Reveal: even runs swap, odd runs release.
        let swap = index.isMultiple(of: 2)
        let revealStarted = context.clock.now()
        if swap {
            let everyApp = AllowlistSupport.allowedBundleIDs(hiding: [], running: platform.runningApps(), own: own)
            held.add(try await platform.allowlist.activate(systemItems: systemItems, bundleIDs: everyApp))
        }
        first.invalidate()
        let back = try await poll(context, pid: pid, since: revealStarted, series: &series) { matches($0, baseline) }
        if swap { series.revealSwap.append(back) } else { series.revealRelease.append(back) }
        // The allowlist that revealed them (swap) is let go of too, so that the next run starts from nothing live.
        held.releaseAll()
        series.hasOpenChange = false
        if back == nil {
            recorder.undoFailed("The items didn't come back within 2 s in run \(index + 1).")
        } else {
            recorder.changeUndone()
        }
    }

    /// Reads the app's frames every 10 ms from `start` until `condition` holds of them: the milliseconds from `start` to the end of
    /// the read that saw it, or nil after the timeout (2 s). A read that gave nothing (the app didn't answer) is not a reading.
    private static func poll(_ context: ProbeContext, pid: pid_t, since start: Date, series: inout Series,
                             until condition: ([CGRect?]) -> Bool) async throws -> Double? {
        try await pollFrames(context, pid: pid, since: start, timeoutMs: phaseTimeoutMs, reads: &series.reads, until: condition)
    }

    /// The same, with its own timeout, and the cost of each read given back in `reads`.
    static func pollFrames(_ context: ProbeContext, pid: pid_t, since start: Date, timeoutMs: Double, reads: inout [Double?],
                           until condition: ([CGRect?]) -> Bool) async throws -> Double? {
        while true {
            try Task.checkCancellation()
            let began = context.clock.now()
            let frames = context.reader.extrasFrames(ofPID: pid)
            let ended = context.clock.now()
            reads.append(ended.timeIntervalSince(began) * 1000)
            if let frames, condition(frames) { return ended.timeIntervalSince(start) * 1000 }
            if ended.timeIntervalSince(start) * 1000 >= timeoutMs { return nil }
            try await context.clock.sleep(for: pollInterval)
        }
    }

    /// Waits for the frames to be what they were, once everything has been let go.
    private static func waitUntilBack(_ context: ProbeContext, pid: pid_t, baseline: [CGRect?], since start: Date) async throws -> Double? {
        var ignored = Series()
        return try await poll(context, pid: pid, since: start, series: &ignored) { matches($0, baseline) }
    }

    /// Whether the frames are the baseline's: as many, each within `tolerance` points of it (an item with no frame only matches
    /// another).
    static func matches(_ frames: [CGRect?], _ baseline: [CGRect?]) -> Bool {
        guard frames.count == baseline.count else { return false }
        return zip(frames, baseline).allSatisfy { frame, original in
            switch (frame, original) {
            case (nil, nil): true
            case (let frame?, let original?):
                abs(frame.minX - original.minX) <= tolerance && abs(frame.minY - original.minY) <= tolerance
                    && abs(frame.width - original.width) <= tolerance && abs(frame.height - original.height) <= tolerance
            default: false
            }
        }
    }
}
