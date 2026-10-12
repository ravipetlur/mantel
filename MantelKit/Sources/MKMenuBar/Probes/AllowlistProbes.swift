import CoreGraphics
import Foundation
import MKCommands
import MKCore
import Synchronization

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
            // The items that were on a bar and aren't while the allowlist is held, by their IDs: both snapshots have the apps' own lists.
            let shownBefore = ProbeContext.shownItems(beforeSnapshot, ownBundleID: own)
            let shownDuring = ProbeContext.shownItems(await context.snapshot(), ownBundleID: own)
            recorder.measure("concealedSlots", strings: shownBefore.subtracting(shownDuring).sorted())
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
/// records whether Notification Center, which the clock opens, opened.
///
/// While any allowlist is live the system ignores clicks on the clock and Notification Center. The tap holds a click and, in its
/// own callback, before it schedules the replay, lifts the allowlist (invalidates it); the replay follows `delay` ms later.
/// The tap sits on the clock's slot on every display, one for each (a click on the clock of any of them is held). The probe
/// then watches for the panel, which is a window of Notification Center that covers a display (`OpenedSystemUI.isOpen`, given the
/// frames of the current layout's displays), for a second after the replay, reading the window list every 50 ms, and activates the allowlist
/// again. Ends after 30 seconds or 5 clicks. Nothing is activated when the app to hide isn't running, and none when Notification
/// Center is open when the tap is about to start (it would count for every click).
///
/// Each click is recorded with `delayMs` (the configured delay), `clickAt`, `liftedAt` and `replayedAt` (milliseconds after the
/// probe started), `liftToReplayMs` (how long the system had between the lift and the click coming back) and `opened`. A click
/// that came while the allowlist was already lifted (a second click during the watch) has no lift, no `liftToReplayMs` and no
/// `opened`; neither has one that came in the instant between an activation returning and the probe holding it.
enum ClickReplayProbe {
    /// How often the window list is read while a replay is watched.
    static let watchInterval: Duration = .milliseconds(50)

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
        let clockFrames = clockFrames(in: before)
        guard !clockFrames.isEmpty else {
            recorder.fail("No slot of the clock with a frame was found in the menu bar, so there is nothing to click. Run the inventory probe to see what is there.")
            return
        }
        recorder.measure("clockSlots", clockFrames.count)

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
        let tap = context.platform.makeClickTap(clockFrames, .milliseconds(delay), .seconds(30), { point in
            let clickAt = clock.now()
            let liftedAt = allowlist.lift() ? clock.now() : nil
            log.clicked(point, at: clickAt, liftedAt: liftedAt)
        }, { _ in
            log.replayed(at: clock.now())
        })

        var clicks: [JSONValue] = []
        var cutShort = false
        do {
            // A panel that is open before the first click would count for every click.
            if OpenedSystemUI.isOpen(context.platform.windowList.onScreenWindows(), displays: await displayFrames(context)) {
                throw ProbeRefusal(message: "Notification Center is open. Close it, and run the probe again.")
            }
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
                let opened = try await watchForPanel(context, log: log, index: index, delay: delay)
                clicks.append(record(log.click(at: index), delay: delay, opened: opened, since: context.startedAt))
                allowlist.arm(try await context.platform.allowlist.activate(systemItems: systemItems, bundleIDs: allowed))
            }
        } catch is CancellationError {
            cutShort = true
            recorder.note("The probe was cut short; the tap and the allowlist were released.")
        } catch let refusal as ProbeRefusal {
            recorder.fail(refusal.message)
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

    /// The clock's slots that have a frame, one for each display that has one (each of MenuBarAgent's windows is a display's), left to
    /// right; two displays' clocks never share a frame.
    static func clockFrames(in snapshot: MenuBarSnapshot) -> [CGRect] {
        var frames: [CGRect] = []
        for window in snapshot.agentWindows {
            for slot in window.slots {
                if let identifier = slot.identifier, identifier.lowercased().hasSuffix("clock"), let frame = slot.frame, !frame.isEmpty,
                   !frames.contains(frame) {
                    frames.append(frame)
                }
            }
        }
        return frames
    }

    /// The frames of the displays of the current layout, as CoreGraphics says them (the layout keeps AppKit's): the window list's bounds
    /// are in those points.
    private static func displayFrames(_ context: ProbeContext) async -> [CGRect] {
        let layout = await context.layoutProvider()
        return layout.displays.map { layout.cgRect(fromAppKit: $0.frame) }
    }

    /// Whether the panel opens: the window list is read every 50 ms from the click until it has been replayed, and then for a second
    /// more, and the click opened it if `OpenedSystemUI.isOpen` holds at any read after the replay. (A read before the replay
    /// can't be the click's: the panel was closed when the probe began.)
    private static func watchForPanel(_ context: ProbeContext, log: ClickLog, index: Int, delay: Int) async throws -> Bool {
        var watchEnds: Date?
        let displays = await displayFrames(context)
        // If the replay never reports, the watch is given the delay and the second after it from the click.
        let fallback = log.click(at: index).clickAt.addingTimeInterval(Double(delay) / 1000 + 1)
        while true {
            if let replayed = log.click(at: index).replayedAt {
                if watchEnds == nil { watchEnds = replayed.addingTimeInterval(1) }
                if OpenedSystemUI.isOpen(context.platform.windowList.onScreenWindows(), displays: displays) { return true }
            }
            if context.clock.now() >= (watchEnds ?? fallback) { return false }
            try await context.clock.sleep(for: watchInterval)
        }
    }
}
