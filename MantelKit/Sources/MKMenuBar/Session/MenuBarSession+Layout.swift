import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout

/// The person's arrangement reaching macOS's order table, and the table's (or the bar's) order reaching the sections.
///
/// - **Asking for a write** (P6). Only the person's own changes ask: moving an app or an item, `insert`, the own-item operations, an app
///   into a group, the new-items marker, the dots' placement or the divider; and apps that appear while Mantel runs with the marker placed.
///   Never automatic overflow, the follower, an own item showing or hiding, the launch read, a refresh or a reset.
/// - **Without the file.** While the layout file isn't given (or reordering is off on this Mac) a change isn't sent: it waits, and is sent
///   from the arrangement as it is when that changes, so no error is made of every change before the file is granted.
/// - **Pending first.** The session is pending before it asks (and while it asks: `layoutRequestsInFlight`), so no read in between follows
///   the order and puts the change back. The applier's phase callback (`setLayoutPhase`) says when its verification is over.
/// - **Following** (P10, P42, P43). Every read that isn't taken while a write is pending or settling puts the icons of each section in the
///   order macOS shows. From the table when the layout file is granted and the resolution covers the apps (the key match is
///   `.autosaveIndex` or `.byDistance`: under `.identifiersOnly` and `.byRank` an app can stay without a key, so a drag of it would never be
///   seen there); otherwise from the bar, by where each icon is. Sections change only for the read that follows a ⌘-drag
///   (`commandDragEnded`), and only for apps that moved. What is found this way is saved and applied, and **never** sent to the applier.
/// - **Settling.** While the bar is being re-sorted, no read is judged (`readShowsThePlan`) and no picture is taken (`layoutCaptureRefusal`).
extension MenuBarSession {
    /// How often the order table is read for the follower at most.
    static let tableReadInterval: Duration = .seconds(2)

    // MARK: Setting up

    /// Sets what writes the order table (nil writes nothing), the rules for how macOS keeps it, and the settings that change the arrangement.
    /// Called again when the settings change: a change of the dots' placement or of the divider asks for a write.
    public func setLayout(_ applier: LayoutApplier?, rules: LayoutRules, settings: LayoutSettings, dots: DotSettings) async {
        let before = (placement: effectivePlacement, divider: layoutDots.showsDivider)
        let sameApplier = applier === layoutApplier
        layoutRules = rules
        layoutSettings = settings
        layoutDots = dots
        guard let applier else {
            layoutStatusTask?.cancel()
            layoutStatusTask = nil
            layoutApplier = nil
            layoutStatus = nil
            layoutPending = false
            layoutSettling = false
            layoutDeferredCause = nil
            layoutFollowWaits = false
            layoutRequestedRevision = 0
            layoutPhaseRevision = 0
            return
        }
        if !sameApplier {
            layoutStatusTask?.cancel()
            layoutApplier = applier
            // Each applier numbers its requests from the start.
            layoutRequestedRevision = 0
            layoutPhaseRevision = 0
            layoutStatusTask = Task { [weak self] in
                for await status in await applier.statuses() { await self?.layoutStatusChanged(status) }
            }
            await applier.refreshAvailability()
            return
        }
        if isStarted, before.placement != effectivePlacement || before.divider != dots.showsDivider {
            await requestLayoutWrite(.placementOrOwnItems)
        }
    }

    /// The layout file was given or taken away, or Refresh was pressed: whether the table can be written is looked at again.
    ///
    /// A change that was made while it couldn't be written (`layoutDeferredCause`) is sent now, from the arrangement as it is.
    public func layoutAvailabilityChanged() async {
        guard let applier = layoutApplier else { return }
        await applier.refreshAvailability()
        tableRead = nil
        guard let cause = layoutDeferredCause else { return }
        await layoutStatusChanged(await applier.status())
        guard !layoutCantBeWritten else { return }
        layoutDeferredCause = nil
        await requestLayoutWrite(cause)
    }

    /// A change that waited for a read with bars (`sendLayoutRequest`) is sent with the read that has them, before that read is followed:
    /// the layout is pending then, so the follow doesn't put the change back.
    func sendDeferredLayoutChange(after read: Inventory) async {
        guard let cause = layoutDeferredCause, LayoutKey.canPlanFrom(read), !layoutCantBeWritten else { return }
        layoutDeferredCause = nil
        await requestLayoutWrite(cause)
    }

    /// What the applier says about the phase of a write: pending from the request until verification ends, settling from the write until
    /// then. The bar is counted as changed when a write becomes pending and when it starts and ends settling, so that a picture whose strip
    /// spans a write is never kept.
    ///
    /// `revision` is the newest request the applier had when it said this (`LayoutApplier.request` answers each request's): a request
    /// the session made after it keeps the session pending, so the end of an earlier request is never taken for the end of the last. Left
    /// out, it ends every request the session has made.
    public func setLayoutPhase(pending: Bool, settling: Bool, revision: Int? = nil) async {
        let was = (pending: layoutIsPending, settling: layoutSettling)
        layoutPending = pending
        layoutSettling = settling
        layoutPhaseRevision = max(layoutPhaseRevision, revision ?? layoutRequestedRevision)
        if (layoutIsPending && !was.pending) || was.settling != settling { noteBarChange("the order table's write was \(settling ? "settling" : "over")") }
        if was.settling && !settling { tableRead = nil }
        publish()
        takeTheWaitingFollow()
    }

    /// A ⌘-drag that ended while a write was under way is followed once nothing is pending or settling any more.
    private func takeTheWaitingFollow() {
        guard layoutFollowWaits, !layoutIsPending, !layoutSettling else { return }
        layoutFollowWaits = false
        // The drag this follow is for: a drag that ends meanwhile has a follow of its own, and its line is its own.
        let drag = dragDrop?.number
        Task { [weak self] in
            _ = await self?.readNow(.layoutFollow)
            await self?.reportTheWaitingFollow(of: drag)
        }
    }

    /// The follow that waited for a write has been taken: the line says how it ended, unless another drag has ended since (that drag's own
    /// follow says how it ended, and the state it keeps is its).
    private func reportTheWaitingFollow(of drag: Int?) {
        guard !layoutFollowWaits, dragDrop?.number == drag else { return }
        reportFollow(nil, limitReached: false)
    }

    /// Whether the bar is being re-sorted by a write of the order table (or a restore).
    public var isLayoutSettling: Bool {
        layoutSettling
    }

    /// Why no picture of the bar is taken now: it is being re-sorted, by a write of the order table or by the person's ⌘-drag (from
    /// `commandDragBegan` to the follow that ends it). What the collector's `mayCapture` answers, at every moment.
    public var layoutCaptureRefusal: String? {
        layoutSettling || dragBefore != nil ? LayoutWords.resorting : nil
    }

    /// A write is asked for or under way: nothing follows the table or the bar.
    var layoutIsPending: Bool {
        layoutPending || layoutRequestsInFlight > 0 || layoutRequestedRevision > layoutPhaseRevision
    }

    /// The layout file isn't given to Mantel, or reordering is off on this Mac: a request would only end in an error.
    private var layoutCantBeWritten: Bool {
        switch layoutStatus?.availability {
        case .needsGrant, .broken: true
        case .available, .held, nil: false
        }
    }

    func layoutStatusChanged(_ status: LayoutStatus) async {
        layoutStatus = status
        if let report = status.lastReport, report != lastTakenReport {
            lastTakenReport = report
            layoutMemory = report.memory
            layoutUnresolved = report.unresolved
            tableRead = nil
            // The order of these apps' own items changed: where they were seen to sit is of the old order.
            if !report.appsWritten.isEmpty { await scanner.forgetPlaces(ofApps: report.appsWritten) }
        }
        publish()
    }

    // MARK: Asking for a write

    /// The arrangement the sections and the settings make, for the writer.
    func layoutInputs() -> LayoutInputs {
        var slotWidths: [ItemID: CGFloat] = [:]
        for item in inventory.items {
            if let width = widths.slotWidth(of: item.id) ?? widths.width(of: item.id) { slotWidths[item.id] = width }
        }
        // An own item's width is its length.
        for (id, spacer) in sections.spacers { slotWidths[OwnItems.itemID(id)] = CGFloat(spacer.width) }
        return LayoutInputs(sections: sections, placement: effectivePlacement,
                            alwaysDotShown: layoutDots.alwaysDot == .always || alwaysHiddenHasApps(),
                            dotsShown: !layoutDots.hideBothDots, dividerShown: layoutDots.showsDivider, widths: slotWidths)
    }

    /// The dots' placement: the person's choice when this Mac can keep them beside the clock, else always between the sections.
    var effectivePlacement: DotsPlacement {
        layoutRules.dotsPlacementOffered ? layoutSettings.dotsPlacement : .betweenSections
    }

    /// Asks the applier for a write, with the layout pending from here on.
    func requestLayoutWrite(_ cause: LayoutChangeCause) async {
        let began = beginLayoutRequest()
        await sendLayoutRequest(cause, began: began)
    }

    /// The layout is pending from now, before anything is awaited, until the request has reached the applier (`sendLayoutRequest`, which
    /// follows with the answer). False when there is no writer: nothing is pending then.
    func beginLayoutRequest() -> Bool {
        guard layoutApplier != nil else { return false }
        if !layoutIsPending { noteBarChange("a write of the order table began") }
        layoutRequestsInFlight += 1
        return true
    }

    /// Hands the arrangement as it is now to the applier, which keeps the layout pending from here on. `began` is what `beginLayoutRequest`
    /// answered.
    func sendLayoutRequest(_ cause: LayoutChangeCause, began: Bool) async {
        defer {
            if began {
                layoutRequestsInFlight -= 1
                // A change that is held back leaves no phase to end: a ⌘-drag's follow that was refused meanwhile is taken now.
                takeTheWaitingFollow()
            }
        }
        guard began, let applier = layoutApplier else { return }
        // Without the file there is nothing to write to: the change waits (the arrangement is taken again when it is sent) and no error is
        // made of it. A grant, or a change of availability, sends it (`layoutAvailabilityChanged`).
        guard !layoutCantBeWritten else {
            layoutDeferredCause = cause
            return
        }
        // Never from a read that has no bars (MenuBarAgent is down or restarting, the grant is missing, no read has been taken): it says
        // nothing of which apps are running or where the system items end, and a write planned from it would place icons among them. The
        // change waits for the next read that has them (`sendDeferredLayoutChange`, from `ingest`).
        guard LayoutKey.canPlanFrom(inventory) else {
            if layoutDeferredCause == nil {
                Log.info("layout", "the order change waits for a read of the menu bar it can be planned from (the last one has no bars, no system "
                         + "item drawn, or MenuBarAgent didn't answer)")
            }
            layoutDeferredCause = cause
            return
        }
        let revision = await applier.request(layoutInputs(), ownBundleID: ownBundleID, inventory: inventory, memory: layoutMemory,
                                             concealedApps: appsNotDrawnForLayout(), cause: cause)
        layoutRequestedRevision = max(layoutRequestedRevision, revision)
    }

    // MARK: The person's changes

    /// An icon (an app's, a system item, or one of Mantel's own) put in a section at a place in its list.
    public func insert(_ item: ItemID, in section: MenuBarSection, at index: Int) async {
        await editSections(.person) { $0.insert(item, in: section, at: index) }
    }

    public func addSpacer(_ spacer: LayoutSpacer, in section: MenuBarSection, at index: Int) async {
        await editSections(.placementOrOwnItems) { $0.addSpacer(spacer, in: section, at: index) }
    }

    public func addGroup(_ group: IconGroup, in section: MenuBarSection, at index: Int) async {
        await editSections(.placementOrOwnItems) { $0.addGroup(group, in: section, at: index) }
    }

    public func updateSpacer(_ spacer: LayoutSpacer) async {
        await editSections(.placementOrOwnItems) { $0.updateSpacer(spacer) }
    }

    public func updateGroup(_ group: IconGroup) async {
        await editSections(.placementOrOwnItems) { $0.updateGroup(group) }
    }

    public func removeOwnItem(_ item: ItemID) async {
        await editSections(.placementOrOwnItems) { $0.removeOwnItem(item) }
    }

    /// An app into a group, at a place among its members.
    public func move(app bundleID: String, toGroup group: GroupID, at index: Int) async {
        await editSections(.person) { $0.move(app: bundleID, toGroup: group, at: index) }
    }

    public func setNewItemsMarker(section: MenuBarSection, index: Int?) async {
        await editSections(.person) { $0.setNewItemsMarker(section: section, index: index) }
    }

    // MARK: ⌘-drags

    /// A ⌘-drag began: the order macOS shows now is kept, to find what the drag moved. `showAll` is whether everything is shown on the bar
    /// for it, and if not why, and `seenAt` when the monitor saw the mouse-down: the log says both.
    public func commandDragBegan(showAll: CommandDragLog.ShowAll = .shown, seenAt: Date? = nil) async {
        Log.info("layout", CommandDragLog.beganLine(showAll, toldAfter: seenAt.map { clock.now().timeIntervalSince($0) } ?? 0))
        dragBefore = await observation(of: inventory)
    }

    /// The ⌘-drag ended: after `LayoutFollower.commandDragFollowDelay` (macOS settles the icon it held), a read that may change sections
    /// follows it (P10, P43). The caller keeps what the drag revealed on the bar until `readNow` has returned: an app that is concealed at
    /// the read is never moved.
    ///
    /// The drag is over when this returns, whatever the read made of it: a read that couldn't be followed (it had no bars, or the wait was
    /// cancelled) doesn't leave `dragBefore` set, which would block clicks and captures until the next drag. The one case it is kept in is
    /// a follow a write refused, which is taken when the write ends (`layoutFollowWaits`).
    ///
    /// **A read that is empty, or is missing an app's icons, isn't followed** (`FollowTrust`): on a busy Mac the answers come late, and the
    /// order the drag left would be kept as the read had it, unlike the bar. The follow reads again, after a wait that grows
    /// (`LayoutFollower.commandDragRetryWaits`), with the order macOS showed when the drag began still waiting to be compared.
    ///
    /// `droppedAt` is when the mouse went up, as the monitor saw it (the session may have been busy when the follow was asked for); the log
    /// line that ends the follow counts from it. The follow's own limit counts from when this begins. `end` is how the monitor knew the
    /// drag had ended: with no mouse-up seen (the cap), `droppedAt` is when it was taken as ended, and the line says so.
    public func commandDragEnded(droppedAt: Date? = nil, end: CommandDragLog.End = .mouseUp) async {
        defer { if !layoutFollowWaits { dragBefore = nil } }
        // Time on the clock from the drop: a read on a busy Mac takes seconds, and while the follow runs clicks and captures are refused, so
        // no read begins after `commandDragFollowLimit` whatever the reads before it took.
        let dropped = clock.now()
        dragsEnded += 1
        dragDrop = DragDrop(number: dragsEnded, dropped: droppedAt ?? dropped, begun: dropped, end: end)
        dragFollow = nil
        let limit = Self.seconds(LayoutFollower.commandDragFollowLimit)
        var limitReached = false
        var last: Inventory?
        waiting: do {
            do { try await clock.sleep(for: LayoutFollower.commandDragFollowDelay) } catch { break waiting }
            for wait in LayoutFollower.commandDragRetryWaits.map(Optional.some) + [nil] {
                guard let taken = await requestRead(.layoutFollow) else { break waiting }
                last = taken.inventory
                guard taken.inventory.bars.isEmpty || taken.followNeedsAnotherRead, !isQuitting, let wait else { break waiting }
                guard clock.now().timeIntervalSince(dropped) + Self.seconds(wait) < limit else {
                    limitReached = true
                    break waiting
                }
                do { try await clock.sleep(for: wait) } catch { break waiting }
            }
        }
        // A follow that a write refused is told of now and again when it is taken, at the end of the write.
        if layoutFollowWaits {
            logFollow(.writeUnderWay, limitReached: false)
        } else {
            reportFollow(last, limitReached: limitReached)
        }
    }

    /// The line that says how the follow of the drag ended, and that the follow is over.
    private func reportFollow(_ last: Inventory?, limitReached: Bool) {
        let follow: CommandDragLog.Follow
        if let last, last.bars.isEmpty {
            follow = .noBars
        } else {
            follow = dragFollow ?? .notRun
        }
        logFollow(follow, limitReached: limitReached)
        dragDrop = nil
    }

    private func logFollow(_ follow: CommandDragLog.Follow, limitReached: Bool) {
        guard let drop = dragDrop else { return }
        let now = clock.now()
        Log.info("layout", CommandDragLog.followLine(follow, afterDrop: now.timeIntervalSince(drop.dropped),
                                                     begunAfter: drop.begun.timeIntervalSince(drop.dropped), limitReached: limitReached,
                                                     end: drop.end))
    }

    /// A read now, for this reason (`ScanScheduler.Reason`), waited for. What the layout asks the bar of: a check of a write, and the
    /// follow of a drag.
    public func readNow(_ reason: ScanScheduler.Reason) async -> Inventory? {
        await requestScan(reason)
    }

    /// `readNow(.layoutCheck)`, with the apps the scan was told not to believe the places of: the applier judges each check against the plan
    /// the read was taken under.
    public func readForCheck() async -> CheckRead? {
        guard let taken = await requestRead(.layoutCheck) else { return nil }
        return CheckRead(taken.inventory, concealedApps: taken.concealed)
    }

    /// Whether an order change is waiting to be written or its write is being checked on the bar (`LayoutStatus.isPending` and
    /// `isSettling`). The update's relaunch waits a short while for it, so that a write that has begun isn't cut off.
    public func layoutWriteIsUnderWay() -> Bool {
        guard let status = layoutStatus else { return false }
        return status.isPending || status.isSettling
    }

    /// The order change that is still in its debounce is written at once, for the app is quitting (`LayoutApplier.flushForQuit`), within
    /// `quitLayoutLimit`. Past it, a change that hasn't begun to be written is not written, and the log says it was dropped; one whose write
    /// had begun can't be called back, and the log says it may still complete.
    public func flushLayoutForQuit() async {
        // A change held for a read it can be planned from is from the person: say that it goes unwritten.
        if layoutDeferredCause != nil, !layoutCantBeWritten {
            Log.warning("quit", "the order change that waited for a read of the menu bar it can be planned from isn't written: Mantel is quitting")
        }
        guard let applier = layoutApplier else { return }
        let finished = await TimeBound.finishes(within: Self.quitLayoutLimit, clock: clock) { await applier.flushForQuit() }
        guard !finished else { return }
        switch await applier.abandonQuitFlush() {
        case .stopped: Log.warning("quit", "the order change made just before quitting wasn't written in time and is dropped")
        case .writeBegun: Log.warning("quit", "the order change made just before quitting is still being written and may complete")
        case .finished, .nothingWaiting: break
        }
    }

    /// Puts the order the person had back (one write of every place Mantel wrote, with the bar settling meanwhile) and follows the table.
    /// Answers how many places came back.
    public func restoreOriginalLayout() async -> Result<Int, LayoutWriteError> {
        // A change held for a read with bars is the arrangement from before the restore: it is dropped, or it would be written over it.
        layoutDeferredCause = nil
        guard let applier = layoutApplier else { return .failure(.needsGrant) }
        let result = await applier.restoreOriginal()
        if case .success(let placed) = result { Log.info("layout", "the original layout was restored (places put back: \(placed))") }
        layoutMemory = [:]
        tableRead = nil
        dragBefore = nil
        return result
    }

    // MARK: Following

    /// The sections after following what macOS shows in this read, or nil when nothing changes (or nothing may be followed).
    ///
    /// Not while a write is pending or settling, and not after quitting or during a reset. The table (or the bar) is asked first; what is
    /// followed is then worked out from the sections as they are after that, and only if no write has been asked for meanwhile: this
    /// actor can take another call while it waits, and a person's change must not be put back.
    ///
    /// Answers the sections that follow (nil when nothing changes or nothing may be followed), and whether the read wasn't followed because
    /// it was empty or partial (`FollowTrust`): the verdict of this read, which goes with it (`TakenRead`), and not a state that a read that
    /// is taken in meanwhile can overwrite.
    func followedSections(in read: Inventory, reasons: Set<ScanScheduler.Reason>) async -> (sections: SectionModel?, needsAnotherRead: Bool) {
        let mayChange = reasons.contains(.layoutFollow)
        guard !resetting, !isQuitting else {
            if mayChange {
                dragBefore = nil
                dragFollow = .notRun
            }
            return (nil, false)
        }
        // A drag's follow that is refused because a write is under way keeps what the drag moved, and is taken when the write ends.
        func refused() -> (sections: SectionModel?, needsAnotherRead: Bool) {
            if mayChange, dragBefore != nil {
                layoutFollowWaits = true
                dragFollow = .writeUnderWay
            }
            return (nil, false)
        }
        guard !layoutIsPending, !layoutSettling else { return refused() }
        let observed = await observation(of: read)
        guard !layoutIsPending, !layoutSettling, !resetting, !isQuitting else { return refused() }
        // A read that is missing an app's icons would put the others in the wrong order: it isn't followed, and a drag's follow reads again.
        if let doubt = followTrust.doubt(in: read) {
            if mayChange { dragFollow = .notTrusted(doubt) }
            return (nil, true)
        }
        let before = mayChange ? dragBefore : nil
        if mayChange { dragBefore = nil }
        let followed = LayoutFollower.follow(sections, observed: observed, placement: effectivePlacement, sectionsMayChange: mayChange,
                                             before: before)
        if mayChange { dragFollow = Self.sectionMoves(from: sections, to: followed) }
        return (followed == sections ? nil : followed, false)
    }

    /// The apps whose section is another in `after` than in `before`, for the log.
    static func sectionMoves(from before: SectionModel, to after: SectionModel) -> CommandDragLog.Follow {
        var moves: [String: MenuBarSection] = [:]
        for app in Set(before.apps.keys).union(after.apps.keys) where before.section(ofApp: app) != after.section(ofApp: app) {
            moves[app] = after.section(ofApp: app)
        }
        return moves.isEmpty ? .nothingMoved : .moved(moves)
    }

    /// The order macOS has the icons in: from the table when the writer is available and the resolution covers the apps, otherwise from the
    /// bar. The table is read at most every two seconds, and the resolution (its memory and the items that have no key) is kept.
    func observation(of read: Inventory) async -> ObservedOrder {
        if let applier = layoutApplier, layoutStatus?.availability == .available, let table = await currentTable(applier) {
            let tokens = LayoutMath.arrange(layoutInputs(), rules: layoutRules, systemStart: 0).tokens
            // The apps a write leaves alone (among the modules that stay) are judged here as a write judges them, so that they stay in
            // "can't reorder" across reads.
            let stayingStart = LayoutMath.stayingModulesStart(table: table, presentModules: LayoutKey.presentModules(in: read, table: table))
            func resolve(stayingStart: Double?) -> LayoutKeyResolution {
                LayoutKeyResolver.resolve(tokens: tokens, table: table, inventory: read, ownBundleID: ownBundleID, rules: layoutRules,
                                          memory: layoutMemory, concealedApps: appsNotDrawnForLayout(), stayingStart: stayingStart)
            }
            let resolution = resolve(stayingStart: stayingStart)
            layoutMemory = resolution.memory
            layoutUnresolved = resolution.unresolved
            // The table shows only what has a key. Under `.identifiersOnly` a nameless app has none, and under `.byRank` the apps that stay
            // unresolved have none: a ⌘-drag of one would never be seen there, so the bar is read, where every drawn icon is. The table is
            // used only when the rule gives each nameless item a key or the memory of one (`.autosaveIndex`, `.byDistance`).
            switch layoutRules.keyMatch {
            case .autosaveIndex, .byDistance:
                // The table still holds the keys of the apps a write leaves alone, and a drag of one is seen there: they are only listed.
                return LayoutFollower.observed(from: table, resolution: resolve(stayingStart: nil))
            case .identifiersOnly, .byRank: break
            }
        }
        return LayoutFollower.observed(fromBar: read, frames: layoutRules.frames)
    }

    private func currentTable(_ applier: LayoutApplier) async -> LayoutTableSnapshot? {
        if let tableRead, clock.now().timeIntervalSince(tableRead.at) < Self.tableReadSeconds { return tableRead.table }
        guard let table = try? await applier.readTable() else { return nil }
        tableRead = (clock.now(), table)
        return table
    }

    private static var tableReadSeconds: TimeInterval {
        Double(tableReadInterval.components.seconds) + Double(tableReadInterval.components.attoseconds) / 1e18
    }
}
