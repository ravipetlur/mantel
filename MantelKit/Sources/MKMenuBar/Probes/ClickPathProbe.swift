import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout
import Synchronization

/// `click-path`: what clicking an icon that macOS isn't drawing comes to. The item starts concealed (in Hidden); each run asks macOS to
/// draw it for a moment, finds where it is, clicks it one way, and records what came of that.
///
/// - **Options.** `item`: `one` (the default), `two`, `extra.<n>` (the test item's), or with `--allow-any` an item ID (`system:wifi`).
///   `kind`: `left` (the default), `right` or `option`. `route`: `press` (the default: an Accessibility press), `post` (a click posted at
///   the slot's centre) or `showMenu` (`AXShowMenu`). `runs`: 1 to 10, 5 by default.
/// - **It refuses** unless the item is concealed when it begins: a click is no measurement of a path that has nothing to find.
/// - **Each run:**
///   1. the slots that are drawn are noted (`slotSnapshot`);
///   2. an allowlist that names the item's app and Mantel's own, and every system item, is activated. A system allowlist is the union of the
///      ones that are live, so the item is drawn beside what Mantel's own shows, and the rest of Hidden stays hidden;
///   3. the item is looked for every 25 ms for 2 s: `locatedMs` is when any slot came back, and `drawnMs` when one came back that a click
///      may be posted at (`ItemLocation.isPostable`, the one place that decides it: this probe never reads how it was tied to decide). What
///      the last answer said is recorded: `tiedBy`, `slotWasInBaseline`, `widthAgrees`, `frameMinusSlotWidth` (how much wider the item's own
///      frame is than its slot: nil when the app reports none), the slot, and whether it is out of the way (`BarRegion`);
///   4. the click goes by the route: a press presses (when no slot can be clicked too: `pressedInPlace`), a post posts at the slot's centre
///      and is skipped when none can be, and `showMenu` performs `AXShowMenu`. A press and an `AXShowMenu` are not waited for: an item whose
///      action opens a menu doesn't answer until the menu closes (or the call times out), so they go out and the menu is watched for while
///      they are out. One that has not returned when the menu shows, or that timed out, was pressed all the same
///      (`pressAnswered` false, `pressReturnedMs` when it did return, after the menu was closed; an error is recorded only for one that
///      failed outright);
///   5. the window list is read every 25 ms for 1.5 s for a window of the item's app that wasn't there before, at a level of 0 or more:
///      `menuMs`, `menuLayer`, `menuFrame`, `menuNearItem` (its left within 60 points of the slot's, its top within 8 of the bar's bottom)
///      and `menuOnScreen`;
///   6. what the test item says it received (`kindReceived`: nil for another item, and for no record newer than the click);
///   7. Escape is posted, and the window is watched until it goes (`closedMs`). It is posted whenever a click was made, and also when no
///      window was seen: a menu the window list doesn't show would stay open. A run that is cut short after the click posts it on the way
///      out, once: a menu that opened would stay open otherwise;
///   8. `pointerRestored`: where the pointer was before and after are the same;
///   9. the allowlist is let go, and the menu bar is given 300 ms. Then the item is looked for until it is gone again (`concealedAgainMs`, 3 s
///      at most): the next run's snapshot is taken only once it is, since a slot that is still there would be part of the snapshot, and no
///      slot would then appear for the item.
/// - **How long a look takes** (`locateCallMs`: `count`, `p50`, `p95` and `max` of each `locate` in the run, in the two loops that look for the
///   item): a poll that takes longer than its interval says how much of `locatedMs`, `drawnMs` and `concealedAgainMs` is the time of the
///   looks themselves, and not macOS's.
/// - **`pressConcealed`:** after the runs, one press while the item is concealed, with `menuMs` and `menuFrame`; it is sent and watched
///   as in a run.
/// - **Records** the lists `locatedMs`, `drawnMs`, `menuMs` and `closedMs` with their middle, 95th and longest values. **Always releases.**
enum ClickPathProbe {
    static let pollInterval: Duration = .milliseconds(25)
    /// How long the item is looked for after the allowlist is live.
    static let locateTimeoutMs = 2000.0
    /// How long a menu is waited for, and how long it is waited to go.
    static let menuTimeoutMs = 1500.0
    /// What the menu bar is given after the allowlist is let go, and how long the item is then waited for to be concealed again.
    static let settle: Duration = .milliseconds(300)
    static let concealedAgainTimeoutMs = 3000.0
    static let concealedAgainInterval: Duration = .milliseconds(100)
    /// The virtual key code of Escape.
    static let escapeKeyCode: UInt16 = 53
    /// The lowest level of a window that can be a menu.
    static let minimumMenuLayer = 0
    /// How far left of the slot's left a menu's may be and be said to be near the item, in points.
    static let nearItemLeft: CGFloat = 60
    /// How far a menu's top may be from the bar's bottom and be said to be under the bar, in points.
    static let nearBarBottom: CGFloat = 8

    enum Route: String {
        case press, post, showMenu
    }

    /// What the options asked for.
    private struct Request {
        let item: ItemID
        /// The test item's name for it (`one`, `two`, `extra.<n>`), when it is one of its items.
        let fixtureName: String?
        let kind: ClickKind
        let route: Route
        let runs: Int
    }

    /// How one run came out: the times that are summarised, and what is recorded of it.
    private struct RunResult {
        var located: Double?
        var drawn: Double?
        var menu: Double?
        var closed: Double?
        var pointerRestored: Bool?
        var concealedAgain: Double?
        /// How long each `locate` of the run took, in milliseconds.
        var locateCalls: [Double] = []
        var json: JSONValue = .null
    }

    // MARK: Running

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let request: Request
        switch parse(context) {
        case .failure(let refusal):
            recorder.fail(refusal.message)
            return
        case .success(let parsed):
            request = parsed
        }
        let platform = context.platform
        let item = request.item
        if !item.isSystem, !platform.runningApps().contains(where: { $0.bundleID == item.bundleID }) {
            recorder.fail("\(item.bundleID) isn't running. " + (item.bundleID == context.fixtureBundleID ? "Open MantelTestItem first." : "Open it first."))
            return
        }
        let inspection = platform.allowlist.inspect()
        if let problem = inspection.problem {
            recorder.fail("macOS's allowlist wasn't called: \(problem)")
            return
        }
        if await platform.locator.locate(item, on: nil, since: nil) != nil {
            recorder.fail(concealedMessage(for: item, fixture: context.fixtureBundleID))
            return
        }

        recorder.measure("item", item.string)
        recorder.measure("kind", request.kind.rawValue)
        recorder.measure("route", request.route.rawValue)
        recorder.measure("runCount", request.runs)

        // What is the same in every run: the bar and the front app's menus (for the question whether the item is out of the way), and where
        // the displays are (for the question whether a menu is on screen).
        let before = await context.snapshot()
        let bars = before.bars()
        let menuFrames: [CGRect]
        if let pid = platform.frontAppPID() { menuFrames = await context.reader.menuFrames(ofPID: pid) } else { menuFrames = [] }
        let layout = await context.layoutProvider()
        let displays = layout.displays.map { layout.cgRect(fromAppKit: $0.frame) }
        let world = World(bars: bars, menuFrames: menuFrames, displays: displays)

        var results: [RunResult] = []
        var cutShort = false
        var pressConcealed: JSONValue = .null
        do {
            for index in 0..<request.runs {
                results.append(try await oneRun(index, request, context, world, recorder: &recorder))
            }
            pressConcealed = try await pressWhileConcealed(request, context, world)
        } catch is CancellationError {
            cutShort = true
            recorder.note("The probe was cut short; the allowlist was released.")
        } catch let refusal as ProbeRefusal {
            recorder.fail(refusal.message)
        } catch {
            recorder.fail("The probe stopped: \(error.localizedDescription)")
        }

        recorder.measure("runs", .array(results.map(\.json)))
        recorder.measure("locatedMs", LatencyStats(values: results.map(\.located)).json())
        recorder.measure("drawnMs", LatencyStats(values: results.map(\.drawn)).json())
        recorder.measure("menuMs", LatencyStats(values: results.map(\.menu)).json())
        recorder.measure("closedMs", LatencyStats(values: results.map(\.closed)).json())
        recorder.measure("pointerRestoredEveryRun", .bool(!results.isEmpty && results.allSatisfy { $0.pointerRestored == true }))
        recorder.measure("pressConcealed", pressConcealed)
        let notConcealedAgain = results.filter { $0.concealedAgain == nil }.count
        if notConcealedAgain > 0 {
            recorder.note("In \(notConcealedAgain) of \(results.count) runs the item was still found 3 s after the allowlist was let go; the next run's snapshot had its slot in it.")
        }
        let neverDrawn = results.filter { $0.drawn == nil }.count
        if neverDrawn > 0 {
            recorder.note("\(neverDrawn) of \(results.count) runs found no slot that a click could be posted at within 2 s; drawnMs is null for each.")
        }
        recorder.note("Times are milliseconds. locatedMs and drawnMs are from when the allowlist was live, menuMs from the click, closedMs from Escape.")

        // The allowlist is let go in every run, however it ended; the menu bar is looked at once more, as the other probes that hold one do.
        guard !cutShort else { return }
        recorder.changeBegan()
        do {
            let released = context.clock.now()
            let running = platform.runningApps
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

    /// What does not change from one run to the next.
    private struct World: Sendable {
        let bars: [MenuBarGeometry]
        let menuFrames: [CGRect]
        let displays: [CGRect]
    }

    // MARK: The request

    static func concealedMessage(for item: ItemID, fixture: String) -> String {
        let what = item.bundleID == fixture ? "MantelTestItem" : (item.isSystem ? "that icon" : item.bundleID)
        return "Move \(what) to Hidden in Settings › Layout first."
    }

    private static func parse(_ context: ProbeContext) -> Result<Request, ProbeRefusal> {
        let options = context.options
        let name = options.string("item") ?? "one"
        let item: ItemID
        var fixtureName: String?
        if TestItemNames.isValid(name) {
            item = context.fixtureItemID(name)
            fixtureName = name
        } else if let parsed = ItemID(string: name) {
            item = parsed
            if parsed.bundleID == context.fixtureBundleID, case .identifier(let identifier) = parsed.key,
               identifier.hasPrefix(TestItemNames.autosavePrefix) {
                fixtureName = String(identifier.dropFirst(TestItemNames.autosavePrefix.count))
            }
        } else {
            return .failure(ProbeRefusal(message: "The item is one, two or extra.<n>, or with --allow-any an item ID such as system:wifi."))
        }
        if item.bundleID == context.platform.ownBundleID { return .failure(ProbeRefusal(message: ProbeSafety.ownItemMessage)) }
        if case .failure(let refusal) = ProbeSafety.permitted([item.bundleID], options: options) { return .failure(refusal) }

        let kindName = options.string("kind") ?? ClickKind.left.rawValue
        guard let kind = ClickKind(rawValue: kindName) else {
            return .failure(ProbeRefusal(message: "The kind is left, right or option."))
        }
        let routeName = options.string("route") ?? Route.press.rawValue
        guard let route = Route(rawValue: routeName) else {
            return .failure(ProbeRefusal(message: "The route is press, post or showMenu."))
        }
        return .success(Request(item: item, fixtureName: fixtureName, kind: kind, route: route,
                                runs: options.int("runs", default: 5, range: 1...10)))
    }

    // MARK: One run

    private static func oneRun(_ index: Int, _ request: Request, _ context: ProbeContext, _ world: World,
                               recorder: inout ProbeRecorder) async throws -> RunResult {
        let platform = context.platform
        let item = request.item
        var result = RunResult()
        var record: [String: JSONValue] = ["run": .number(Double(index + 1))]

        // 1. What is drawn now.
        let snapshot = await platform.locator.slotSnapshot(on: nil)

        // 2. Draw the item: its app, Mantel's own and every system item are allowed; nothing is concealed that wasn't.
        var allowed: [String] = []
        for bundleID in [item.isSystem ? nil : item.bundleID, platform.ownBundleID] {
            if let bundleID, !allowed.contains(bundleID) { allowed.append(bundleID) }
        }
        let activateStarted = context.clock.now()
        let assertion: any AllowlistAssertionHandle
        do {
            assertion = try await platform.allowlist.activate(systemItems: Array(0...255), bundleIDs: allowed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProbeRefusal(message: "The allowlist wasn't activated: \(error.localizedDescription)")
        }
        recorder.changeBegan()
        // Let go on every way out of this run, a cancelled one included.
        var released = false
        defer {
            if !released {
                assertion.invalidate()
                recorder.changeUndone()
            }
        }
        // Whether a click was made, and whether Escape has been posted for it. A run that ends before `closeMenu` has posted it (cut short
        // while it waited for the menu) posts it here, before the allowlist above is let go: a menu that opened would stay open.
        var clicked = false
        var escaped = false
        defer {
            if clicked, !escaped { try? platform.poster.key(escapeKeyCode, flags: []) }
        }
        record["activateMs"] = .number(context.milliseconds(since: activateStarted))

        // 3. Find it.
        let locateStarted = context.clock.now()
        var last: ItemLocation?
        while true {
            try Task.checkCancellation()
            let lookStarted = context.clock.now()
            let looked = await platform.locator.locate(item, on: nil, since: snapshot)
            result.locateCalls.append(context.milliseconds(since: lookStarted))
            if let found = looked {
                last = found
                let elapsed = context.milliseconds(since: locateStarted)
                if result.located == nil { result.located = elapsed }
                // The item was concealed when the snapshot was taken: this is the one rule for such an item.
                if found.isPostable(drawnAtSnapshot: false) {
                    result.drawn = elapsed
                    break
                }
            }
            if context.milliseconds(since: locateStarted) >= locateTimeoutMs { break }
            try await context.clock.sleep(for: pollInterval)
        }
        let postable = result.drawn != nil
        let slot = last?.slotFrame
        record["locatedMs"] = ProbeJSON.number(result.located)
        record["drawnMs"] = ProbeJSON.number(result.drawn)
        record["postable"] = .bool(postable)
        record["tiedBy"] = ProbeJSON.text(last?.tiedBy.rawValue)
        record["slotWasInBaseline"] = ProbeJSON.flag(last?.slotWasInBaseline)
        record["widthAgrees"] = ProbeJSON.flag(last?.widthAgrees)
        record["frameMinusSlotWidth"] = ProbeJSON.number(last?.frameMinusSlotWidth)
        record["slot"] = ProbeJSON.rect(slot)
        record["display"] = ProbeJSON.text(last?.displayUUID)
        if let last, let bar = world.bars.first(where: { $0.displayUUID == last.displayUUID }) {
            record["outOfTheWay"] = .bool(BarRegion.isOutOfTheWay(last.slotFrame, bar: bar, menuFrames: world.menuFrames))
        } else {
            record["outOfTheWay"] = .null
        }

        // 4. Click.
        let pointerBefore = platform.pointerLocation()
        let windowsBefore = platform.windowList.onScreenWindows()
        let clickStarted = context.clock.now()
        var sent: ActionInFlight?
        switch request.route {
        case .press:
            record["pressedInPlace"] = .bool(!postable)
            sent = ActionInFlight.start(.press, item, with: platform.presser, clock: context.clock)
        case .showMenu:
            sent = ActionInFlight.start(.showMenu, item, with: platform.presser, clock: context.clock)
        case .post:
            if postable, let slot {
                let point = CGPoint(x: slot.midX, y: slot.midY)
                do {
                    try platform.poster.click(request.kind, at: point)
                    clicked = true
                } catch {
                    record["error"] = .string(error.localizedDescription)
                }
                record["posted"] = .bool(clicked)
            } else {
                // No slot that a click may be posted at: nothing is posted.
                record["posted"] = .bool(false)
            }
        }
        // A press that failed outright sent nothing, and there is no menu to watch for.
        if let sent { clicked = sent.failure == nil }

        // 5. The menu.
        let owners = ownerPIDs(of: item, running: platform.runningApps())
        var opened: [WindowInfo] = []
        if clicked {
            opened = try await watchForMenu(of: owners, before: windowsBefore, since: clickStarted, sent: sent, context)
            if let sent, sent.failure != nil { clicked = false }
        }
        if let sent, !opened.isEmpty { record["pressPendingAtMenu"] = .bool(sent.result == nil) }
        let menu = opened.first
        if menu != nil { result.menu = context.milliseconds(since: clickStarted) }
        record["menuMs"] = ProbeJSON.number(result.menu)
        record["menuLayer"] = menu.map { .number(Double($0.layer)) } ?? .null
        record["menuFrame"] = ProbeJSON.rect(menu?.bounds)
        if let menu, let slot {
            record["menuNearItem"] = .bool(abs(menu.bounds.minX - slot.minX) <= nearItemLeft && abs(menu.bounds.minY - slot.maxY) <= nearBarBottom)
        } else {
            record["menuNearItem"] = .null
        }
        record["menuOnScreen"] = menu.map { menu in .bool(world.displays.contains { $0.intersects(menu.bounds) }) } ?? .null

        // 6. What the test item received.
        if clicked, let name = request.fixtureName, name == "one" || name == "two" {
            record["kindReceived"] = ProbeJSON.text(TestItemClickLog.kindReceived(by: name, since: clickStarted, in: platform.testItemSupportFolder))
        } else {
            record["kindReceived"] = .null
        }

        // 7. Close what opened.
        if clicked {
            result.closed = try await closeMenu(opened, context, escaped: &escaped, record: &record)
        }
        record["closedMs"] = ProbeJSON.number(result.closed)
        if let sent { try await recordOutcome(of: sent, since: clickStarted, context, &record) }

        // 8. The pointer.
        let pointerAfter = platform.pointerLocation()
        if let pointerBefore, let pointerAfter { result.pointerRestored = pointerBefore == pointerAfter }
        record["pointerRestored"] = ProbeJSON.flag(result.pointerRestored)

        // 9. Let go, and wait for the item to be concealed again.
        assertion.invalidate()
        recorder.changeUndone()
        released = true
        try await context.clock.sleep(for: settle)
        let waitStarted = context.clock.now()
        var concealedAgain: Double?
        while true {
            try Task.checkCancellation()
            let lookStarted = context.clock.now()
            // The slots tell, not `locate`: an app the scans still name as concealed gets no bare tie there, and the answer would be nil from
            // the first look. The item is concealed again when the bar has no more slots than before the run (nothing is drawn for it).
            let gone: Bool
            if let snapshot, let now = await platform.locator.slotSnapshot(on: nil) {
                gone = now.slots.count <= snapshot.slots.count
            } else {
                gone = await platform.locator.locate(item, on: nil, since: nil) == nil
            }
            result.locateCalls.append(context.milliseconds(since: lookStarted))
            if gone {
                concealedAgain = context.milliseconds(since: waitStarted)
                break
            }
            if context.milliseconds(since: waitStarted) >= concealedAgainTimeoutMs { break }
            try await context.clock.sleep(for: concealedAgainInterval)
        }
        record["concealedAgainMs"] = ProbeJSON.number(concealedAgain)
        record["locateCallMs"] = LatencyStats(values: result.locateCalls).json(includingValues: false)
        result.concealedAgain = concealedAgain
        result.json = .object(record)
        return result
    }

    private enum Action {
        case press, showMenu
    }

    /// A press or `AXShowMenu` that was sent and may not have returned. An item whose action opens a menu doesn't answer until the menu
    /// closes, or the call times out (`ItemPressError.noAnswer`), so the menu is watched for while the action is out.
    private final class ActionInFlight: Sendable {
        struct Returned: Sendable {
            let error: ItemPressError?
            let at: Date
        }

        private let returned = Mutex<Returned?>(nil)

        /// How the action came back; nil while it hasn't.
        var result: Returned? { returned.withLock { $0 } }

        /// The error of an action that failed outright (the item isn't there, Accessibility isn't granted, it takes no such action): one
        /// that was never sent. Nil for one that is out, that returned, or that timed out, which may have opened its menu all the same.
        var failure: ItemPressError? {
            guard let error = result?.error, error != .noAnswer else { return nil }
            return error
        }

        /// Sends the action. The call runs on until it first has to wait before this returns; the real presser is an actor, so its first
        /// wait is the hop to it and this returns before the action has run, and an outright failure is seen by the first look for the menu
        /// (`watchForMenu`), within one poll. Only a presser that never waits (a fake) has answered by the time this returns.
        static func start(_ action: Action, _ item: ItemID, with presser: any ItemPressing, clock: any Clock) -> ActionInFlight {
            let flight = ActionInFlight()
            _ = Task.immediate {
                var failure: ItemPressError?
                do throws(ItemPressError) {
                    switch action {
                    case .press: try await presser.press(item)
                    case .showMenu: try await presser.showMenu(item)
                    }
                } catch {
                    failure = error
                }
                flight.returned.withLock { $0 = Returned(error: failure, at: clock.now()) }
            }
            return flight
        }
    }

    /// Reads the window list every 25 ms for a window of the item's owners that wasn't there before and can be a menu, for 1.5 s from
    /// `started`; ends sooner when the action `sent` failed outright. What it found, nothing when no menu came.
    private static func watchForMenu(of owners: [pid_t], before: [WindowInfo], since started: Date, sent: ActionInFlight?,
                                     _ context: ProbeContext) async throws -> [WindowInfo] {
        while true {
            // A failure first: a window seen in the same poll as one is not what an action that was never sent opened.
            if sent?.failure != nil { return [] }
            let now = context.platform.windowList.onScreenWindows()
            let opened = owners.flatMap { MenuWindows.opened(by: $0, before: before, after: now, minimumLayer: minimumMenuLayer) }
            if !opened.isEmpty || context.milliseconds(since: started) >= menuTimeoutMs { return opened }
            try await context.clock.sleep(for: pollInterval)
        }
    }

    /// Records how a press or `AXShowMenu` came out, after its menu was closed (which is what lets one that was held go): whether it
    /// answered, and when it returned. One that has not returned is given the menu wait; it may never. An error is for one that failed
    /// outright.
    private static func recordOutcome(of sent: ActionInFlight, since started: Date, _ context: ProbeContext,
                                      _ record: inout [String: JSONValue]) async throws {
        let waitStarted = context.clock.now()
        while sent.result == nil, context.milliseconds(since: waitStarted) < menuTimeoutMs {
            try await context.clock.sleep(for: pollInterval)
        }
        guard let returned = sent.result else {
            record["pressAnswered"] = .bool(false)
            record["pressReturnedMs"] = .null
            return
        }
        record["pressReturnedMs"] = .number(returned.at.timeIntervalSince(started) * 1000)
        if let failure = sent.failure {
            record["error"] = .string(failure.localizedDescription)
        } else {
            record["pressAnswered"] = .bool(returned.error == nil)
        }
    }

    /// Posts Escape (`escaped` says so from then on, so that the run does not post it again on the way out), and waits for the windows that
    /// opened to go. The milliseconds it took; nil when none opened or one stayed.
    private static func closeMenu(_ opened: [WindowInfo], _ context: ProbeContext, escaped: inout Bool,
                                  record: inout [String: JSONValue]) async throws -> Double? {
        let platform = context.platform
        let escapeAt = context.clock.now()
        escaped = true
        do {
            try platform.poster.key(escapeKeyCode, flags: [])
        } catch {
            record["escapeError"] = .string(error.localizedDescription)
        }
        guard !opened.isEmpty else { return nil }
        let numbers = Set(opened.map(\.number))
        while true {
            let now = platform.windowList.onScreenWindows()
            if !now.contains(where: { numbers.contains($0.number) }) { return context.milliseconds(since: escapeAt) }
            if context.milliseconds(since: escapeAt) >= menuTimeoutMs { return nil }
            try await context.clock.sleep(for: pollInterval)
        }
    }

    // MARK: Pressing it concealed

    /// One press while the item is concealed (no allowlist of the probe's is live): whether a menu opens, and where.
    private static func pressWhileConcealed(_ request: Request, _ context: ProbeContext, _ world: World) async throws -> JSONValue {
        let platform = context.platform
        var record: [String: JSONValue] = [:]
        let windowsBefore = platform.windowList.onScreenWindows()
        let started = context.clock.now()
        // As in a run: a press that was made is followed by Escape on every way out, once.
        var pressed = false
        var escaped = false
        defer {
            if pressed, !escaped { try? platform.poster.key(escapeKeyCode, flags: []) }
        }
        let sent = ActionInFlight.start(.press, request.item, with: platform.presser, clock: context.clock)
        pressed = sent.failure == nil
        var opened: [WindowInfo] = []
        if pressed {
            let owners = ownerPIDs(of: request.item, running: platform.runningApps())
            opened = try await watchForMenu(of: owners, before: windowsBefore, since: started, sent: sent, context)
            pressed = sent.failure == nil
        }
        let menu = opened.first
        record["pressed"] = .bool(pressed)
        record["menuMs"] = menu == nil ? .null : .number(context.milliseconds(since: started))
        record["menuLayer"] = menu.map { .number(Double($0.layer)) } ?? .null
        record["menuFrame"] = ProbeJSON.rect(menu?.bounds)
        record["menuOnScreen"] = menu.map { menu in .bool(world.displays.contains { $0.intersects(menu.bounds) }) } ?? .null
        if pressed {
            record["closedMs"] = ProbeJSON.number(try await closeMenu(opened, context, escaped: &escaped, record: &record))
        }
        try await recordOutcome(of: sent, since: started, context, &record)
        return .object(record)
    }

    /// The processes whose windows a menu of the item can be: its app's, or for a system item the two that draw the system's.
    private static func ownerPIDs(of item: ItemID, running: [RunningApp]) -> [pid_t] {
        let owners: Set<String> = item.isSystem ? ["com.apple.controlcenter", "com.apple.systemuiserver"] : [item.bundleID]
        return running.filter { $0.bundleID.map(owners.contains) ?? false }.map(\.pid)
    }
}
