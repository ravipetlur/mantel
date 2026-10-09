import CoreGraphics
import Foundation
import MKCommands
import MKCore
import Synchronization

/// What the allowlist probes share.
enum AllowlistSupport {
    /// The bundle IDs to allow so that `hidden` are the only apps concealed: every running app's, but theirs, each once, in
    /// the order the apps came, and `own` (Mantel's) whether it is running or not and whatever `hidden` says. (An allowlist
    /// names the apps that stay; whatever isn't on it is concealed.)
    static func allowedBundleIDs(hiding hidden: Set<String>, running: [ProbePlatform.RunningApp], own: String) -> [String] {
        let hidden = hidden.subtracting([own])
        var seen: Set<String> = []
        var allowed: [String] = []
        for app in running {
            guard let bundleID = app.bundleID, !hidden.contains(bundleID), seen.insert(bundleID).inserted else { continue }
            allowed.append(bundleID)
        }
        if seen.insert(own).inserted { allowed.append(own) }
        return allowed
    }

    /// Every system item (0 to 255) unless the options name which.
    static func systemItems(_ options: ProbeOptions) -> [Int] {
        options.numbers("system-items") ?? Array(0...255)
    }

    /// Why a probe that hides `hidden` mustn't activate an allowlist, or nil: none of them is running. Such an allowlist hides
    /// nothing of theirs, and for the whole hold every system item that isn't on it (the microphone and camera indicators, Now
    /// Playing, Focus), which is a change to the person's menu bar for no measurement at all.
    static func nothingToHide(_ hidden: [String], running: [ProbePlatform.RunningApp], fixture: String) -> String? {
        let runningIDs = Set(running.compactMap(\.bundleID))
        guard !hidden.contains(where: runningIDs.contains) else { return nil }
        let names = hidden.joined(separator: ", ")
        let only = hidden.allSatisfy { $0 == fixture }
        return "Nothing to hide: \(names) \(hidden.count == 1 ? "isn't" : "aren't") running. "
            + (only ? "Open MantelTestItem first." : hidden.count == 1 ? "Open it first." : "Open them first.")
    }
}

/// `allowlist-info`: what the private framework looks like on this Mac. Only reads.
enum AllowlistInfoProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let inspection = context.platform.allowlist.inspect()
        recorder.measure("frameworkLoaded", inspection.frameworkLoaded)
        recorder.measure("classes", .object(inspection.classes.mapValues(JSONValue.bool)))
        recorder.measure("encodings", .object(inspection.encodings.mapValues(JSONValue.string)))
        recorder.measure("problem", inspection.problem.map(JSONValue.string) ?? .null)
        if let problem = inspection.problem {
            recorder.note("Mantel won't call the allowlist: \(problem)")
        }
    }
}

/// `allowlist-activate`: conceals some apps' items for a few seconds and measures how long that takes and how it ends.
///
/// `apps` are the apps to conceal (default: the test item); every other running app stays on the allowlist, background-only
/// ones included, and so does Mantel's own item, whatever `apps` says. Only the test item is touched unless `--allow-any` is
/// given, and hiding system items (a `--system-items` that leaves some of 0 to 255 out) needs it too. Nothing is activated when
/// none of the apps to hide is running.
enum AllowlistActivateProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let options = context.options
        let own = context.platform.ownBundleID
        let requested = options.list("apps")
        // Mantel's own item is never hidden by a probe: its ID is always on the allowlist, whatever `apps` says.
        let concealed = (requested.isEmpty ? [context.fixtureBundleID] : requested).filter { $0 != own }
        if requested.contains(own) { recorder.note(ProbeSafety.ownItemMessage) }
        guard !concealed.isEmpty else {
            recorder.fail("There is nothing to hide: \(ProbeSafety.ownItemMessage)")
            return
        }
        if case .failure(let refusal) = ProbeSafety.permitted(concealed, options: options) {
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
        if let reason = AllowlistSupport.nothingToHide(concealed, running: context.platform.runningApps(), fixture: context.fixtureBundleID) {
            recorder.fail(reason)
            return
        }

        let hold = options.int("hold", default: 5, range: 1...30)
        let allowed = AllowlistSupport.allowedBundleIDs(hiding: Set(concealed), running: context.platform.runningApps(), own: own)
        recorder.measure("concealedApps", strings: concealed)
        recorder.measure("allowedAppCount", allowed.count)
        recorder.measure("systemItemCount", systemItems.count)
        recorder.measure("holdSeconds", hold)

        let beforeSnapshot = await context.snapshot()
        let beforeKeys = ProbeContext.framedKeys(beforeSnapshot)
        let beforeFrames = ProbeContext.framedFrames(beforeSnapshot)
        let started = context.clock.now()
        let assertion: any AllowlistAssertionHandle
        do {
            assertion = try await context.platform.allowlist.activate(systemItems: systemItems, bundleIDs: allowed)
        } catch {
            recorder.fail("The allowlist wasn't activated: \(error.localizedDescription)")
            return
        }
        recorder.changeBegan()
        recorder.measure("activateToCompletionMs", context.milliseconds(since: started))

        var cutShort = false
        do {
            // Two ways of seeing it: a slot that lost its frame (the one that is measured), and, in case macOS keeps a
            // concealed item's old frame, any slot whose frame changed (the items that move up to fill its place).
            var appeared: Double?
            var moved: Double?
            var appearedTrace: PollTrace?
            var movedTrace: PollTrace?
            var tracker = PollTracker()
            let deadline = started.addingTimeInterval(2)
            while appeared == nil || moved == nil {
                try Task.checkCancellation()
                let pollStarted = context.milliseconds(since: started)
                let snapshot = await context.agentSnapshot()
                let elapsed = context.milliseconds(since: started)
                let bounds = tracker.record(startedMs: pollStarted, endedMs: elapsed)
                if appeared == nil, ProbeContext.framedKeys(snapshot) != beforeKeys {
                    appeared = elapsed
                    appearedTrace = tracker.trace(hit: bounds)
                }
                if moved == nil, ProbeContext.framedFrames(snapshot) != beforeFrames {
                    moved = elapsed
                    movedTrace = tracker.trace(hit: bounds)
                }
                if (appeared != nil && moved != nil) || context.clock.now() >= deadline { break }
                try await context.clock.sleep(for: .milliseconds(25))
            }
            recorder.measure("activateToVisibleChangeMs", appeared.map(JSONValue.number) ?? .null)
            recorder.measure("activateToFrameChangeMs", moved.map(JSONValue.number) ?? .null)
            recorder.measure(poll: "activateToVisibleChange", appearedTrace ?? tracker.trace(hit: nil))
            recorder.measure(poll: "activateToFrameChange", movedTrace ?? tracker.trace(hit: nil))
            if appeared == nil {
                recorder.note(moved == nil
                    ? "There was no visible change within 2 s of activating."
                    : "No slot lost its frame within 2 s of activating, but some moved: macOS may keep a concealed item's old frame.")
            }
            try await context.clock.sleep(for: .seconds(hold))
            let duringKeys = ProbeContext.framedKeys(await context.snapshot())
            recorder.measure("concealedSlots", strings: beforeKeys.subtracting(duringKeys).sorted())
        } catch {
            cutShort = true
            recorder.note("The probe was cut short; the allowlist was released.")
        }

        // Whatever happened above, it is let go.
        let released = context.clock.now()
        assertion.invalidate()
        guard !cutShort else {
            recorder.changeUndone()
            return
        }
        do {
            let running = context.platform.runningApps
            let outcome = try await context.poll(every: 25, upTo: 2000, from: released, until: {
                ProbeContext.isRestored(before: beforeSnapshot, now: $0, running: running())
            })
            recorder.measure(poll: "invalidateToRestore", outcome.trace)
            if let back = outcome.hit {
                recorder.measure("invalidateToRestoreMs", back.elapsedMs)
                recorder.measure("restored", true)
                recorder.changeUndone()
            } else {
                recorder.measure("invalidateToRestoreMs", .null)
                recorder.measure("restored", false)
                recorder.undoFailed("The menu bar didn't come back within 2 s of releasing the allowlist.")
            }
        } catch {
            recorder.note("The probe was cut short; the allowlist was released.")
            recorder.changeUndone()
        }
    }
}

/// The allowlist assertion that is live, held where the tap's click callback can reach it: the callback lifts it at the moment a
/// click is held. Both calls are safe from any thread, and the call into the allowlist is made outside the lock.
final class LiftableAllowlist: Sendable {
    private let live = Mutex<(any AllowlistAssertionHandle)?>(nil)

    /// A new assertion is live.
    func arm(_ assertion: any AllowlistAssertionHandle) {
        live.withLock { $0 = assertion }
    }

    /// Invalidates the assertion that is live, if one is. True when there was one.
    @discardableResult
    func lift() -> Bool {
        let taken = live.withLock { assertion -> (any AllowlistAssertionHandle)? in
            defer { assertion = nil }
            return assertion
        }
        taken?.invalidate()
        return taken != nil
    }
}

/// The clicks the tap has held, each with when it was held, when the allowlist was lifted for it and when it was replayed.
final class ClickLog: Sendable {
    struct Click: Sendable {
        let point: CGPoint
        let clickAt: Date
        /// nil when no allowlist was live to lift: a click that comes while the one before it is still being watched.
        let liftedAt: Date?
        var replayedAt: Date?
    }

    private struct State {
        var clicks: [Click] = []
        /// How many of them the probe has looked at.
        var taken = 0
    }

    private let state = Mutex(State())

    func clicked(_ point: CGPoint, at clickAt: Date, liftedAt: Date?) {
        state.withLock { $0.clicks.append(Click(point: point, clickAt: clickAt, liftedAt: liftedAt, replayedAt: nil)) }
    }

    /// The oldest click that hasn't been replayed yet has been: replays come in the order of the clicks, each `delay` after.
    func replayed(at date: Date) {
        state.withLock { state in
            if let index = state.clicks.firstIndex(where: { $0.replayedAt == nil }) { state.clicks[index].replayedAt = date }
        }
    }

    /// The oldest click nobody has looked at, and its place.
    func next() -> (index: Int, click: Click)? {
        state.withLock { state in
            guard state.taken < state.clicks.count else { return nil }
            defer { state.taken += 1 }
            return (state.taken, state.clicks[state.taken])
        }
    }

    /// A click as it is now (its replay may have come since it was taken).
    func click(at index: Int) -> Click {
        state.withLock { $0.clicks[index] }
    }
}

/// `click-replay`: conceals the test item, holds clicks on the clock, lifts the allowlist for each and replays the click, and
/// records whether Notification Center opened.
///
/// While any allowlist is live the system ignores clicks on the clock and Notification Center. The tap holds a click and, in its
/// own callback, before it schedules the replay, lifts the allowlist (invalidates it); the replay follows `delay` ms later.
/// The probe watches for a second for a new Notification Center window, and activates the allowlist again. Ends after 30
/// seconds or 5 clicks. Nothing is activated when the app to hide isn't running.
///
/// Each click is recorded with `delayMs` (the configured delay), `clickAt`, `liftedAt` and `replayedAt` (milliseconds after the
/// probe started), `liftToReplayMs` (how long the system had between the lift and the click coming back) and `opened`. A click
/// that came while the allowlist was already lifted (a second click during the watch) has no lift, no `liftToReplayMs` and no
/// `opened`; neither has one that came in the instant between an activation returning and the probe holding it.
enum ClickReplayProbe {
    static let notificationCenter = "com.apple.notificationcenterui"

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
        if let reason = AllowlistSupport.nothingToHide([app], running: context.platform.runningApps(), fixture: context.fixtureBundleID) {
            recorder.fail(reason)
            return
        }

        let delay = options.int("delay", default: 100, range: 20...400)
        recorder.measure("delayMs", delay)
        let before = await context.snapshot()
        guard let clockFrame = clockFrame(in: before) else {
            recorder.fail("No slot of the clock with a frame was found in the menu bar, so there is nothing to click. Run the inventory probe to see what is there.")
            return
        }

        let allowed = AllowlistSupport.allowedBundleIDs(hiding: [app], running: context.platform.runningApps(), own: own)
        let allowlist = LiftableAllowlist()
        do {
            allowlist.arm(try await context.platform.allowlist.activate(systemItems: systemItems, bundleIDs: allowed))
        } catch {
            recorder.fail("The allowlist wasn't activated: \(error.localizedDescription)")
            return
        }
        recorder.changeBegan()

        // The tap's thread: the lift is the first thing done about a click, and the replay isn't scheduled until it has returned.
        let log = ClickLog()
        let clock = context.clock
        let tap = context.platform.makeClickTap([clockFrame], .milliseconds(delay), .seconds(30), { point in
            let clickAt = clock.now()
            let liftedAt = allowlist.lift() ? clock.now() : nil
            log.clicked(point, at: clickAt, liftedAt: liftedAt)
        }, { _ in
            log.replayed(at: clock.now())
        })

        var clicks: [JSONValue] = []
        var cutShort = false
        do {
            // The windows Notification Center has while nobody is clicking: what a new one is told from.
            var baseline = context.platform.windows.onScreenWindows(ownedBy: notificationCenter)
            try tap.start()
            let deadline = context.clock.now().addingTimeInterval(30)
            while clicks.count < 5, context.clock.now() < deadline {
                guard let (index, held) = log.next() else {
                    try await context.clock.sleep(for: .milliseconds(20))
                    continue
                }
                guard held.liftedAt != nil else {
                    // Nothing was live to lift for this one, and nothing is to be put back.
                    clicks.append(record(held, delay: delay, opened: nil, since: context.startedAt))
                    continue
                }
                let opened = try await watchForNewWindow(context, baseline: baseline)
                // The replay came `delay` ms after the click, well inside the second that was watched.
                clicks.append(record(log.click(at: index), delay: delay, opened: opened, since: context.startedAt))
                allowlist.arm(try await context.platform.allowlist.activate(systemItems: systemItems, bundleIDs: allowed))
                baseline = context.platform.windows.onScreenWindows(ownedBy: notificationCenter)
            }
        } catch is CancellationError {
            cutShort = true
            recorder.note("The probe was cut short; the tap and the allowlist were released.")
        } catch let error as ClickReplayError {
            recorder.fail(error.localizedDescription)
        } catch {
            recorder.fail("The probe stopped: \(error.localizedDescription)")
        }
        recorder.measure("clicks", .array(clicks))
        if !clicks.isEmpty {
            recorder.note("clickAt, liftedAt and replayedAt are milliseconds after the probe started.")
        }

        // Everything is let go.
        tap.stop()
        let released = context.clock.now()
        allowlist.lift()
        guard !cutShort else {
            recorder.changeUndone()
            return
        }
        do {
            let running = context.platform.runningApps
            if try await context.poll(every: 25, upTo: 2000, from: released, until: {
                ProbeContext.isRestored(before: before, now: $0, running: running())
            }).hit != nil {
                recorder.changeUndone()
            } else {
                recorder.undoFailed("The menu bar didn't come back within 2 s of releasing the allowlist.")
            }
        } catch {
            recorder.changeUndone()
        }
    }

    /// One click as the report has it: the configured delay, and when it was held, lifted and replayed, in milliseconds after
    /// the probe started, with the time between the lift and the replay.
    private static func record(_ click: ClickLog.Click, delay: Int, opened: Bool?, since start: Date) -> JSONValue {
        func offset(_ date: Date?) -> JSONValue { date.map { .number($0.timeIntervalSince(start) * 1000) } ?? .null }
        var liftToReplay = JSONValue.null
        if let lifted = click.liftedAt, let replayed = click.replayedAt {
            liftToReplay = .number(replayed.timeIntervalSince(lifted) * 1000)
        }
        return .object(["delayMs": .number(Double(delay)), "clickAt": offset(click.clickAt), "liftedAt": offset(click.liftedAt),
                        "replayedAt": offset(click.replayedAt), "liftToReplayMs": liftToReplay,
                        "opened": opened.map(JSONValue.bool) ?? .null])
    }

    /// The clock's slot with a frame, taken from the first display that has one.
    private static func clockFrame(in snapshot: MenuBarSnapshot) -> CGRect? {
        for slot in snapshot.allSlots {
            if let identifier = slot.identifier, identifier.lowercased().hasSuffix("clock"), let frame = slot.frame, !frame.isEmpty {
                return frame
            }
        }
        return nil
    }

    /// Whether a window that wasn't there opens, within a second: polled every 25 ms.
    private static func watchForNewWindow(_ context: ProbeContext, baseline: Set<Int>) async throws -> Bool {
        let started = context.clock.now()
        while true {
            if !context.platform.windows.onScreenWindows(ownedBy: notificationCenter).subtracting(baseline).isEmpty { return true }
            if context.clock.now().timeIntervalSince(started) >= 1 { return false }
            try await context.clock.sleep(for: .milliseconds(25))
        }
    }
}
