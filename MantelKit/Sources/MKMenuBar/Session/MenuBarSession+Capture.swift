import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout

/// Taking the pictures of the icons at the moments that call for them. What a picture is, and which icons are cropped, is the collector's
/// (`ItemImageCollector`); here it is decided when, and from which read.
///
/// A picture is never kept under an item that isn't the one in it, and when it can't be told that the pixels and the slot frames belong to
/// the same moment, nothing is kept:
/// - **Launch.** The first read that has a bar is captured before the first plan is applied, while everything is drawn (a first read
///   that has no bar applies the plan, and the launch isn't captured: the moments that follow are). It has a deadline, the budget
///   (`CaptureRules.budget(forShownBars:)`) from when it begins: nobody waits for it past that, the plan applies, and a strip that comes
///   back after the deadline is not cropped.
/// - **A reveal that was seen, Settings opening and a click's icon,** are captured on a task of their own: nothing here waits for a capture
///   in the path that applies a plan. A reveal is captured from the read after which no more room is made for it. Settings' and the
///   click's read the bar when it is still (`waitForTheBarToBeStill`: a read taken while a plan is being drawn is of a bar that moves on),
///   and a capture that kept nothing because the bar changed under it is taken again, from a read of its own, up to `captureTries` times.
/// - **Recapture** reveals everything for one capture, and puts the plan back.
/// - **Every capture is told the apps the plan conceals,** so that it skips them, and is of one bar: the active display's, or the main
///   display's when that can't be told (a display that isn't active draws its icons translucent, and the pictures come out tinted by the
///   wallpaper).
/// - **Every capture, the launch's too, is asked again when its strip is back** (`isStillCurrent`): nothing may have been applied since
///   the read began; the bar's slots, looked at once more, must be the read's (a change that Mantel doesn't make, such as an app launching
///   or an icon changing its width, slides every slot left of it, and none right of it); and the apps whose icons are cropped are asked
///   for their frames once more, and an app's pictures are kept only when its frames are in the slots the read gave its items
///   (`ItemFrameCheck`: a read can tie an app to its neighbour's slot, and icons of one width can trade places with every slot where it
///   was). When the slots differ, an app is still kept only if the slots that aren't Mantel's own left of where the walk from the right
///   stopped are the same ones (as many, of the same widths in order, but for the one at the stop: the dots being placed, say, or one
///   slot's width change), and its icons are right of where the bar first differs (`BarSlotCheck.difference`); then its frames are the
///   second check. A slot of anyone else's that came or went costs every picture: a run of slots of one width with no names can't
///   show where a slide began. When that can't be told, nothing is kept, and the log says what was found out of place.
extension MenuBarSession {
    /// How the recording indicator is named among the system items.
    static let recordingIndicatorModule = "audiovideo"
    static let indicatorQuietLogLine = "the recording indicator is left out of what is judged for a moment after each capture"
    static let launchCaptureOverranLogLine = "the launch capture ran past its budget; the plan is applied without waiting for it"
    static let launchCaptureLostLogLine = "the launch capture was lost: the first read with bars came after icons were hidden"
    static let noPicturesText = "No pictures are being taken"
    static let barNotReadText = "The bar couldn't be read"
    static let notStartedText = "Mantel hasn't finished starting"

    /// Sets what takes the pictures; nil takes none. The app sets it before the session starts, so that the launch is captured.
    public func setImageCollector(_ collector: ItemImageCollector?) async {
        imageCollector = collector
    }

    // MARK: Recapture

    /// Shows every icon for one capture and puts the plan back: the plan is made with everything revealed and applied through the
    /// session, so the engines, the dots and the rehide state go on as they do for any reveal. It waits for the look at the bar (at most
    /// one second), reads the bar, captures it, and then makes the plan as it was.
    ///
    /// It answers skipped, saying why, before the session has started (the launch reads are done), during a reset, while the bar is being
    /// re-sorted by a write of the order table (showing every icon then would only be refused after a flash), in Focus Mode, once
    /// quitting has begun, while another recapture is under way, and when nothing takes pictures. Every picture is taken again: the
    /// collector doesn't leave one that is recent (`CaptureMoment.recapture`), and the bar's two-second throttle stands: a recapture that
    /// comes within it waits out the rest, on the session's clock, before it reveals anything.
    /// A reveal that comes while it runs stands: the plan is not put back over it.
    public func recaptureIcons() async -> CaptureSummary {
        guard imageCollector != nil else { return Self.skipped(Self.noPicturesText) }
        if let refused = recaptureRefusal() { return refused }
        guard !isRecapturing else { return Self.skipped("Icons are being captured") }
        isRecapturing = true
        defer { isRecapturing = false }
        // A capture that began a moment ago holds the bar's throttle: the rest of it is waited out before anything is revealed, so that the
        // pictures that follow are taken instead of refused after a flash of every icon. What can stop a recapture is asked again after.
        if await waitOutTheThrottle(), let refused = recaptureRefusal() { return refused }

        let before = (state: revealState, presentation: revealPresentation, swapped: swapConcealed)
        revealGeneration += 1
        let generation = revealGeneration
        revealState = .allShown
        revealPresentation = .inline
        swapConcealed = []
        await rebuildAndApply()

        await confirmReveal(generation: generation, wait: min(confirmationWait, Self.recaptureLookLimit))
        var summary = Self.skipped(Self.barNotReadText)
        if generation == revealGeneration, !isQuitting, let taken = await requestRead(.reveal), generation == revealGeneration {
            summary = await takePictures(.recapture, taken: taken, generation: generation)
        }

        // Another change of reveal (or a reset) since this began has put its own state in place of this one's: it stands.
        if generation == revealGeneration {
            revealGeneration += 1
            revealState = before.state
            revealPresentation = before.presentation
            swapConcealed = before.swapped
            await rebuildAndApply()
        }
        return summary
    }

    /// Why a recapture can't begin now, or nil.
    private func recaptureRefusal() -> CaptureSummary? {
        guard isStarted, !isReadingAtLaunch else { return Self.skipped(Self.notStartedText) }
        guard !isQuitting else { return Self.skipped(CommandAnswers.quitting) }
        guard !resetting else { return Self.skipped(CommandAnswers.resetUnderWay) }
        if let resorting = layoutCaptureRefusal { return Self.skipped(resorting) }
        guard revealState != .focusMode else { return Self.skipped(CommandAnswers.focus(isOn: true)) }
        return nil
    }

    /// Waits, on the session's clock, until the bar's capture interval has passed since the collector last took a strip. A capture that
    /// starts meanwhile moves the end of the wait, so it is asked again each time. True when it waited at all.
    private func waitOutTheThrottle() async -> Bool {
        guard let collector = imageCollector else { return false }
        let interval = collector.rules.perBarInterval
        var waited = false
        while let wait = RecaptureWait.remaining(lastStrip: await collector.lastStripAt, now: clock.now(), interval: interval) {
            waited = true
            do { try await clock.sleep(for: wait) } catch { return waited }
        }
        return waited
    }

    /// The most a recapture waits for the bar to show everything.
    static let recaptureLookLimit: Duration = .seconds(1)

    // MARK: The moments

    /// The launch's capture: bounded by the budget the shown bars give, through `TimeBound`, and given the moment that budget ends as
    /// its deadline: the plan applies once it does, so a strip that is back after it shows a bar that has been changed, and is not
    /// cropped. A capture that isn't done by then isn't waited for.
    func captureAtLaunch(_ read: Inventory, agentPID: pid_t?) async {
        guard let collector = imageCollector, !launchCaptureDone, !isQuitting else { return }
        launchCaptureDone = true
        let budget = collector.rules.launchBudget(forShownBars: shownBars(of: read).count, readTook: lastReadTook)
        let deadline = clock.now().addingTimeInterval(Self.seconds(budget))
        let concealed = appsNotDrawn()
        let taken = TakenRead(inventory: read, barChanges: barChanges, agentPID: agentPID)
        // A task of its own, which nothing waits for past the budget (and which `capturesFinished()` waits for, for the tests).
        let capturing = runCapture { session in
            await collector.reconcile(with: read)
            _ = await collector.capture(.launch, read: read, concealed: concealed, deadline: deadline,
                                        isCurrent: { display, apps in await session.isStillCurrent(taken: taken, display: display, apps: apps, generation: nil) })
        }
        let finished = await TimeBound.finishes(within: budget, clock: clock) { await capturing.value }
        if !finished { Log.info("session", Self.launchCaptureOverranLogLine) }
    }

    /// A reveal whose look saw the icons: their pictures are taken from the read after which no more room is made, on a task of its own.
    func startCapturingRevealed(_ apps: Set<String>, taken: TakenRead, generation: Int) {
        guard imageCollector != nil else { return }
        runCapture { await $0.captureRevealed(apps, taken: taken, generation: generation) }
    }

    private func captureRevealed(_ apps: Set<String>, taken: TakenRead, generation: Int) async {
        var taken = taken
        var tries = 1
        while true {
            // Not once the reveal is over: the icons are off the bar again, and a strip of it would show others where these were.
            guard generation == revealGeneration else { return }
            let summary = await takePictures(.revealSeen(apps), taken: taken, generation: generation)
            // The bar changed while the strip was taken (the plan's own last changes, an app): once it is still it is read and taken again.
            guard Self.barChangedUnderIt(summary), tries < captureTries, generation == revealGeneration else { return }
            tries += 1
            await waitForTheBarToBeStill()
            guard generation == revealGeneration, let again = await requestRead(.reveal), generation == revealGeneration else { return }
            taken = again
        }
    }

    /// Settings opened: the icons that are drawn (the Shown ones) are captured from a read taken for it, on a task of its own.
    func startCapturingForSettings() {
        guard imageCollector != nil else { return }
        runCapture { await $0.captureForSettings() }
    }

    private func captureForSettings() async {
        var tries = 0
        while true {
            // The bar is read when it is still: what is read while a plan is being drawn is a bar that moves on.
            await waitForTheBarToBeStill()
            guard let taken = await requestRead(.refresh) else { return }
            let summary = await takePictures(.settingsOpened, taken: taken)
            tries += 1
            guard Self.barChangedUnderIt(summary), tries < captureTries else { return }
        }
    }

    /// Sets how many times a capture is taken when the bar changes under it (the first time included): three, unless a test is of one try.
    func setCaptureTries(_ tries: Int) {
        captureTries = max(1, tries)
    }

    /// Whether a capture kept nothing because the bar changed while it was taken: the one that is worth taking again.
    private static func barChangedUnderIt(_ summary: CaptureSummary) -> Bool {
        summary.captured == 0 && summary.skipped == ItemImageCollector.SkipReason.barChanged.text
    }

    /// Sets how long a plan is given to be drawn after the engines have applied it, before a capture reads the bar: a test of the check
    /// has no use for the wait, and the fake clock would have to be moved for it.
    func setBarDrawnWait(_ wait: Duration) {
        barDrawnWait = wait
    }

    /// The most a capture waits for the bar to be still: after it the bar is read as it is.
    static let barStillLimit: Duration = .seconds(5)

    /// Returns when no plan is being applied and the last one was applied `barDrawnWait` ago, and no write of the order table is pending or
    /// settling and no ⌘-drag is being followed, or when `barStillLimit` has passed, or at the quit. A read taken before is of a bar that is
    /// still catching up with a plan, or being re-sorted, and the pictures of it are not kept.
    func waitForTheBarToBeStill() async {
        let began = clock.now()
        let limit = Self.seconds(Self.barStillLimit)
        while !isQuitting, clock.now().timeIntervalSince(began) < limit {
            let progress = applyProgress
            let wait: Duration
            if progress.underway || layoutIsPending || layoutSettling || dragBefore != nil {
                wait = .milliseconds(100)
            } else if let since = progress.since, since < barDrawnWait {
                wait = barDrawnWait - since
            } else {
                return
            }
            do { try await clock.sleep(for: wait) } catch { return }
        }
    }

    /// Runs a capture on a task of its own, which `capturesFinished()` waits for.
    @discardableResult
    private func runCapture(_ work: @escaping @Sendable (MenuBarSession) async -> Void) -> Task<Void, Never> {
        let number = nextCaptureTask
        nextCaptureTask += 1
        let task = Task {
            await work(self)
            self.captureTasks[number] = nil
        }
        captureTasks[number] = task
        return task
    }

    /// Returns when the captures that were started on tasks of their own are done. For tests.
    func capturesFinished() async {
        while let task = captureTasks.values.first { await task.value }
    }

    // MARK: Taking them

    /// Asks the collector for the pictures of a moment, from this read: after the pictures of items whose identity may have moved are
    /// dropped, and told which apps the plan conceals. When the strip is back the collector asks `isStillCurrent`, and keeps nothing if
    /// the bar was changed after the read began (or, where `generation` is given, the reveal that was in force is over), or its slots
    /// are not the ones the read had.
    @discardableResult
    func takePictures(_ moment: CaptureMoment, taken: TakenRead, generation: Int? = nil) async -> CaptureSummary {
        guard let collector = imageCollector else { return Self.skipped(Self.noPicturesText) }
        guard !isQuitting else { return Self.skipped(CommandAnswers.quitting) }
        guard !resetting else { return Self.skipped(CommandAnswers.resetUnderWay) }
        // A read with no bar in it says nothing of any icon: it isn't "No icon to capture", it is a bar that wasn't read.
        guard !taken.inventory.bars.isEmpty else { return Self.skipped(Self.barNotReadText) }
        let concealed = appsNotDrawn()
        await collector.reconcile(with: taken.inventory)
        return await collector.capture(moment, read: taken.inventory, concealed: concealed,
                                       isCurrent: { display, apps in await self.isStillCurrent(taken: taken, display: display, apps: apps, generation: generation) })
    }

    /// The apps (of `apps`, the ones whose icons are cropped from a display's bar) whose pictures may be kept, now that a strip of the bar
    /// is back; none when the bar isn't known to be as it was when the read was taken. It is so when nothing has been applied to it since,
    /// the reveal the read was taken for (when there is one) is still in force, the slots of the app's icons are where the read had them
    /// (`BarSlotCheck`: the whole list when the bar is the same; else, when the slots left of the walk's stop that aren't Mantel's own are
    /// the same ones and the stop is no dot that only slid there, the slots right of the first difference, and only on the bar the apps'
    /// frames are on; else none), and the app's frames, asked again, are in the slots the read gave its items (`ItemFrameCheck`). The count
    /// of Mantel's own changes is the cheap first test, and is asked again after the look and the apps, which take a moment.
    ///
    /// **A look or an app that doesn't answer is not a change.** On a busy Mac the answers come late, so what didn't answer is asked again
    /// after a moment, up to four rounds and three seconds, and the bar is taken for settled when two rounds in a row agree
    /// (`StillCurrentWatch`). Only a difference that was answered throws pictures away, and the pictures of the apps whose frames were
    /// confirmed are kept when another app never answered.
    ///
    /// What moves the icons without a plan of Mantel's (the dots being placed, the clock click's lift and its restore, a bar that is
    /// catching up with a plan, an app launching, quitting or changing width) moves the slots, and is seen there. What the slots can't
    /// show, icons of one width that trade places (a ⌘-drag, an app that removes its item and adds it again, a layout write that macOS
    /// applies late), is seen by the apps' frames when the icons are of different apps, which follow them; two items of one app that
    /// trade places aren't seen (an app is compared as a set), and neither is a change and its undo within the span. Two icons of one
    /// width and no names that swap leave every slot as it was: that was the whole-list rule's risk before, and is now. So is an icon that
    /// arrives just left of a run of one width while an icon of the run's width leaves right of it, and its mirror (an icon of the run's
    /// width comes inside the run while the app's icon just left of it, of another width, goes): the slot lists read as one width change.
    /// And on a bar piled at the «, an icon that comes or goes right of it moves every icon between it and the « by one slot, and the «
    /// makes up the count: with icons of one width the slot list is unchanged. No rule on unnamed slots can tell these apart. Within the
    /// run that is trusted the apps' frames are the only guard for an icon, as they are for any app when the slots are the same. A read
    /// with no slots for the bar is not known to be the same, and neither is an app whose frames never come.
    ///
    /// **The apps are asked before the look**, so that a slide that happens while the apps answer and is undone before the look is over
    /// is seen by the look (a bar that slid during the answers and came back by the time of the look shows the slots as they were, and the
    /// frames the apps gave are then the slid ones, which lie in other slots). Asked after the look, the slots would be proven only up to
    /// the moment the look ended.
    ///
    /// Answers the apps whose pictures may be kept, whether the apps that aren't kept are so for want of time (`outOfTime`: nothing
    /// was seen to move, and the rest wasn't judged) and not because the bar, or an app's own frames, differed, and what was found out of
    /// place (`StillCurrentAnswer.changes`), for the log.
    func isStillCurrent(taken: TakenRead, display: String, apps: Set<String>, generation: Int?) async -> StillCurrentAnswer {
        if let why = whyNotUnchanged(since: taken, generation: generation) { return StillCurrentAnswer(kept: [], changes: [why]) }
        guard let before = taken.inventory.barSlots[display] else {
            return StillCurrentAnswer(kept: [], changes: ["the read has no slots for the bar"])
        }
        // The bound is time on the clock from the start, and what is left of it is what each round's reads may spend (the apps' frames and the
        // look at the slots take what they take on a busy Mac: counting only the pauses between rounds would let a round last seconds).
        let began = clock.now()
        let bound = Self.seconds(StillCurrentWatch.bound)
        var watch = StillCurrentWatch(apps: apps)
        // What was found out of place, for the log: the look's difference, the apps whose slots moved, and the apps whose frames are elsewhere.
        var found = StillCurrentFindings()
        while true {
            let asked = watch.pending.subtracting([ItemID.systemBundleID])
            // The apps' frames have half of what is left and the look the rest: a slow app among them can't leave the look too little for
            // one of MenuBarAgent's queries to use its second wait on a loaded Mac.
            let frames = await readingFor(max(0, bound - clock.now().timeIntervalSince(began)) / 2) { await itemFramesNow(ofApps: asked) }
            if let why = whyNotUnchanged(since: taken, generation: generation) { return endedBy(why, watch, found) }
            let now = await readingFor(bound - clock.now().timeIntervalSince(began)) { await slotsNow(on: display) }
            if let why = whyNotUnchanged(since: taken, generation: generation) { return endedBy(why, watch, found) }
            // MenuBarAgent that isn't running, or is another process than the read's, isn't slow: the bar was redrawn, or isn't there.
            if let why = await whyAgentIsNotTheReads(taken) { return endedBy(why, watch, found) }
            // A look that was cut short (a read of the window timed out) lacks the slots after the cut: it is no look, and isn't a change.
            var look = SlotsLook.unanswered
            var moved: Set<String> = []
            if let now, now.isComplete {
                if BarSlotCheck.isSame(read: before, now: now) {
                    look = .same
                } else {
                    // Where no slot of anyone else's came or went (Mantel's own may have), the slots right of the first difference are where
                    // they were, and an app whose icons are all in those can still be kept, on its own frames. Anywhere else a slide can't be
                    // told from no slide (icons of one width with no names), and no app is: the old rule, all or nothing. The same where the
                    // apps' frames are on another bar than this one: they can't see a slide that only this bar had.
                    let difference = BarSlotCheck.difference(read: before, now: now)
                    let framesAreHere = taken.inventory.activeDisplay.map { $0 == display } ?? true
                    let isTrusted = difference.isTrusted && framesAreHere
                    moved = isTrusted
                        ? BarSlotCheck.appsWithMovedSlots(watch.pending, read: taken.inventory, display: display, slots: before, unmoved: difference.unmoved)
                        : watch.pending
                    found.slots = difference.summary + (difference.isTrusted && !framesAreHere ? "; the apps' frames are on another bar: no icon is known to be where it was" : "")
                    found.everyAppMoved = !isTrusted
                    look = .differs
                }
            }
            // The system's items are no app's: nobody is asked for them, and what is said of them is the read's own.
            let answered = Set(frames.keys).union(watch.pending.intersection([ItemID.systemBundleID]))
            let framesDisplay = taken.inventory.activeDisplay
            let tied = ItemFrameCheck.appsStillTied(watch.pending, read: taken.inventory, display: display, framesDisplay: framesDisplay,
                                                    framesNow: frames)
            let pendingBefore = watch.pending
            let verdict = watch.note(slots: look, tied: tied, answered: answered, moved: moved)
            found.noteRejected(watch.rejected.intersection(pendingBefore), moved: moved) { app in
                ItemFrameCheck.describeUntied(app, read: taken.inventory, display: display, framesDisplay: framesDisplay, framesNow: frames[app] ?? [])
            }
            switch verdict {
            case .done(let kept):
                return found.answer(for: watch, kept: kept, of: apps)
            case .again:
                // The bar is given a moment to settle before it is looked at again, on the session's clock.
                guard clock.now().timeIntervalSince(began) < bound else { return outOfTime(watch, of: apps, found: found) }
                do { try await clock.sleep(for: StillCurrentWatch.settleWait) } catch { return StillCurrentAnswer(kept: []) }
                if let why = whyNotUnchanged(since: taken, generation: generation) { return endedBy(why, watch, found) }
                guard clock.now().timeIntervalSince(began) < bound else { return outOfTime(watch, of: apps, found: found) }
            }
        }
    }

    /// What a check that ended for a reason of Mantel's (what it did, the reveal, MenuBarAgent) answers: nothing at a quit or a reset, else the
    /// apps that were confirmed before it. An app is confirmed only after a round whose frames and look both passed the same guards, so its
    /// strip predates the change and its picture is sound.
    private func endedBy(_ why: String, _ watch: StillCurrentWatch, _ found: StillCurrentFindings) -> StillCurrentAnswer {
        found.answer(kept: isQuitting || resetting ? [] : watch.confirmed, outOfTime: false, adding: why)
    }

    /// What a check that ended by its bound answers: the apps that were confirmed, and that the rest weren't judged in time.
    private func outOfTime(_ watch: StillCurrentWatch, of apps: Set<String>, found: StillCurrentFindings) -> StillCurrentAnswer {
        found.answer(for: watch, kept: watch.keptWhenOutOfTime, of: apps)
    }

    /// Whether MenuBarAgent is running, and is the process the read was taken from (when that is known); else what is the matter.
    private func whyAgentIsNotTheReads(_ taken: TakenRead) async -> String? {
        guard let now = await scanner.menuBarAgentPID() else { return "MenuBarAgent isn't running" }
        guard let before = taken.agentPID, before != now else { return nil }
        return "MenuBarAgent is another process than the read's (\(before) then, \(now) now)"
    }

    /// Runs one read of the apps with at most this much time (`AXReadScope`): a read that has none left asks nobody.
    private func readingFor<Result: Sendable>(_ time: TimeInterval, _ read: @Sendable () async -> Result) async -> Result {
        let scope = AXReadScope(budget: max(0, time), perAppBudget: AXPatience.standard.perAppBudget, clock: clock)
        return await AXReadScope.run(scope, read)
    }

    /// What has changed since the read that the pictures are of, when Mantel has: it is quitting or resetting, the count of its changes of
    /// the bar has moved (and what the last was), or the reveal the read was taken for is over. Nil when nothing has.
    private func whyNotUnchanged(since taken: TakenRead, generation: Int?) -> String? {
        if isQuitting { return "Mantel is quitting" }
        if resetting { return "the menu bar is being reset" }
        if taken.barChanges != barChanges {
            let times = barChanges - taken.barChanges
            return "Mantel changed the bar after the read (\(times) time\(times == 1 ? "" : "s"); the last: \(lastBarChange))"
        }
        if let generation, generation != revealGeneration { return "the reveal the read was taken for is over" }
        return nil
    }

    // MARK: A click's picture

    /// The picture of the icon that a click found drawn, from a read taken for the click: the location says which slot, and the read says
    /// what is on the bar now, so the picture is of the bar as that read has it (`isStillCurrent`), never of an old read. Nothing is done
    /// when nothing takes pictures, during a reset or a quit, or when the read can't be taken.
    public func captureClickedIcon(_ location: ItemLocation) async {
        guard imageCollector != nil else { return }
        var tries = 0
        while true {
            // The click's own plans (the icon's reveal, the room made for it) have to be drawn before the bar is read.
            await waitForTheBarToBeStill()
            guard !isQuitting, !resetting, let taken = await requestRead(.reveal) else { return }
            let summary = await takePictures(.clickDrawn(location), taken: taken)
            tries += 1
            guard Self.barChangedUnderIt(summary), tries < captureTries else { return }
        }
    }

    // MARK: The recording indicator

    /// While the quiet period runs after a strip was taken (when the rules have one), the read without the recording indicator's item: the
    /// indicator that a capture can make appear says nothing of the menu bar. The log says so once for as long as Mantel runs.
    func droppingTheIndicator(from read: Inventory) async -> Inventory {
        guard let collector = imageCollector, let quiet = collector.rules.indicatorQuietPeriod,
              let last = await collector.lastStripAt, clock.now().timeIntervalSince(last) < Self.seconds(quiet) else { return read }
        let indicator = ItemID.system(Self.recordingIndicatorModule)
        guard read.items.contains(where: { $0.id == indicator }) else { return read }
        if !indicatorQuietLogged {
            indicatorQuietLogged = true
            Log.info("session", Self.indicatorQuietLogLine)
        }
        // Its slot is still on the bar: it stays as one nobody's, so that it isn't counted as room.
        var untied = read.untiedSlots
        for item in read.items where item.id == indicator {
            for (display, frame) in item.frames { untied[display, default: []].append(frame) }
        }
        return Inventory(capturedAt: read.capturedAt, bars: read.bars, items: read.items.filter { $0.id != indicator },
                         chevrons: read.chevrons, reach: read.reach, problems: read.problems, unansweredApps: read.unansweredApps,
                         untiedSlots: untied, activeDisplay: read.activeDisplay, barSlots: read.barSlots,
                         contestedApps: read.contestedApps, incompleteApps: read.incompleteApps, appProcesses: read.appProcesses,
                         agentReadCut: read.agentReadCut, runningApps: read.runningApps)
    }

    // MARK: Small things

    private static func skipped(_ reason: String) -> CaptureSummary {
        CaptureSummary(captured: 0, changed: 0, skipped: reason)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
