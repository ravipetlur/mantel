import Foundation
import MKCore
import MKLayout

/// Why the session asks for a write of the order table (P6): what the person did, apps that appeared while the new-items marker is
/// placed, or a change of the dots' placement or of Mantel's own items. Only for the log: every cause is written the same way.
public enum LayoutChangeCause: Sendable, Equatable {
    case person, newApps, placementOrOwnItems
}

/// A read of the bar for a check of a write, with the apps the scanner was told not to believe the places of when it was taken: the plan
/// in force then, which may not be the plan that was in force when the write was asked for.
public struct CheckRead: Sendable {
    public let inventory: Inventory
    public let concealedApps: Set<String>

    public init(_ inventory: Inventory, concealedApps: Set<String>) {
        self.inventory = inventory
        self.concealedApps = concealedApps
    }
}

/// Writes the order the person arranged into macOS's table, checks that the bar shows it, and puts the original back on request.
///
/// A write runs on a task of the applier's own, so that whoever asks never waits for it (`MenuBarController`'s event queue among them):
/// - **`request`** keeps the newest inputs and returns. The task then waits one second for more (newest inputs win), waits while the
///   layout is held (`held`: the wide spacer is in force; the inputs are kept, not dropped), reads the
///   table, works the arrangement out from the inputs and the table (`systemStart` and the rules are the applier's), finds the keys,
///   puts every token it writes inside the gap the apps it doesn't write leave (`OwnItemPlacer`), and writes what differs.
/// - **Then the bar settles.** From the write until verification ends, `phase` says the layout is pending and settling, so that nothing
///   that reads the bar judges it or takes its picture. Verification reads the bar (`read`) every 250 ms for `rules.verificationWait`,
///   and a read that shows the order ends it early. Each read is judged against the apps its own scan was told not to believe the places
///   of, not the request's. A bar that still differs at the end gets the write once more and the wait again; a second difference is
///   `notAccepted`, and the table is left as macOS has it. The second write is worked out again from the table as macOS has rewritten it
///   (its distances are not the ones the first was made from), from the last bar read and the set that read was scanned under.
/// - **An app among the modules that stay is never left moved.** The request's read may have lacked those modules. After the first
///   verification, whatever it said, the last bar read says which modules stay: an app the first write moved (by the keys it wrote) whose
///   place before or after it is at or below the left-most of them gets its original distances written back, and the write ends
///   `notAccepted`. So does a second try that would leave out an app the first wrote, because the table as macOS has it now puts it among
///   them. When too little is drawn to compare, cfprefsd holding the values is what counts (P8), and nothing is shown.
/// - **A newer request ends the wait** of an older one: the newer write supersedes it.
/// - **Restoring** is one write of every place Mantel wrote, inside a settle window of its own, and one at a time.
/// - **Quitting** (`flushForQuit`) writes a request that is still in its debounce at once, and doesn't wait for the bar. A worker that is
///   past its debounce when the quit begins hands its request to the flush before it begins to write (`requestUnwritten`).
public actor LayoutApplier {
    public static let debounce: Duration = .seconds(1)
    /// How often verification reads the bar, and how often a held write looks again.
    static let pollInterval: Duration = .milliseconds(250)

    private struct Request {
        let inputs: LayoutInputs
        let ownBundleID: String
        let inventory: Inventory
        let memory: [ItemID: String]
        /// The apps the plan in force doesn't draw (the session knows the plan): the resolver doesn't believe where they were last drawn.
        let concealedApps: Set<String>
        let cause: LayoutChangeCause
    }

    private enum Outcome {
        case matches, differs, cantTell, superseded
    }

    private let writer: any LayoutTableWriting
    private let rules: LayoutRules
    private let clock: any Clock
    private let read: @Sendable () async -> CheckRead?
    private let shownBars: @Sendable (Inventory) -> Set<String>
    private let phase: @Sendable (_ pending: Bool, _ settling: Bool, _ revision: Int) async -> Void
    private let held: @Sendable () async -> String?

    private var newest: Request?
    /// Bumped by every request: a debounce that ends with another number has been asked again.
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var sleeping: Task<Void, any Error>?
    private var restoring: Task<Result<Int, LayoutWriteError>, Never>?
    private var isRestoring = false
    /// Set when the app is quitting: no write is started by the applier's task any more.
    private var isQuitting = false
    /// Whether the quit has begun (`flushForQuit` was called): a test waits for it before it moves a worker that was held.
    var quitHasBegun: Bool { isQuitting }
    /// The worker has taken a request and has not yet handed it to the writer: a quit that begins now hands it to the flush.
    private var requestUnwritten = false
    private var quitFlush = QuitFlush.idle

    private var isPending = false
    private var isSettling = false
    private var reportedPhase: (pending: Bool, settling: Bool) = (false, false)
    private var lastReport: LayoutWriteReport?
    private var lastError: LayoutWriteError?
    private var lastErrorAt: Date?
    private var availability: LayoutWriterAvailability = .needsGrant
    private var hasKept = false
    private var subscribers: [Int: AsyncStream<LayoutStatus>.Continuation] = [:]
    private var nextSubscriber = 0

    public init(writer: any LayoutTableWriting, rules: LayoutRules, clock: any Clock,
                read: @escaping @Sendable () async -> CheckRead?,
                shownBars: @escaping @Sendable (Inventory) -> Set<String>,
                phase: @escaping @Sendable (_ pending: Bool, _ settling: Bool, _ revision: Int) async -> Void,
                held: @escaping @Sendable () async -> String?) {
        self.writer = writer
        self.rules = rules
        self.clock = clock
        self.read = read
        self.shownBars = shownBars
        self.phase = phase
        self.held = held
    }

    // MARK: Asking

    /// Queues the write and returns at once; the applier's own task debounces, writes and verifies. `memory` is the resolver's memory the
    /// session keeps; the report brings the updated one back. Answers the request's revision: the phase callback carries the revision it
    /// was told at, so the session can tell the end of an earlier request from the end of its last. `concealedApps` is the apps the plan in
    /// force doesn't draw.
    @discardableResult
    public func request(_ inputs: LayoutInputs, ownBundleID: String, inventory: Inventory, memory: [ItemID: String],
                        concealedApps: Set<String>, cause: LayoutChangeCause) -> Int {
        newest = Request(inputs: inputs, ownBundleID: ownBundleID, inventory: inventory, memory: memory, concealedApps: concealedApps,
                         cause: cause)
        revision += 1
        isPending = true
        publish()
        if worker == nil, !isQuitting {
            worker = Task { await self.work() }
        }
        return revision
    }

    /// The table through cfprefsd (the writer's read): what the session follows when the file is granted.
    public func readTable() async throws(LayoutWriteError) -> LayoutTableSnapshot {
        try await writer.readTable()
    }

    /// Looks again at whether the table can be written, and at whether Mantel has anything in it: at launch, on a change of the grant and
    /// on Refresh.
    public func refreshAvailability() async {
        await refreshWhatTheWriterSays()
        publish()
    }

    public func status() async -> LayoutStatus {
        await refreshWhatTheWriterSays()
        return makeStatus()
    }

    /// Whether the table can be written (held while the wide spacer has the menu bar) and whether Mantel has anything in it.
    private func refreshWhatTheWriterSays() async {
        availability = await currentAvailability()
        hasKept = await writer.hasKeptChanges
    }

    private func currentAvailability() async -> LayoutWriterAvailability {
        if let reason = await held() { return .held(reason) }
        return await writer.availability()
    }

    /// The status now, and each change of it. Only the newest is kept for a reader that is behind.
    public func statuses() -> AsyncStream<LayoutStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: LayoutStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        continuation.yield(makeStatus())
        return stream
    }

    // MARK: The write

    private func work() async {
        while newest != nil, !isRestoring, !isQuitting {
            await cycle()
        }
        worker = nil
    }

    /// One request: from the debounce to the report. Returns early, saying nothing, when a restore takes over; returns to `work` with a
    /// newer request waiting when it was superseded.
    private func cycle() async {
        await setPhase(pending: true, settling: isSettling)
        // Changes within a second are one write: each request starts the second again.
        while true {
            let seen = revision
            guard await pause(Self.debounce) else { return }
            if seen == revision { break }
        }
        while let reason = await held() {
            availability = .held(reason)
            publish()
            guard await pause(Self.pollInterval) else { return }
        }
        // The hold above is awaited outside `pause`: a quit that began meanwhile leaves the request to its flush.
        guard let request = newest, !isRestoring, !isQuitting else { return }
        newest = nil
        requestUnwritten = true

        var report: LayoutWriteReport?
        var failure: LayoutWriteError?
        var refused = false
        do {
            switch await writer.availability() {
            case .available:
                availability = .available
                switch try await write(request) {
                case .report(let made): report = made
                case .refused: refused = true
                case .superseded: return
                }
            case .needsGrant:
                availability = .needsGrant
                failure = .needsGrant
            case .broken(let text):
                availability = .broken(text)
                failure = .broken(text)
            case .held(let text):
                // A leftover of an earlier version's platform test blocks kept writes until it is put back: nothing is written, and the inputs are not kept.
                availability = .held(text)
            }
        } catch {
            failure = error
            if case .notAccepted = error { Log.warning("layout", LayoutWords.notAcceptedLogLine) }
            // A grant that went stale in the middle of the write, or a table that can't be read: what the writer says now is what is shown.
            availability = await currentAvailability()
        }
        requestUnwritten = false
        if let failure, case .failed(let text) = failure { Log.warning("layout", "the order table wasn't written: \(text)") }

        await finishPhase()
        hasKept = await writer.hasKeptChanges
        // A request that wasn't tried has nothing to say: what the last write reported, and its error, stand.
        guard !refused else {
            publish()
            return
        }
        if let report { lastReport = report }
        lastError = failure
        lastErrorAt = failure == nil ? nil : clock.now()
        publish()
    }

    /// The end of a request. A request that came meanwhile keeps the layout pending: the session never sees it unpending while one waits.
    private func finishPhase() async {
        await setPhase(pending: newest != nil, settling: newest != nil && isSettling)
        if newest != nil, !reportedPhase.pending { await setPhase(pending: true, settling: isSettling) }
    }

    private enum Written {
        case report(LayoutWriteReport)
        /// Nothing was written, and nothing is said of it but the log: the read the write would be planned from has no bars to place on.
        case refused
        case superseded
    }

    /// What one try writes: the arrangement as it is written (what couldn't be placed left out), the keys of its tokens, and the resolution
    /// the verifier goes by.
    private struct Plan {
        /// The table this try was worked out from: what it was before the write.
        let table: LayoutTableSnapshot
        let arrangement: LayoutArrangement
        let keys: [LayoutToken: String]
        let checked: LayoutKeyResolution
        let resolution: LayoutKeyResolution
        let notPlaced: [LayoutToken]
        /// The apps whose places kept one of Mantel's own items from being written.
        let blockedBy: [String]
    }

    /// Reads the table and works out what to write from it: the arrangement, the keys, and where each token goes among the apps that
    /// aren't written. Every try does this from the table as it is then (macOS rewrites it after it re-sorts the bar).
    ///
    /// **Nil when the read it would plan from has no bars to place on** (`LayoutKey.canPlanFrom`): it says nothing of which apps are
    /// running or where the system items end, so nothing is planned from it. The session doesn't send such a request (it waits for a read
    /// that has them); this is the backstop.
    private func plan(_ request: Request, memory: [ItemID: String], read: CheckRead? = nil,
                      earlierKeys: [ItemID: String] = [:]) async throws(LayoutWriteError) -> Plan? {
        let table = try await writer.readTable()
        let inventory = read?.inventory ?? request.inventory
        guard LayoutKey.canPlanFrom(inventory) else { return nil }
        let present = LayoutKey.presentModules(in: inventory, table: table)
        // Where the written tokens may begin counts every module that is drawn; which apps are left alone counts only the ones that stay.
        let systemStart = LayoutMath.systemStart(table: table, presentModules: present, widths: request.inputs.widths)
        let stayingStart = LayoutMath.stayingModulesStart(table: table, presentModules: present)
        let arrangement = LayoutMath.arrange(request.inputs, rules: rules, systemStart: systemStart)
        let resolution = LayoutKeyResolver.resolve(tokens: arrangement.tokens, table: table, inventory: inventory,
                                                   ownBundleID: request.ownBundleID, rules: rules, memory: memory,
                                                   concealedApps: read?.concealedApps ?? request.concealedApps, stayingStart: stayingStart,
                                                   earlierKeys: earlierKeys)
        let placement = OwnItemPlacer.place(arrangement, keys: resolution.keys, table: table, systemStart: systemStart,
                                            ignoring: resolution.outOfTheWay.union(resolution.notRunning))
        let notPlaced = Set(placement.notPlaced)
        let keys = resolution.keys.filter { !notPlaced.contains($0.key) }
        return Plan(table: table, arrangement: OwnItemPlacer.applying(placement, to: arrangement), keys: keys,
                    checked: LayoutKeyResolution(keys: keys, unresolved: resolution.unresolved, memory: resolution.memory),
                    resolution: resolution, notPlaced: placement.notPlaced, blockedBy: placement.blockedBy)
    }

    /// Says which apps' places kept Mantel's own items from being written (bundle IDs only): once for a write, whatever the tries.
    private static func logBlockers(of plan: Plan) {
        guard !plan.blockedBy.isEmpty else { return }
        Log.info("layout", "own items weren't placed because of the places of: \(plan.blockedBy.joined(separator: ", "))")
    }

    private func write(_ request: Request) async throws(LayoutWriteError) -> Written {
        let planned = try await self.plan(request, memory: request.memory)
        // The last moment a quit can take the request: a write that has been handed on can't be called back, and one that hadn't begun goes
        // through the flush's own gate.
        if isQuitting {
            if newest == nil { newest = request }
            requestUnwritten = false
            return .superseded
        }
        requestUnwritten = false
        guard var plan = planned else {
            Log.warning("layout", "the order change wasn't written: the read of the menu bar it was planned from can't be planned from "
                        + "(no bars, no system item drawn, or MenuBarAgent didn't answer)")
            return .refused
        }
        Self.logBlockers(of: plan)
        Log.info("layout", "writing the order (\(request.cause)): \(plan.keys.count) places, \(plan.resolution.unresolved.count) can't be "
            + "reordered, \(plan.notPlaced.count) not placed")

        var wrote = try await writer.write(plan.arrangement, keys: plan.keys)
        var written = wrote.count
        var attempts = 1
        var verdict = LayoutVerdict.matches
        if !wrote.isEmpty {
            await setPhase(pending: true, settling: true)
            var (outcome, lastRead) = await verify(plan.arrangement, resolution: plan.checked)
            let first = plan
            // The request's read may have lacked modules that stay, and put an app among them out of its place: the bar read after the write
            // shows them, whatever the verification said.
            if outcome != .superseded {
                let moved = Self.appsMovedAmongTheStaying(by: first, wrote: wrote, read: lastRead, ownBundleID: request.ownBundleID)
                if !moved.isEmpty { try await putBack(moved, of: first, wrote: wrote) }
            }
            if outcome == .differs {
                // The table is read again: macOS rewrote it when it re-sorted, and the first try's distances mean nothing against it. The
                // bar is the last one read, with the apps its scan was told not to believe, and the nameless items keep the keys they
                // were matched to.
                var namelessKeys: [ItemID: String] = [:]
                for (token, key) in plan.keys {
                    if case .item(let id) = token, !id.isSystem, id.bundleID != request.ownBundleID, case .index = id.key {
                        namelessKeys[id] = key
                    }
                }
                guard let again = try await self.plan(request, memory: plan.resolution.memory, read: lastRead, earlierKeys: namelessKeys)
                else { throw .notAccepted }
                plan = again
                if newest != nil || isRestoring || isQuitting { return .superseded }
                // An app the first try wrote and the second leaves out because it sits among the modules that stay (in the table as macOS
                // has it now) can't be checked: that is not an order that was accepted.
                let leftOut = Self.appsWritten(by: first, wrote: wrote, ownBundleID: request.ownBundleID)
                    .intersection(plan.resolution.amongTheStaying)
                if !leftOut.isEmpty { try await putBack(leftOut, of: first, wrote: wrote) }
                let second = try await writer.write(plan.arrangement, keys: plan.keys)
                wrote += second
                written += second.count
                attempts = 2
                (outcome, lastRead) = await verify(plan.arrangement, resolution: plan.checked)
            }
            switch outcome {
            case .superseded: return .superseded
            case .differs: throw .notAccepted
            case .cantTell: verdict = .cantTell
            case .matches: verdict = .matches
            }
        }
        // Only the apps whose distances were written change their order: what is learned of the order of their items is stale. They are
        // read off the keys written, over both tries (an app written in the first and left out of the second counts).
        let appsWritten = Set(wrote.compactMap { key -> String? in
            if case .status(let bundleID, _)? = LayoutKey.parse(key), bundleID != request.ownBundleID { return bundleID }
            return nil
        })
        return .report(LayoutWriteReport(
            at: clock.now(), written: written, attempts: attempts, verdict: verdict == .cantTell ? "cantTell" : "matches",
            unresolved: plan.resolution.unresolved, memory: plan.resolution.memory, notPlaced: plan.notPlaced.compactMap(Self.name(of:)),
            appsWritten: appsWritten.sorted(), placed: Self.placedOnTheBar(plan)))
    }

    /// The places a try worked out that move an icon on the bar: Mantel's own, and those of apps that are running (the table keeps keys of
    /// apps that aren't, and a lone item of one is given its key all the same).
    private static func placedOnTheBar(_ plan: Plan) -> Int {
        plan.keys.keys.filter { token in
            if case .item(let id) = token { return !plan.resolution.notRunning.contains(id.bundleID) }
            return true
        }.count
    }

    /// The apps a write put a key of, from the keys it wrote (not the ones it planned): what the writer left alone didn't move.
    private static func appsWritten(by plan: Plan, wrote: [String], ownBundleID: String) -> Set<String> {
        Set(writtenTokens(of: plan, wrote: wrote, ownBundleID: ownBundleID).compactMap { token in
            if case .item(let id) = token { id.bundleID } else { nil }
        })
    }

    /// The tokens of apps (not Mantel's own: not its items, nor its spacers and group icons) whose keys the write wrote.
    private static func writtenTokens(of plan: Plan, wrote: [String], ownBundleID: String) -> [LayoutToken] {
        let keys = Set(wrote)
        return plan.keys.compactMap { token, key in
            guard case .item(let id) = token, !id.isSystem, id.bundleID != ownBundleID, id.bundleID != OwnItems.owner, keys.contains(key)
            else { return nil }
            return token
        }
    }

    /// The apps the write moved that have a place among the modules that stay (the left-most one the last read draws, by the table the
    /// try was worked out from): the app's distance in that table, or the one written, is at or below that module's own. Empty when no
    /// read was taken. The resolver keeps an app out of a write when the read it plans from draws those modules; this is for the read
    /// that didn't.
    private static func appsMovedAmongTheStaying(by plan: Plan, wrote: [String], read: CheckRead?, ownBundleID: String) -> Set<String> {
        guard let read else { return [] }
        let present = LayoutKey.presentModules(in: read.inventory, table: plan.table)
        let start = LayoutMath.stayingModulesStart(table: plan.table, presentModules: present)
        guard start > 0 else { return [] }
        var moved: Set<String> = []
        for token in writtenTokens(of: plan, wrote: wrote, ownBundleID: ownBundleID) {
            guard case .item(let id) = token, let key = plan.keys[token] else { continue }
            if let before = plan.table.distances[key], before <= start { moved.insert(id.bundleID) }
            if let written = plan.arrangement.distances[token], written <= start { moved.insert(id.bundleID) }
        }
        return moved
    }

    /// Ends the write as not accepted, because it moved these apps, which sit among the modules that stay. When the table is still in the
    /// numbering the try was worked out from (every key the write didn't write has the distance it had, within 0.25), every key the write
    /// wrote is written back at the distance it had before (the apps', Mantel's own items' and the dots' alike), so the table is as it was
    /// and nothing ends up across a dot; the bar is then given the verification wait to re-sort. When macOS has renumbered the table since,
    /// or it can't be read, nothing is written: the old distances no longer mean the places they were.
    private func putBack(_ apps: Set<String>, of plan: Plan, wrote: [String]) async throws(LayoutWriteError) {
        Log.warning("layout", "the order isn't accepted: the write moved apps that sit among the modules that stay "
            + "(\(apps.sorted().joined(separator: ", ")))")
        let written = Set(wrote)
        guard let now = try? await writer.readTable(), Self.keepsItsNumbering(now, from: plan.table, except: written) else {
            Log.warning("layout", "the places weren't written back: the order table has changed since the write")
            throw .notAccepted
        }
        var distances: [LayoutToken: Double] = [:]
        var keys: [LayoutToken: String] = [:]
        for (token, key) in plan.keys where written.contains(key) {
            guard let before = plan.table.distances[key] else { continue }
            distances[token] = before
            keys[token] = key
        }
        if !keys.isEmpty {
            // Left to right, as an arrangement is.
            let tokens = distances.sorted { $0.value > $1.value }.map(\.key)
            do {
                _ = try await writer.write(LayoutArrangement(tokens: tokens, distances: distances, skipped: []), keys: keys)
                Log.info("layout", "the places the write changed are written back")
                _ = await pause(rules.verificationWait)
            } catch {
                Log.warning("layout", "the places weren't written back: \(error.localizedDescription)")
            }
        }
        throw .notAccepted
    }

    /// Whether `now` is in the numbering of `before`: every key of `before` that isn't in `except` and that `now` has is at the same
    /// distance, within 0.25.
    private static func keepsItsNumbering(_ now: LayoutTableSnapshot, from before: LayoutTableSnapshot, except: Set<String>) -> Bool {
        before.distances.allSatisfy { key, distance in
            except.contains(key) || now.distances[key].map { abs($0 - distance) <= 0.25 } ?? true
        }
    }

    /// Reads the bar every 250 ms for the verification wait; a read that shows the order ends it. What the last read said stands at the
    /// end (`cantTell` when none could be taken). A newer request, or a restore, ends it at once. The last step is cut short so that the
    /// last read is at the end of the wait, not after it. Each read is judged against the apps its own scan was told not to believe the
    /// places of. Answers the last bar read too (nil when none could be taken).
    ///
    /// **The wait is time on the clock,** from the start: a read on a busy Mac takes seconds, and the time it takes counts, so that the
    /// verification ends by its wait and one more read, and not after twelve of them.
    private func verify(_ arrangement: LayoutArrangement, resolution: LayoutKeyResolution) async -> (outcome: Outcome, read: CheckRead?) {
        let began = clock.now()
        var waited: Duration { .milliseconds(Int((clock.now().timeIntervalSince(began) * 1000).rounded())) }
        var last = LayoutVerdict.cantTell
        var lastRead: CheckRead?
        while waited < rules.verificationWait {
            if newest != nil || isRestoring || isQuitting { return (.superseded, lastRead) }
            let step = min(Self.pollInterval, rules.verificationWait - waited)
            guard await pause(step) else { return (.superseded, lastRead) }
            guard let taken = await read() else { continue }
            lastRead = taken
            last = LayoutVerifier.verdict(arrangement, resolution: resolution, read: taken.inventory, shownBars: shownBars(taken.inventory),
                                          frames: rules.frames, concealedApps: taken.concealedApps)
            if last == .matches { return (.matches, lastRead) }
        }
        if newest != nil || isRestoring || isQuitting { return (.superseded, lastRead) }
        switch last {
        case .matches: return (.matches, lastRead)
        case .differs: return (.differs, lastRead)
        case .cantTell: return (.cantTell, lastRead)
        }
    }

    // MARK: Quitting

    /// Where `flushForQuit` is: the caller bounds it by time, and what it does after the bound depends on this.
    private enum QuitFlush {
        case idle, waiting, abandoned, writing, done
    }

    /// What `abandonQuitFlush` found the flush doing.
    public enum QuitFlushOutcome: Sendable, Equatable {
        /// It hadn't begun to write, and won't: the change is dropped.
        case stopped
        /// The write was handed to the writer before the bound passed: it can't be called back, and completes.
        case writeBegun
        /// It had ended already.
        case finished
        /// Nothing was waiting to be written: the worker had no request that hadn't begun (its write had been handed to the writer, it was
        /// verifying one, or it was idle). A write that was handed on may finish after the bound; nothing is logged of it.
        case nothingWaiting
    }

    /// The app is quitting: a request that is still waiting (in its debounce, or held) is written at once, and the bar isn't waited for.
    /// One that can't be written (held, no grant) is dropped and the log says so. The applier starts nothing after this. A caller that
    /// can't wait for ever calls `abandonQuitFlush` at its limit: a flush that hasn't begun to write then doesn't.
    public func flushForQuit() async {
        isQuitting = true
        if quitFlush == .idle { quitFlush = .waiting }
        defer { quitFlush = .done }
        sleeping?.cancel()
        await worker?.value
        guard let request = newest else { return }
        newest = nil
        // Until the write is handed on, the flush holds a request that `abandonQuitFlush` has to count.
        requestUnwritten = true
        defer { requestUnwritten = false }
        guard quitFlush == .waiting else { return }
        guard await held() == nil, case .available = await writer.availability() else {
            Log.warning("quit", "the order change made just before quitting wasn't written (the table can't be written now)")
            return
        }
        do {
            guard let plan = try await self.plan(request, memory: request.memory) else {
                Log.warning("quit", "the order change made just before quitting wasn't written (the menu bar couldn't be read)")
                return
            }
            // The last moment it can still be stopped: a write that has been handed on can't be called back.
            guard quitFlush == .waiting else { return }
            quitFlush = .writing
            let wrote = try await writer.write(plan.arrangement, keys: plan.keys)
            Self.logBlockers(of: plan)
            Log.info("layout", "wrote the order at quit: \(wrote.count) places")
        } catch {
            Log.warning("layout", "the order change made just before quitting wasn't written: \(error.localizedDescription)")
        }
    }

    /// The caller's limit on `flushForQuit` has passed: a flush that hasn't begun to write won't, and the answer says which it was.
    public func abandonQuitFlush() -> QuitFlushOutcome {
        switch quitFlush {
        case .idle, .waiting:
            let waiting = newest != nil || requestUnwritten
            quitFlush = .abandoned
            return waiting ? .stopped : .nothingWaiting
        case .abandoned: return .stopped
        case .writing: return .writeBegun
        case .done: return .finished
        }
    }

    // MARK: Restoring

    /// Puts back every place Mantel wrote: the layout is settling meanwhile, as for a write, and a read from the table follows it. One at a
    /// time: a second call while one runs is answered with the first's result. A write that is waiting is dropped (its inputs are
    /// of an arrangement that is being put back), and one that is being written is let finish first.
    public func restoreOriginal() async -> Result<Int, LayoutWriteError> {
        if let restoring { return await restoring.value }
        let task = Task { await self.restore() }
        restoring = task
        let result = await task.value
        restoring = nil
        return result
    }

    private func restore() async -> Result<Int, LayoutWriteError> {
        if let reason = await held() { return .failure(.failed(reason)) }
        isRestoring = true
        defer { isRestoring = false }
        newest = nil
        sleeping?.cancel()
        await worker?.value

        await setPhase(pending: true, settling: true)
        let result: Result<Int, LayoutWriteError>
        do {
            let count = try await writer.restoreOriginalLayout()
            if count > 0 { _ = await pause(rules.verificationWait, endsForRestore: false) }
            result = .success(count)
        } catch {
            result = .failure(error)
        }
        // A request that came while the restore ran keeps the layout pending: its write goes on when this ends, and nothing follows meanwhile.
        await setPhase(pending: newest != nil, settling: false)
        // The table is read again (the session follows it) now that the bar is still.
        if newest == nil { _ = await read() }
        hasKept = await writer.hasKeptChanges
        if case .failure(let error) = result { lastError = error } else { lastError = nil }
        lastErrorAt = lastError == nil ? nil : clock.now()
        publish()
        // A request that came while the restore ran waited for it: its write goes on now.
        isRestoring = false
        if newest != nil, worker == nil { worker = Task { await self.work() } }
        return result
    }

    // MARK: Inside

    /// Sleeps on the clock. False when it was cut short: a restore took over (unless this is the restore's own wait), or the task was
    /// cancelled.
    private func pause(_ duration: Duration, endsForRestore: Bool = true) async -> Bool {
        if isQuitting || (isRestoring && endsForRestore) { return false }
        let clock = clock
        let sleeper = Task { try await clock.sleep(for: duration) }
        sleeping = sleeper
        let outcome = await sleeper.result
        sleeping = nil
        if case .failure = outcome { return false }
        return !(isQuitting || (isRestoring && endsForRestore))
    }

    /// Tells the session the phase, when it isn't what it was last told.
    private func setPhase(pending: Bool, settling: Bool) async {
        isPending = pending
        isSettling = settling
        publish()
        guard reportedPhase.pending != pending || reportedPhase.settling != settling else { return }
        reportedPhase = (pending, settling)
        await phase(pending, settling, revision)
    }

    private func makeStatus() -> LayoutStatus {
        LayoutStatus(availability: availability, lastReport: lastReport, lastError: lastError, isPending: isPending,
                     isSettling: isSettling, hasKeptChanges: hasKept, dotsPlacementOffered: rules.dotsPlacementOffered,
                     lastErrorAt: lastErrorAt)
    }

    private func publish() {
        let status = makeStatus()
        for continuation in subscribers.values { continuation.yield(status) }
    }

    private func dropSubscriber(_ id: Int) {
        subscribers[id] = nil
    }

    /// The autosave name of an own item's token, or the identity of an app's item, for the report.
    private static func name(of token: LayoutToken) -> String? {
        switch token {
        case .dot(.hidden): OwnItems.hiddenDotName
        case .dot(.always): OwnItems.alwaysDotName
        case .divider: OwnItems.dividerName
        case .item(let id): OwnItems.autosaveName(of: id) ?? id.string
        }
    }
}
