import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The applier over a writer that touches no file and a bar that says what the test scripts, on a clock the test moves.
@Suite("Layout applier", .timeLimit(.minutes(1)))
struct LayoutApplierTests {
    private typealias F = LayoutFixtures

    private struct Harness {
        let clock = FakeClock()
        let writer = FakeLayoutWriter()
        let phases = PhaseLog()
        let reads = ReadScript()
        let held = HeldBox()
        let applier: LayoutApplier

        /// `readTakes` is how long a read of the bar takes on the clock: seconds, on a busy Mac.
        init(rules: LayoutRules = F.rules(), readTakes: Duration = .zero) {
            let writer = writer, phases = phases, reads = reads, held = held, clock = clock
            applier = LayoutApplier(
                writer: writer, rules: rules, clock: clock, read: { writer.note("read"); clock.advance(by: readTakes); return reads.next() },
                shownBars: { Set($0.bars.map(\.displayUUID)) },
                phase: { pending, settling, revision in
                    phases.add(pending, settling, revision)
                    writer.note("phase(\(pending),\(settling))")
                },
                held: { held.current })
        }

        func request(_ inputs: LayoutInputs = F.inputs(), inventory: Inventory = F.ownDrawn(), memory: [ItemID: String] = [:],
                     concealedApps: Set<String> = [], cause: LayoutChangeCause = .person) async {
            await applier.request(inputs, ownBundleID: F.own, inventory: inventory, memory: memory, concealedApps: concealedApps, cause: cause)
        }

        /// Moves the clock 250 ms at a time, whenever something sleeps on it, until the condition holds. False if it doesn't within
        /// ten seconds of real time.
        func drive(until done: @escaping @Sendable () async -> Bool) async -> Bool {
            let clock = clock
            return await withinTimeLimit(.seconds(10)) {
                while await !done() {
                    if await clock.waitForSleepers(1, within: .milliseconds(20)) { clock.advance(by: .milliseconds(250)) }
                }
                return true
            } ?? false
        }

        /// Until the write has ended: the layout isn't pending any more.
        func settled() async -> Bool {
            let applier = applier
            return await drive { await !applier.status().isPending }
        }

        /// Until a restore has written and its wait is over.
        func restored() async -> Bool {
            await drive { writer.restoreCount >= 1 && phases.last?.settling == false }
        }

        /// Until the applier is sleeping and nothing has moved it: a few steps of the clock.
        func advance(_ seconds: Int) async {
            for _ in 0..<(seconds * 4) {
                _ = await clock.waitForSleepers(1, within: .milliseconds(20))
                clock.advance(by: .milliseconds(250))
            }
        }
    }

    private func matching() -> Inventory { F.ownDrawn([.alwaysDot, .hiddenDot, .divider]) }
    private func differing() -> Inventory { F.ownDrawn([.divider, .hiddenDot, .alwaysDot]) }

    // MARK: Asking

    @Test func requestReturnsBeforeTheWrite() async {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request()

        // Back already, with the layout pending and nothing written.
        #expect(await h.applier.status().isPending)
        #expect(h.writer.writeCount == 0)
        #expect(await h.settled())
        #expect(h.writer.writeCount == 1)
    }

    @Test func requestCarriesMemoryAndTheReportReturnsIt() async throws {
        let rules = F.rules(.byDistance(tolerance: 5))
        let h = Harness(rules: rules)
        let a = F.nameless("a")
        let key = LayoutKey.status(bundleID: "com.example.a", autosaveName: "Item-0")
        h.writer.table = LayoutTableSnapshot(distances: [key: 200])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 50)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(shown: [a])), inventory: inventory, memory: [a: key])
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(report.memory == [a: key], "the memory the session sent comes back, as the resolver kept it")
        #expect(h.writer.writes.first?.keys[.item(a)] == key, "and the key it holds is the one written")
    }

    @Test func rulesAndSystemStartComeFromTheApplier() async throws {
        let table = LayoutTableSnapshot(distances: ["module:Clock": 100])
        let inventory = F.inventory(F.ownDrawn().items + [F.systemItem("clock", x: 900)])
        let inputs = F.inputs(widths: [.system("clock"): 30])

        // The apps begin where the clock's distance and width end (130); the divider is the right-most of the three own items.
        let orderOnly = Harness(rules: F.rules())
        orderOnly.writer.table = table
        orderOnly.reads.answer([matching()])
        await orderOnly.request(inputs, inventory: inventory)
        #expect(await orderOnly.settled())
        let distances = try #require(orderOnly.writer.writes.first?.arrangement.distances)
        #expect(distances[.divider] == 130)
        #expect(distances[.dot(.hidden)] == 139)
        #expect(distances[.dot(.always)] == 177)

        // The rules are the applier's: a distance to the left edge adds each token's own width.
        var leftEdge = F.rules()
        leftEdge.reference = .leftEdge
        let other = Harness(rules: leftEdge)
        other.writer.table = table
        other.reads.answer([matching()])
        await other.request(inputs, inventory: inventory)
        #expect(await other.settled())
        let shifted = try #require(other.writer.writes.first?.arrangement.distances)
        #expect(shifted[.divider] == 139)
        #expect(shifted[.dot(.hidden)] == 177)
    }

    @Test func readTableReadsThroughTheWriter() async throws {
        let h = Harness()
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 0, "module:Battery": 31])
        #expect(try await h.applier.readTable() == h.writer.table)

        h.writer.readError = .needsGrant
        await #expect(throws: LayoutWriteError.needsGrant) { try await h.applier.readTable() }
    }

    // MARK: The write

    @Test func debounceCoalesces() async throws {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request(F.inputs(divider: true))
        _ = await h.clock.waitForSleepers(1, within: .seconds(5))
        h.clock.advance(by: .milliseconds(500))
        // Another change half a second later: the second starts again, and its inputs are the ones written.
        await h.request(F.inputs(divider: false))
        #expect(await h.settled())

        #expect(h.writer.writeCount == 1)
        let write = try #require(h.writer.writes.first)
        #expect(write.arrangement.tokens == [.dot(.always), .dot(.hidden)], "the newest inputs: no divider")
        #expect(LayoutApplier.debounce == .seconds(1))
    }

    @Test func nothingIsWrittenBeforeTheDebounceEnds() async {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request()
        _ = await h.clock.waitForSleepers(1, within: .seconds(5))
        h.clock.advance(by: .milliseconds(900))
        #expect(h.clock.sleeperCount == 1, "the debounce is still sleeping: 900 ms isn't a second")
        #expect(h.writer.writeCount == 0)
        #expect(await h.applier.status().isPending)
    }

    @Test func verifiedEndsWaitEarly() async throws {
        let h = Harness(rules: F.rules(wait: .seconds(5)))
        h.reads.answer([matching()])
        await h.request()
        #expect(await h.settled())

        // The first read after the write showed the order: no more reads for the other four seconds.
        #expect(h.reads.reads == 1)
        let report = try #require(await h.applier.status().lastReport)
        #expect(report.verdict == "matches")
        #expect(report.attempts == 1)
        #expect(report.written == 3)
        #expect(await h.applier.status().lastError == nil)
    }

    @Test func notAcceptedAfterOneRetryStops() async {
        let h = Harness()
        h.reads.answer([differing()])
        await h.request()
        #expect(await h.settled())

        // The bar never showed it: written once more, and then stopped. The table is left as macOS has it.
        #expect(h.writer.writeCount == 2)
        #expect(await h.applier.status().lastError == .notAccepted)
        #expect(await h.applier.status().lastReport == nil)
        #expect(h.phases.last?.pending == false && h.phases.last?.settling == false)
        // And nothing more comes, however long it is left.
        await h.advance(20)
        #expect(h.writer.writeCount == 2)
        #expect(LayoutWriteError.notAccepted.errorDescription == "macOS didn't accept the new order")
    }

    @Test func theVerificationWaitIsTimeOnTheClockAndReadsThatTakeSecondsCountInIt() async {
        // On a busy Mac a read of the bar takes two seconds. The wait is three: it ends by the wait and one more read, not after the dozen
        // reads that a count of the pauses between them would make.
        let h = Harness(rules: F.rules(wait: .seconds(3)), readTakes: .seconds(2))
        h.reads.answer([differing()])
        await h.request()
        #expect(await h.settled())

        let reads = h.writer.eventsWithReads.filter { $0 == "read" }.count
        // Two reads in the first verification and two in the one after the retry's write.
        #expect(reads <= 4, "\(reads) reads")
        #expect(await h.applier.status().lastError == .notAccepted)
    }

    @Test func aFailureCarriesTheTimeItHappened() async {
        let h = Harness()
        h.reads.answer([differing()])
        await h.request()
        #expect(await h.settled())
        let failed = await h.applier.status()
        #expect(failed.lastError == .notAccepted)
        #expect(failed.lastErrorAt == h.clock.now())

        // The next write that is accepted takes the error and its time away.
        h.reads.answer([matching()])
        await h.request()
        #expect(await h.settled())
        let after = await h.applier.status()
        #expect(after.lastError == nil)
        #expect(after.lastErrorAt == nil)
    }

    @Test func aSecondTryThatShowsTheOrderIsAccepted() async throws {
        let h = Harness()
        // Differs through the first wait (4 reads of 250 ms), then matches.
        h.reads.answer([differing(), differing(), differing(), differing(), differing(), matching()])
        await h.request()
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2)
        let report = try #require(await h.applier.status().lastReport)
        #expect(report.attempts == 2)
        #expect(report.written == 6)
        #expect(await h.applier.status().lastError == nil)
    }

    @Test func cantTellNeverToasts() async throws {
        let h = Harness()
        // Nothing comparable is drawn: the write counts as verified by cfprefsd.
        h.reads.answer([F.inventory([])])
        await h.request()
        #expect(await h.settled())

        #expect(h.writer.writeCount == 1)
        #expect(await h.applier.status().lastError == nil)
        #expect(try #require(await h.applier.status().lastReport).verdict == "cantTell")

        // A read that couldn't be taken says nothing either.
        let silent = Harness()
        silent.reads.answer([nil])
        await silent.request()
        #expect(await silent.settled())
        #expect(await silent.applier.status().lastError == nil)
    }

    @Test func nothingToChangeIsNotSettled() async throws {
        let h = Harness()
        h.writer.answerWrites([0])
        await h.request()
        #expect(await h.settled())

        // The table already holds the arrangement: no re-sort is coming, so the bar isn't waited for.
        #expect(h.phases.all == ["phase(true,false)", "phase(false,false)"])
        #expect(h.reads.reads == 0)
        #expect(try #require(await h.applier.status().lastReport).written == 0)
    }

    // MARK: Phases

    @Test func pendingFromRequestUntilVerified() async {
        let h = Harness(rules: F.rules(wait: .seconds(2)))
        h.reads.answer([differing(), differing(), matching()])
        await h.request()
        #expect(await h.applier.status().isPending)

        // Written, and then waiting for the bar: pending the whole time.
        #expect(await h.drive { h.writer.writeCount == 1 })
        #expect(await h.applier.status().isPending)
        #expect(await h.settled())
        #expect(await h.applier.status().isPending == false)
        #expect(h.phases.last?.pending == false)
    }

    @Test func settlingOnlyAroundTheWrite() async {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request()
        #expect(await h.settled())

        // Pending from the request; settling from the write until it is verified; then neither.
        #expect(h.writer.events == ["phase(true,false)", "write", "phase(true,true)", "phase(false,false)"])
        #expect(await h.applier.status().isSettling == false)
    }

    @Test func newerRequestSupersedesWait() async throws {
        let h = Harness(rules: F.rules(wait: .seconds(5)))
        h.reads.answer([differing()])
        await h.request(F.inputs(divider: true))
        #expect(await h.drive { h.writer.writeCount == 1 && h.phases.last?.settling == true })

        // Another change while the first is being waited for: that wait ends, and the newer write goes the same way.
        h.reads.answer([matching()])
        await h.request(F.inputs(divider: false))
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2)
        #expect(h.writer.writes[1].arrangement.tokens == [.dot(.always), .dot(.hidden)])
        let report = try #require(await h.applier.status().lastReport)
        #expect(report.attempts == 1)
        // The layout was pending and settling throughout: it was never told it was over in between.
        let ends = h.phases.all.filter { $0 == "phase(false,false)" }
        #expect(ends.count == 1)
        #expect(await h.applier.status().lastError == nil)
    }

    // MARK: Held

    @Test func heldUnderTheWideSpacer() async {
        let h = Harness()
        h.reads.answer([matching()])
        h.held.set(LayoutHold.reason(engine: .spacer))
        await h.request()
        await h.advance(3)
        #expect(h.writer.writeCount == 0)
        #expect(await h.applier.status().isPending)
        #expect(await h.applier.status().availability == .held("The wide spacer is hiding icons, so Mantel waits to change the order."))

        h.held.set(LayoutHold.reason(engine: .allowlist))
        #expect(await h.settled())
        #expect(h.writer.writeCount == 1)
    }

    @Test func theHoldTextsAreTheOnesGiven() {
        #expect(LayoutHold.reason(engine: .spacer) == "The wide spacer is hiding icons, so Mantel waits to change the order.")
        #expect(LayoutHold.reason(engine: .allowlist) == nil)
        #expect(LayoutHold.reason(engine: nil) == nil)
    }

    // MARK: Putting back

    @Test func restoreIsSettled() async throws {
        let h = Harness(rules: F.rules(wait: .seconds(1)))
        h.writer.kept = true
        h.reads.answer([matching()])

        let applier = h.applier
        let restoring = Task { await applier.restoreOriginal() }
        // Settling from before the write until after the wait; then the read that follows the table.
        #expect(await h.drive { h.writer.restoreCount == 1 })
        #expect(await h.applier.status().isSettling)
        #expect(await h.restored())
        let result = await restoring.value

        #expect(result == .success(3))
        #expect(h.writer.events == ["phase(true,true)", "restore", "phase(false,false)"])
        #expect(h.reads.reads == 1, "a read of the bar follows the table once it is still")
        let status = await h.applier.status()
        #expect(status.isSettling == false && status.isPending == false)
        #expect(status.hasKeptChanges == false)
    }

    @Test func restoreWithNothingKeptDoesNotWait() async {
        let h = Harness()
        h.writer.restoreAnswer = 0
        h.reads.answer([matching()])
        #expect(await h.applier.restoreOriginal() == .success(0))
        #expect(h.writer.events == ["phase(true,true)", "restore", "phase(false,false)"])
    }

    @Test func aFailedRestoreIsAnswered() async {
        let h = Harness()
        h.writer.restoreError = .failed("macOS didn't keep the change to this setting.")
        h.reads.answer([matching()])
        #expect(await h.applier.restoreOriginal() == .failure(.failed("macOS didn't keep the change to this setting.")))
        #expect(await h.applier.status().lastError == .failed("macOS didn't keep the change to this setting."))
        #expect(h.phases.last?.pending == false)
    }

    @Test func restoresRunOneAtATime() async {
        let h = Harness(rules: F.rules(wait: .seconds(1)))
        h.reads.answer([matching()])
        let applier = h.applier
        let first = Task { await applier.restoreOriginal() }
        let second = Task { await applier.restoreOriginal() }
        #expect(await h.drive { h.writer.restoreCount >= 1 && h.phases.last?.settling == false })
        #expect(await first.value == .success(3))
        #expect(await second.value == .success(3), "the second is answered with the first's result")
        #expect(h.writer.restoreCount == 1, "one write of the kept places, not two that would find the places held")
    }

    @Test func aWaitingWriteIsDroppedByARestore() async {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request()
        _ = await h.clock.waitForSleepers(1, within: .seconds(5))

        let applier = h.applier
        let restoring = Task { await applier.restoreOriginal() }
        #expect(await h.drive { h.writer.restoreCount == 1 })
        #expect(await h.restored())
        _ = await restoring.value
        await h.advance(5)

        #expect(h.writer.writeCount == 0, "the arrangement it was to write is the one being put back")
        #expect(await h.applier.status().isPending == false)
    }

    @Test func aRequestDuringARestoreIsWrittenAfterIt() async {
        let h = Harness(rules: F.rules(wait: .seconds(1)))
        h.reads.answer([matching()])
        let applier = h.applier
        let restoring = Task { await applier.restoreOriginal() }
        #expect(await h.drive { h.writer.restoreCount == 1 })
        await h.request()
        #expect(await h.restored())
        _ = await restoring.value
        #expect(await h.settled())
        #expect(h.writer.writeCount == 1)
    }

    // MARK: Never from following

    // `followedOrderNeverWrites` is in `MenuBarSessionLayoutTests`: it drives a real session follow, from the bar and from the table.

    @Test func commandDragThenEditorDropWritesTheDraggedOrder() async throws {
        let h = Harness()
        h.reads.answer([matching()])
        let a = F.named("a"), b = F.named("b")
        // The person ⌘-dragged b left of a: macOS has it in the table, and the session followed it into the sections without a write.
        h.writer.table = LayoutTableSnapshot(distances: [F.key(b): 200, F.key(a): 120])
        let dragged = F.sections(shown: [b, a])
        await h.advance(2)
        #expect(h.writer.writeCount == 0)

        // An editor drop then asks for a write: the arrangement is the sections as followed, the dragged order.
        let inventory = F.inventory([F.appItem(a, x: 400), F.appItem(b, x: 300)] + F.ownDrawn().items)
        await h.request(F.inputs(dragged), inventory: inventory)
        #expect(await h.settled())

        let write = try #require(h.writer.writes.first)
        let tokens = write.arrangement.tokens
        let positionOfA = try #require(tokens.firstIndex(of: .item(a)))
        let positionOfB = try #require(tokens.firstIndex(of: .item(b)))
        #expect(positionOfB < positionOfA, "b stays left of a")
        let distances = write.arrangement.distances
        #expect(try #require(distances[.item(b)]) > #require(distances[.item(a)]))
    }

    // MARK: Failing

    @Test func unavailableWriterWritesNothing() async {
        let h = Harness()
        h.writer.availabilityNow = .needsGrant
        await h.request()
        #expect(await h.settled())

        #expect(h.writer.writeCount == 0)
        #expect(await h.applier.status().lastError == .needsGrant)
        #expect(await h.applier.status().availability == .needsGrant)
        #expect(h.phases.last?.pending == false)

        let broken = Harness()
        broken.writer.availabilityNow = .broken(LayoutWords.broken)
        await broken.request()
        #expect(await broken.settled())
        #expect(broken.writer.writeCount == 0)
        #expect(await broken.applier.status().lastError == .broken(LayoutWords.broken))

        // A leftover of a platform test blocks kept writes: nothing is written, and nothing is shown as an error.
        let held = Harness()
        held.writer.availabilityNow = .held("A platform test's change hasn't been put back yet.")
        await held.request()
        #expect(await held.settled())
        #expect(held.writer.writeCount == 0)
        #expect(await held.applier.status().lastError == nil)
    }

    @Test func failedIsPublished() async {
        let h = Harness()
        h.writer.writeError = .failed("Mantel lost access to com.apple.MenuBar.plist. Choose it again in Settings › Permissions.")
        h.reads.answer([matching()])
        await h.request()
        #expect(await h.settled())

        #expect(h.writer.writeCount == 1, "no second try")
        #expect(await h.applier.status().lastError == .failed("Mantel lost access to com.apple.MenuBar.plist. Choose it again in Settings › Permissions."))
        #expect(await h.applier.status().lastReport == nil)
        #expect(h.phases.last?.pending == false && h.phases.last?.settling == false)
        #expect(LayoutWriteError.failed("anything").errorDescription == "Couldn't change the menu bar order")
    }

    @Test func aTableThatCantBeReadIsFailedToo() async {
        let h = Harness()
        h.writer.readError = .failed("The file couldn't be read.")
        await h.request()
        #expect(await h.settled())
        #expect(h.writer.writeCount == 0)
        #expect(await h.applier.status().lastError == .failed("The file couldn't be read."))
    }

    @Test func statusesTellEachChange() async throws {
        let h = Harness()
        h.reads.answer([matching()])
        let applier = h.applier
        let seen = Task { () -> [LayoutStatus] in
            var all: [LayoutStatus] = []
            for await status in await applier.statuses() {
                all.append(status)
                if all.contains(where: { $0.lastReport != nil }) { break }
            }
            return all
        }
        await h.request()
        #expect(await h.settled())
        let statuses = await seen.value
        #expect(statuses.contains { $0.isPending })
        #expect(statuses.last?.lastReport?.written == 3)
        #expect(statuses.allSatisfy { $0.dotsPlacementOffered == false })
    }

    // MARK: Mantel's own items by the apps' real places

    private let hiddenName = OwnItems.hiddenDotName
    private let dividerName = OwnItems.dividerName

    @Test func ownItemsAreBetweenTheRealDistancesOfTheAppsBesideThem() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b")
        // Nothing nameless can be placed on this Mac, so only Mantel's own items are written: between a (Hidden) and b (Shown).
        h.writer.table = LayoutTableSnapshot(distances: [LayoutKey.status(bundleID: a.bundleID, autosaveName: "Item-0"): 200,
                                                         LayoutKey.status(bundleID: b.bundleID, autosaveName: "Item-0"): 100])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(hidden: [a], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        let write = try #require(h.writer.writes.first)
        #expect(Set(write.keys.keys) == [.dot(.always), .dot(.hidden), .divider], "only own items are written")
        let distances = write.arrangement.distances
        let hidden = try #require(distances[.dot(.hidden)]), divider = try #require(distances[.divider])
        #expect(hidden < 200 && hidden > divider && divider > 100, "the dot and the divider sit in the gap between a and b, in order")
        let always = try #require(distances[.dot(.always)])
        #expect(always > 200, "•• is left of a")
        let report = try #require(await h.applier.status().lastReport)
        #expect(report.unresolved == [a, b])
        #expect(report.notPlaced.isEmpty)
    }

    @Test func ownItemsBetweenInterleavedAppsAreNotWritten() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b")
        // a has an item at 150 and another at 50; b's is at 100: they are interleaved, so there is no gap between them.
        h.writer.table = LayoutTableSnapshot(distances: [LayoutKey.status(bundleID: a.bundleID, autosaveName: "Item-0"): 150,
                                                         LayoutKey.status(bundleID: a.bundleID, autosaveName: "Item-1"): 50,
                                                         LayoutKey.status(bundleID: b.bundleID, autosaveName: "Item-0"): 100,
                                                         F.ownKey(OwnItems.hiddenDotName): 120, F.ownKey(OwnItems.dividerName): 110])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(hidden: [a], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        let write = try #require(h.writer.writes.first)
        #expect(Set(write.keys.keys) == [.dot(.always)], "the dot and the divider between a and b aren't written; they stay at 120 and 110")
        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.notPlaced) == [hiddenName, dividerName])
        #expect(await h.applier.status().lastError == nil, "not a failure: they are left where macOS has them")
    }

    @Test func unmeasuredRulesStillWrite() async throws {
        // Before anything is measured the weakest is assumed: an item whose width isn't known has no distance, and is not written.
        var unmeasured = LayoutRules.unmeasured
        unmeasured.verificationWait = .seconds(1)
        let h = Harness(rules: unmeasured)
        let a = F.named("a")
        h.writer.table = LayoutTableSnapshot(distances: [F.key(a): 100])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(shown: [a])), inventory: inventory)
        #expect(await h.settled())

        let write = try #require(h.writer.writes.first)
        #expect(write.arrangement.skipped == [a])
        let distances = write.arrangement.distances
        #expect(distances[.item(a)] == nil, "the app has no distance, so it isn't written (the writer leaves out a token with none)")
        #expect(Set(distances.keys) == [.dot(.always), .dot(.hidden), .divider])
        #expect(try #require(distances[.divider]) > 100, "and they are left of where the app is: it is the one to their right")
    }

    @Test func anAppWithNoKeyDoesNotKeepOwnItemsFromBeingWritten() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b")
        h.writer.table = LayoutTableSnapshot(distances: [LayoutKey.status(bundleID: b.bundleID, autosaveName: "Item-0"): 100])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(hidden: [a], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        // a has no key in the table: nothing says where it is, so nothing is kept on a side of it, and the items between a and b are written
        // right of b (the one app whose place is told), left of the system items' end.
        let report = try #require(await h.applier.status().lastReport)
        #expect(report.notPlaced.isEmpty)
        #expect(report.placed == 3)
        #expect(h.writer.writes.first?.keys.count == 3)
    }

    /// Three apps have keys; the one between the other two in the table's range is either not running (not among the running apps) or
    /// running but showing nothing in the read (it didn't show an item, and its keys are still where the table has them).
    @Test(arguments: [false, true])
    func anAppThatIsntRunningDoesNotKeepOwnItemsFromBeingWrittenButOneThatRunsButShowsNothingStillKeepsItsSide(runs: Bool) async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b"), other = F.nameless("other")
        h.writer.table = LayoutTableSnapshot(distances: [
            LayoutKey.status(bundleID: a.bundleID, autosaveName: "Item-0"): 400, LayoutKey.status(bundleID: b.bundleID, autosaveName: "Item-0"): 100,
            LayoutKey.status(bundleID: other.bundleID, autosaveName: "Item-0"): 50, LayoutKey.status(bundleID: other.bundleID, autosaveName: "Item-1"): 500])
        let items = [F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items
        let inventory = runs ? F.inventory(items, running: Set(items.map(\.ownerBundleID)).union([other.bundleID])) : F.inventory(items)
        h.reads.answer([matching()])

        await h.request(F.inputs(F.sections(hidden: [a, other], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        if runs {
            #expect(report.notPlaced.contains(OwnItems.hiddenDotName), "which apps run comes from the running apps, not from the items the read has")
        } else {
            #expect(report.notPlaced.isEmpty, "the dots are written between a and b whatever keys the app that isn't there still has")
            #expect(report.placed == 3)
        }
    }

    @Test func placedCountsOnlyThePlacesThatMoveAnIconOnTheBar() async throws {
        // The table keeps a key for an app that isn't running, and a lone item is given its key all the same: it is written, and it moves
        // nothing on the bar. Only the apps are in the arrangement here.
        let n = F.named("n")
        let inputs = LayoutInputs(sections: F.sections(shown: [n]), placement: .betweenSections, alwaysDotShown: false, dotsShown: false,
                                  dividerShown: false, widths: [:])
        for running in [false, true] {
            let h = Harness()
            h.writer.table = LayoutTableSnapshot(distances: [F.key(n): 100])
            h.reads.answer([matching()])
            let items = F.ownDrawn().items + (running ? [F.appItem(n, x: 300)] : [])
            await h.request(inputs, inventory: F.inventory(items))
            #expect(await h.settled())
            #expect(h.writer.writes.first?.keys.count == 1, "its place is written either way")
            #expect(try #require(await h.applier.status().lastReport).placed == (running ? 1 : 0))
        }
    }

    // MARK: A read with no bars

    private func readWithNoBars(_ problem: InventoryProblem = .agentNotRunning) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: [], chevrons: [:], reach: [], problems: [problem])
    }

    @Test func nothingIsPlannedFromAReadThatHasNoBars() async throws {
        // The backstop alone: the request carries a read from when MenuBarAgent was down (no bars, no item, so every app would count as not
        // running and the system items' end would be 0).
        let a = F.nameless("a"), b = F.nameless("b")
        let table = LayoutTableSnapshot(distances: [LayoutKey.status(bundleID: a.bundleID, autosaveName: "Item-0"): 400,
                                                    LayoutKey.status(bundleID: b.bundleID, autosaveName: "Item-0"): 100])
        let sectionInputs = F.inputs(F.sections(hidden: [a], shown: [b]))
        // No bars, whichever way it couldn't be taken; and a bar with no system item gives no floor.
        let noFloor = Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [F.bar],
                                items: [F.ownItem(.alwaysDot, x: 100), F.appItem(a, x: 300), F.appItem(b, x: 400)], chevrons: [:], reach: [],
                                problems: [], runningApps: [a.bundleID, b.bundleID])
        for read in [readWithNoBars(), readWithNoBars(.accessibilityNotGranted), readWithNoBars(.agentHasNoWindows), noFloor, Inventory.empty] {
            let h = Harness()
            h.writer.table = table
            h.reads.answer([matching()])
            await h.request(sectionInputs, inventory: read)
            #expect(await h.settled())
            #expect(h.writer.writeCount == 0)
            let status = await h.applier.status()
            #expect(status.lastReport == nil && status.lastError == nil && !status.isPending, "nothing was tried, so nothing is said of it")
        }
        // The same request from a read that has them writes.
        let h = Harness()
        h.writer.table = table
        h.reads.answer([matching()])
        await h.request(sectionInputs, inventory: F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items))
        #expect(await h.settled())
        #expect(h.writer.writeCount == 1)
    }

    @Test func aWriteThatWasRefusedLeavesTheLastReportAndErrorAsTheyWere() async throws {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request()
        #expect(await h.settled())
        let report = try #require(await h.applier.status().lastReport)
        await h.request(inventory: readWithNoBars())
        #expect(await h.settled())
        #expect(await h.applier.status().lastReport == report)
        #expect(h.writer.writeCount == 1)
    }

    // MARK: No app crosses a dot

    private func itemKey(_ id: ItemID) -> String { LayoutKey.status(bundleID: id.bundleID, autosaveName: "Item-0") }

    /// What the table says once the first write is in it.
    private func tableAfterTheFirstWrite(_ h: Harness) throws -> [String: Double] {
        let write = try #require(h.writer.writes.first)
        var table = h.writer.table.distances
        for (token, key) in write.keys { if let distance = write.arrangement.distances[token] { table[key] = distance } }
        return table
    }

    @Test func reorderingInsideHiddenKeepsEveryAppOnItsSideOfTheDot() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b"), c = F.nameless("c")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(a): 300, itemKey(c): 150, itemKey(b): 100])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(c, x: 330), F.appItem(b, x: 400)] + F.ownDrawn().items)

        // The person dragged c before a in Hidden: the arrangement is `•• c a • | b`; the table has a (300) left of c (150).
        await h.request(F.inputs(F.sections(hidden: [c, a], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        let table = try tableAfterTheFirstWrite(h)
        let hidden = try #require(table[F.ownKey(OwnItems.hiddenDotName)]), divider = try #require(table[F.ownKey(OwnItems.dividerName)])
        let always = try #require(table[F.ownKey(OwnItems.alwaysDotName)])
        let aAt = try #require(table[itemKey(a)]), bAt = try #require(table[itemKey(b)]), cAt = try #require(table[itemKey(c)])
        #expect(aAt > hidden && cAt > hidden, "a and c are still left of •")
        #expect(hidden > divider && divider > bAt, "b is still right of • and of the divider")
        #expect(always > aAt && always > cAt, "•• is left of both")
        #expect(h.writer.writes.first?.keys[.item(c)] == nil, "nothing nameless is written")
    }

    @Test func aNewAppWithAFarLeftKeyDoesntMoveTheMarkerPastTheOthers() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b"), c = F.nameless("c"), fresh = F.nameless("fresh")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(a): 300, itemKey(c): 150, itemKey(fresh): 900, itemKey(b): 100])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(c, x: 330), F.appItem(fresh, x: 360), F.appItem(b, x: 400)]
            + F.ownDrawn().items)

        // The marker is at the end of Hidden, and the new app is filed there: `a c fresh • | b`.
        await h.request(F.inputs(F.sections(hidden: [a, c, fresh], shown: [b])), inventory: inventory, cause: .newApps)
        #expect(await h.settled())

        let table = try tableAfterTheFirstWrite(h)
        let hidden = try #require(table[F.ownKey(OwnItems.hiddenDotName)])
        for app in [a, c, fresh] { #expect(try #require(table[itemKey(app)]) > hidden, "\(app.bundleID) stays left of •") }
        #expect(try hidden > #require(table[itemKey(b)]))
    }

    @Test func aNamedAppAmongNamelessOnesIsPlacedByTheirRealPlaces() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b"), n = F.named("n")
        // n names itself (like the test item), and the table has it at 450: right of a (400) which is the other way round from the model.
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(a): 400, itemKey(b): 100, F.key(n): 450])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(n, x: 330), F.appItem(b, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(shown: [a, n, b]), widths: [n: 30]), inventory: inventory)
        #expect(await h.settled())

        let table = try tableAfterTheFirstWrite(h)
        let placed = try #require(table[F.key(n)])
        #expect(placed < 400 && placed > 100, "between a and b, by their real places and not by assumed widths")
        #expect(table[itemKey(a)] == 400 && table[itemKey(b)] == 100, "the nameless ones aren't touched")
    }

    @Test func nothingIsWrittenAmongTheSystemItems() async throws {
        let h = Harness()
        let a = F.nameless("a")
        // The clock is at 200 and 30 wide: the apps begin at 230. The last app is at 400, so the dot and the divider go between.
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 200, itemKey(a): 400])
        h.reads.answer([matching()])
        let inventory = F.inventory(F.ownDrawn().items + [F.appItem(a, x: 300), F.systemItem("clock", x: 900)])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: inventory)
        #expect(await h.settled())

        let table = try tableAfterTheFirstWrite(h)
        for name in [OwnItems.hiddenDotName, OwnItems.dividerName] {
            let distance = try #require(table[F.ownKey(name)])
            #expect(distance > 230 && distance < 400, "\(name) is left of the system items and right of a")
        }
    }

    @Test(arguments: [
        // a (200.4) is meant to be left of c (200), and they are 0.4 apart: n between them has no gap that the writer would keep.
        (a: 200.4, c: 200.0, n: 60.0, written: false),
        // a (100) is meant to be left of c (300), and the table has them the other way round. Neither can be reordered, and n is no less
        // placeable for it: it is written right of the one that agrees with the order of the rest.
        (a: 100.0, c: 300.0, n: 200.0, written: true),
    ])
    func aNamedAppBetweenTwoThatLeaveNoGapOrAreTheOtherWayRoundIsWrittenOnlyWhereTheWriterKeepsIt(
        aAt: Double, cAt: Double, nAt: Double, written: Bool
    ) async throws {
        let h = Harness()
        let a = F.nameless("a"), c = F.nameless("c"), n = F.named("n")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(a): aAt, itemKey(c): cAt, F.key(n): nAt])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(n, x: 330), F.appItem(c, x: 360)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(shown: [a, n, c])), inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(report.notPlaced.contains(n.string) == !written, "an app that wasn't written is in the report")
        #expect(h.writer.writes.first?.keys[.item(n)] == (written ? F.key(n) : nil))
    }

    @Test func ownItemsThatCantBeToldApartFromAnUnplacedOneAreNotWrittenEither() async throws {
        // Interleaved a and b, and the dot isn't in the table yet: its place can't be told, so •• (left of it) can't be put on its side.
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(a): 150, LayoutKey.status(bundleID: a.bundleID, autosaveName: "Item-1"): 50,
                                                         itemKey(b): 100])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(hidden: [a], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        #expect(h.writer.writes.first?.keys.isEmpty == true)
        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.notPlaced) == [hiddenName, dividerName, OwnItems.alwaysDotName])
    }

    /// The table with what a write would put in it laid over it.
    private func laid(_ h: Harness, write index: Int = 0) throws -> [String: Double] {
        let write = try #require(h.writer.writes.count > index ? h.writer.writes[index] : nil)
        var table = h.writer.table.distances
        for (token, key) in write.keys { if let distance = write.arrangement.distances[token] { table[key] = distance } }
        return table
    }

    private func systemInventory(_ apps: [MenuBarItem] = []) -> Inventory {
        F.inventory(F.ownDrawn().items + apps + [F.systemItem("clock", x: 900)])
    }

    @Test func aDotThatCantBePlacedKeepsTheTestItemFromCrossingIt() async throws {
        // This Mac's rules (`.identifiersOnly`): the test item names itself, so it is written; the other apps don't. Hidden [T] and Shown
        // [B, A], packed as macOS leaves them: A 100, B 122, the divider 152, • 161, T 199, the system items ending at 90. No ••.
        let h = Harness()
        let t = F.named("t"), a = F.nameless("a"), b = F.nameless("b")
        h.writer.table = LayoutTableSnapshot(distances: [
            "module:Clock": 60, itemKey(a): 100, itemKey(b): 122, F.ownKey(OwnItems.dividerName): 152, F.ownKey(OwnItems.hiddenDotName): 161,
            F.key(t): 199])
        h.reads.answer([matching()])
        let inventory = systemInventory([F.appItem(t, x: 300), F.appItem(a, x: 330), F.appItem(b, x: 360)])
        // The person dragged A into Hidden: `T A • | B`. The table has B left of A, so • and the divider have no gap.
        let inputs = LayoutInputs(sections: F.sections(hidden: [t, a], shown: [b]), placement: .betweenSections, alwaysDotShown: false,
                                  dotsShown: true, dividerShown: true, widths: [t: 30, .system("clock"): 30])

        await h.request(inputs, inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.notPlaced) == [hiddenName, dividerName], "the dot and the divider have no gap")
        let table = try laid(h)
        let hidden = try #require(table[F.ownKey(OwnItems.hiddenDotName)]), divider = try #require(table[F.ownKey(OwnItems.dividerName)])
        #expect(hidden == 161 && divider == 152, "they stay where macOS has them")
        let testItem = try #require(table[F.key(t)])
        #expect(testItem > hidden, "T is still left of •, so it stays in Hidden")
        #expect(try testItem > #require(table[itemKey(a)]) && testItem > #require(table[itemKey(b)]))
    }

    @Test func aDotThatCantBePlacedKeepsTheOtherDotFromEndingLeftOfIt() async throws {
        // All nameless: Always Hidden [A, D], Hidden and Shown empty, A left of D. Table: the divider 90, • 99, •• 115, D 131, A 155; the
        // system items end at 90. The person puts A in Hidden: `D •• A • |`. •• has no gap (A is left of D in the table), and stays at 115.
        let h = Harness()
        let a = F.nameless("a"), d = F.nameless("d")
        h.writer.table = LayoutTableSnapshot(distances: [
            "module:Clock": 60, F.ownKey(OwnItems.dividerName): 90, F.ownKey(OwnItems.hiddenDotName): 99, F.ownKey(OwnItems.alwaysDotName): 115,
            itemKey(d): 131, itemKey(a): 155])
        h.reads.answer([matching()])
        let inventory = systemInventory([F.appItem(a, x: 300), F.appItem(d, x: 330)])
        let inputs = LayoutInputs(sections: F.sections(always: [d], hidden: [a]), placement: .betweenSections, alwaysDotShown: true,
                                  dotsShown: true, dividerShown: true, widths: [.system("clock"): 30])

        await h.request(inputs, inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(report.notPlaced.contains(OwnItems.alwaysDotName), "•• can't be placed")
        let table = try laid(h)
        let always = try #require(table[F.ownKey(OwnItems.alwaysDotName)]), hidden = try #require(table[F.ownKey(OwnItems.hiddenDotName)])
        let divider = try #require(table[F.ownKey(OwnItems.dividerName)])
        #expect(always > hidden && hidden > divider, "•• is still left of •, which is left of the divider")
        #expect(divider > 90, "and nothing is among the system items")
    }

    @Test func anAppWrittenOnlyByTheFirstTryIsReportedWritten() async throws {
        // Under `.autosaveIndex` x and y are written the first time; macOS rewrites the table without x's key, so the second try leaves it out.
        let h = Harness(rules: F.rules(.autosaveIndex(prefix: "Item-")))
        let x = F.nameless("x"), y = F.nameless("y")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(x): 1, itemKey(y): 1])
        h.writer.tablesAfterWrites([LayoutTableSnapshot(distances: [itemKey(y): 1])])
        // The first try's wait (1 s: four reads) shows a bar that differs; the second try's shows the order.
        h.reads.answer([differing(), differing(), differing(), differing(), matching()])
        let inventory = F.inventory([F.appItem(x, x: 300), F.appItem(y, x: 400)] + F.ownDrawn().items)

        await h.request(F.inputs(F.sections(shown: [x, y]), widths: [x: 30, y: 30]), inventory: inventory)
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2)
        #expect(h.writer.writes.first?.keys[.item(x)] != nil, "the first try wrote x")
        #expect(h.writer.writes.last?.keys[.item(x)] == nil, "the second didn't")
        #expect(try #require(await h.applier.status().lastReport).appsWritten.contains(x.bundleID))
    }

    @Test func theSecondTryIsWorkedOutAgainFromTheTableAsMacOSRewroteIt() async throws {
        let h = Harness()
        let a = F.nameless("a"), b = F.nameless("b")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(a): 300, itemKey(b): 100])
        // macOS re-sorted after the first write and rewrote the table: every distance moved, and the first gap (100, 300) is now below b's.
        h.writer.tablesAfterWrites([LayoutTableSnapshot(distances: [itemKey(a): 600, itemKey(b): 250])])
        let inventory = F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn().items)
        // The bar read after the write has the apps too, as a real read does: the second try goes by the apps it shows.
        h.reads.answer([F.inventory([F.appItem(a, x: 300), F.appItem(b, x: 400)] + F.ownDrawn([.divider, .hiddenDot, .alwaysDot]).items)])

        await h.request(F.inputs(F.sections(hidden: [a], shown: [b])), inventory: inventory)
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2)
        let first = try #require(h.writer.writes.first?.arrangement.distances[.dot(.hidden)])
        let second = try #require(h.writer.writes.last?.arrangement.distances[.dot(.hidden)])
        #expect(first < 300 && first > 100, "the first is between a and b as the table was")
        #expect(first < 250 || first > 600, "the first dot is out of the new gap, so a retry that wrote it again would be wrong")
        #expect(second < 600 && second > 250, "the second is between them as macOS has them now, not where the first put the dot")
    }

    // MARK: Availability after a failure and the apps written

    @Test func availabilityIsLookedAtAgainAfterAFailedWrite() async throws {
        for failure in ["write", "read"] {
            let h = Harness()
            if failure == "write" {
                h.writer.writeError = .failed("Mantel lost access to com.apple.MenuBar.plist.")
            } else {
                h.writer.readError = .needsGrant
            }
            h.writer.availabilityAfterAnError = .needsGrant
            h.reads.answer([matching()])
            let applier = h.applier
            let published = Task { () -> LayoutStatus? in
                for await status in await applier.statuses() where status.lastError != nil { return status }
                return nil
            }
            await h.request()
            let done = await h.drive { h.phases.last?.pending == false }
            #expect(done)
            let status = try #require(await published.value)
            #expect(status.availability == .needsGrant, "published with the error: \(failure)")
        }
    }

    @Test func onlyTheAppsWhoseDistancesChangedAreReportedWritten() async throws {
        let h = Harness(rules: F.rules(.autosaveIndex(prefix: "Item-")))
        h.writer.writesOnlyChanges = true
        let x = F.nameless("x"), y = F.nameless("y")
        h.writer.table = LayoutTableSnapshot(distances: [itemKey(x): 1, itemKey(y): 1])
        h.reads.answer([matching()])
        let inventory = F.inventory([F.appItem(x, x: 300), F.appItem(y, x: 400)] + F.ownDrawn().items)
        let inputs = F.inputs(F.sections(shown: [x, y]), widths: [x: 30, y: 30])
        await h.request(inputs, inventory: inventory)
        #expect(await h.settled())
        #expect(try #require(await h.applier.status().lastReport).appsWritten == [x.bundleID, y.bundleID])

        // x is where the first write put it; y is somewhere else: the second write changes y alone.
        var table = try tableAfterTheFirstWrite(h)
        table[itemKey(y)] = 5000
        h.writer.table = LayoutTableSnapshot(distances: table)
        await h.request(inputs, inventory: inventory)
        #expect(await h.settled())
        #expect(try #require(await h.applier.status().lastReport).appsWritten == [y.bundleID])
    }

    // MARK: The verification wait

    @Test func theLastReadIsAtTheEndOfTheWaitNotAfterIt() async throws {
        let h = Harness(rules: F.rules(wait: .milliseconds(5350)))
        h.reads.answer([F.inventory([])])
        await h.request()
        _ = await h.clock.waitForSleepers(1, within: .seconds(5))
        h.clock.advance(by: LayoutApplier.debounce)
        // 21 steps of 250 ms, and then a last one of 100 ms: 5.35 s in all.
        for step in 1...21 {
            #expect(await h.clock.waitForSleepers(1, within: .seconds(5)))
            h.clock.advance(by: .milliseconds(250))
            #expect(await waitUntil { h.reads.reads == step })
        }
        #expect(await h.clock.waitForSleepers(1, within: .seconds(5)))
        h.clock.advance(by: .milliseconds(100))
        #expect(await waitUntil { h.reads.reads == 22 })
        #expect(await waitUntil { h.phases.last?.pending == false }, "the wait is over at 5.35 s, not at 5.5")
    }

    // MARK: Pending until its own end, and quitting

    @Test func aRequestDuringARestoreKeepsTheLayoutPendingAndTakesNoReadYet() async {
        let h = Harness(rules: F.rules(wait: .seconds(1)))
        h.reads.answer([matching()])
        let applier = h.applier
        let restoring = Task { await applier.restoreOriginal() }
        #expect(await h.drive { h.writer.restoreCount == 1 })
        await h.request()
        #expect(await h.restored())
        _ = await restoring.value

        // The restore's end said settling was over but pending wasn't: the write that waits goes on, and the bar wasn't read meanwhile.
        let events = h.writer.eventsWithReads
        let firstWrite = events.firstIndex(of: "write") ?? events.count
        #expect(!events[..<firstWrite].contains("phase(false,false)"))
        #expect(events[..<firstWrite].contains("phase(true,false)"))
        #expect(!events[..<firstWrite].contains("read"), "and no read of the bar was taken before the write that waited")
        #expect(await h.settled())
    }

    @Test func aRequestAsACycleEndsIsToldAfterTheEndAndTheEndCarriesItsRevision() async throws {
        let clock = FakeClock(), writer = FakeLayoutWriter(), phases = PhaseLog(), reads = ReadScript()
        let reached = Mutex(false), endGate = Gate()
        reads.answer([matching()])
        let applier = LayoutApplier(
            writer: writer, rules: F.rules(), clock: clock, read: { reads.next() }, shownBars: { Set($0.bars.map(\.displayUUID)) },
            phase: { pending, settling, revision in
                phases.add(pending, settling, revision)
                guard !pending else { return }
                reached.withLock { $0 = true }
                await endGate.wait()
            },
            held: { nil })
        let first = await applier.request(F.inputs(), ownBundleID: F.own, inventory: F.ownDrawn(), memory: [:], concealedApps: [], cause: .person)
        // The clock is moved a step at a time, when the applier sleeps on it, until the end of the first request is being told (the phase
        // call waits at `endGate`). No real time decides anything: a loaded machine only makes it slower.
        #expect(await clock.advance(by: .milliseconds(250)) { reached.withLock { $0 } })

        // The end of the first request is being told when the second arrives.
        let second = await applier.request(F.inputs(divider: false), ownBundleID: F.own, inventory: F.ownDrawn(), memory: [:], concealedApps: [], cause: .person)
        endGate.open()
        #expect(second > first)
        #expect(await clock.advance(by: .milliseconds(250)) { phases.count >= 4 && phases.last?.pending == false })

        let revisions = phases.allRevisions
        #expect(revisions.first == first, "the first request's pending carries its revision")
        let firstEnd = try #require(phases.all.firstIndex(of: "phase(false,false)"))
        #expect(revisions[firstEnd] == first, "its end carries the revision it ends, which is older than the request that came meanwhile")
        #expect(revisions.last == second)
    }

    @Test func quittingWritesTheRequestThatIsStillInItsDebounceAtOnce() async throws {
        let h = Harness()
        h.reads.answer([matching()])
        await h.request()
        _ = await h.clock.waitForSleepers(1, within: .seconds(5))

        // No time has passed on the clock: the second hasn't ended.
        await h.applier.flushForQuit()
        #expect(h.writer.writeCount == 1)
        #expect(h.reads.reads == 0, "the bar isn't waited for")
        await h.advance(10)
        #expect(h.writer.writeCount == 1, "nothing more is started")
    }

    @Test func quittingDropsTheRequestThatCantBeWrittenNow() async {
        let held = Harness()
        held.held.set(LayoutWords.heldForTheSpacer)
        await held.request()
        await held.applier.flushForQuit()
        #expect(held.writer.writeCount == 0)

        let ungranted = Harness()
        ungranted.writer.availabilityNow = .needsGrant
        await ungranted.request()
        await ungranted.applier.flushForQuit()
        #expect(ungranted.writer.writeCount == 0)

        let nothing = Harness()
        await nothing.applier.flushForQuit()
        #expect(nothing.writer.writeCount == 0)
    }

    @Test func aFlushThatTheLimitPassesBeforeItsWriteDoesNotWrite() async {
        let h = Harness()
        let gate = Gate()
        h.writer.holdReads(at: gate)
        defer { gate.open() }
        await h.request()
        let applier = h.applier
        let flushing = Task { await applier.flushForQuit() }
        // The flush is working out what to write (it reads the table) when the caller's limit passes.
        #expect(await waitUntil { h.writer.readsHeld == 1 })
        #expect(await applier.abandonQuitFlush() == .stopped)
        gate.open()
        await flushing.value
        #expect(h.writer.writeCount == 0, "begun after the limit: not started")
    }

    @Test func aFlushWhoseWriteBeganBeforeTheLimitIsToldSo() async {
        let h = Harness()
        let gate = Gate()
        h.writer.holdWrites(at: gate)
        defer { gate.open() }
        await h.request()
        let applier = h.applier
        let flushing = Task { await applier.flushForQuit() }
        #expect(await waitUntil { h.writer.writeCount == 1 })
        #expect(await applier.abandonQuitFlush() == .writeBegun, "it can't be called back")
        gate.open()
        await flushing.value
        #expect(await applier.abandonQuitFlush() == .finished)
    }

    @Test func aFlushThatHasFinishedIsToldSo() async {
        let h = Harness()
        await h.request()
        await h.applier.flushForQuit()
        #expect(h.writer.writeCount == 1)
        #expect(await h.applier.abandonQuitFlush() == .finished)
    }

    // MARK: Apps matched by rank

    private func rankKey(_ id: ItemID, _ n: Int) -> String { LayoutKey.status(bundleID: id.bundleID, autosaveName: "Item-\(n)") }

    /// The bar with the notes app's two icons and Mantel's three, the app's `first` and `second` at x 450 and 400 (so `second` is the
    /// left one), then at 400 and 450 when `swapped`.
    private func rankBar(_ first: ItemID, _ second: ItemID, swapped: Bool = false) -> Inventory {
        let clock = F.systemItem("clock", x: 900)
        let (firstX, secondX): (CGFloat, CGFloat) = swapped ? (400, 450) : (450, 400)
        return F.slotted(F.ownDrawn().items + [F.appItem(first, x: firstX), F.appItem(second, x: secondX), clock])
    }

    /// macOS's table for it: Mantel's three, the system's clock and the app's two entries, `Item-1` at 250 (left) and `Item-0` at 150.
    private func rankTable(_ first: ItemID, _ second: ItemID) -> LayoutTableSnapshot {
        LayoutTableSnapshot(distances: [
            "module:Clock": 60, F.ownKey(OwnItems.alwaysDotName): 900, F.ownKey(OwnItems.hiddenDotName): 800, F.ownKey(OwnItems.dividerName): 700,
            rankKey(first, 0): 150, rankKey(first, 1): 250])
    }

    @Test func aWriteWithARankMatchedAppWritesItsKeysAndVerifiesMatches() async throws {
        let h = Harness(rules: F.rules(.byRank))
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        // `first` is the right icon and `Item-0` the smaller distance, `second` the left one: the person now wants `first` before `second`.
        h.writer.table = rankTable(first, second)
        h.reads.answer([rankBar(first, second, swapped: true)])
        let inputs = F.inputs(F.sections(shown: [first, second]), widths: [first: 30, second: 30])

        await h.request(inputs, inventory: rankBar(first, second))
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(report.verdict == "matches")
        #expect(report.unresolved.isEmpty)
        let write = try #require(h.writer.writes.first)
        // The left icon (`second`) takes the larger distance, 250, whose key is `Item-1`; the right one the other.
        #expect(write.keys[.item(second)] == rankKey(first, 1) && write.keys[.item(first)] == rankKey(first, 0))
        #expect(report.appsWritten.contains(first.bundleID))
    }

    @Test func aWrongMatchInsideAnAppEndsDiffersAndKeepsEveryIconOnItsSideOfTheDots() async throws {
        let h = Harness(rules: F.rules(.byRank))
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        h.writer.table = rankTable(first, second)
        // macOS puts the icons the other way round whatever is written: the match inside the app was wrong.
        h.reads.answer([rankBar(first, second)])
        let inputs = F.inputs(F.sections(shown: [first, second]), widths: [first: 30, second: 30])

        await h.request(inputs, inventory: rankBar(first, second))
        #expect(await h.settled())

        #expect(await h.applier.status().lastError == .notAccepted, "the write is reported as not accepted")
        #expect(h.writer.writeCount == 2)
        for index in h.writer.writes.indices {
            let table = try laid(h, write: index)
            let always = try #require(table[F.ownKey(OwnItems.alwaysDotName)]), hidden = try #require(table[F.ownKey(OwnItems.hiddenDotName)])
            let divider = try #require(table[F.ownKey(OwnItems.dividerName)]), clock = try #require(table["module:Clock"])
            #expect(always > hidden && hidden > divider, "the dots and the divider keep their order")
            for key in [rankKey(first, 0), rankKey(first, 1)] {
                let at = try #require(table[key])
                #expect(at < divider && at > clock, "both of the app's icons are right of the dots and the divider, and not among the system items")
            }
        }
    }

    @Test func anAppTheTableCantPlaceStaysOutOfTheWrite() async throws {
        // Three entries for two icons: no key is written for either, and the report says they can't be reordered.
        let h = Harness(rules: F.rules(.byRank))
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        h.writer.table = LayoutTableSnapshot(distances: rankTable(first, second).distances.merging([rankKey(first, 2): 350]) { $1 })
        h.reads.answer([rankBar(first, second)])

        await h.request(F.inputs(F.sections(shown: [first, second]), widths: [first: 30, second: 30]), inventory: rankBar(first, second))
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.unresolved) == [first, second])
        let write = try #require(h.writer.writes.first)
        #expect(write.keys[.item(first)] == nil && write.keys[.item(second)] == nil)
    }

    @Test func aConcealedAppIsNotMatchedByRankWhenItHasSeveralItems() async throws {
        let h = Harness(rules: F.rules(.byRank))
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        h.writer.table = rankTable(first, second)
        h.reads.answer([rankBar(first, second)])

        // The plan conceals the app: its frames are where it was last drawn, and the applier is told so.
        await h.request(F.inputs(F.sections(shown: [first, second]), widths: [first: 30, second: 30]), inventory: rankBar(first, second),
                        concealedApps: [first.bundleID])
        #expect(await h.settled())

        #expect(try #require(await h.applier.status().lastReport).unresolved.count == 2)
    }

    @Test func aKeyThatTheBarDidNotTakeEndsNotAcceptedAndIsNotGivenUpOnAtTheSecondTry() async throws {
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a", 0)
        let bar = F.slotted(F.ownDrawn().items + [F.appItem(a, x: 450), F.systemItem("clock", x: 900)])
        let table = rankTable(a, a).distances.filter { !$0.key.hasSuffix("Item-1") }
        h.writer.table = LayoutTableSnapshot(distances: table)
        // After the first write the table has the app's key left of • (800), as written; the bar goes on drawing the icon right of it:
        // the key wasn't the icon's. The second try must write it again and fail the check, not drop the app and find nothing wrong.
        var written = table
        written[rankKey(a, 0)] = 850
        h.writer.tablesAfterWrites([LayoutTableSnapshot(distances: written)])
        h.reads.answer([bar])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [a: 30]), inventory: bar)
        #expect(await h.settled())

        #expect(await h.applier.status().lastError == .notAccepted)
        #expect(h.writer.writeCount == 2)
        for write in h.writer.writes { #expect(write.keys[.item(a)] == rankKey(a, 0), "the app's key is in both writes") }
    }

    @Test func anAppAmongTheStayingModulesIsNotWrittenAndOneJustAboveThemIs() async throws {
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a"), c = F.nameless("c"), n = F.named("n")
        // The clock is at 200 and 30 wide: the apps begin at 230. a's entry (190) and n's (180) are right of the clock, among the modules
        // that stay; c's (240) is not.
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 200, itemKey(a): 190, F.key(n): 180, itemKey(c): 240])
        h.reads.answer([matching()])
        let inventory = F.inventory(F.ownDrawn().items + [F.appItem(a, x: 300), F.appItem(n, x: 330), F.appItem(c, x: 360),
                                                          F.systemItem("clock", x: 900)])

        await h.request(F.inputs(F.sections(shown: [c, a, n]), widths: [.system("clock"): 30]), inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.unresolved) == [a, n], "the two that sit among the modules that stay can't be reordered")
        let write = try #require(h.writer.writes.first)
        #expect(write.keys[.item(a)] == nil && write.keys[.item(n)] == nil, "and nothing is written for them")
        #expect(write.keys[.item(c)] == itemKey(c))
        #expect(try #require(write.arrangement.distances[.item(c)]) > 230, "c is written above the system items")
    }

    @Test func aNamedItemWithNoKeyDoesNotStopTheWriteOfTheTokensBesideItsApp() async throws {
        let h = Harness(rules: F.rules(.byRank))
        let foo = F.named("a", "foo"), x = F.nameless("a", 0)
        // foo has no entry and the app's one entry is `bar`: nothing of the app is written, and the app's place is that entry's.
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 60, "status:com.example.a::bar": 150])
        h.reads.answer([matching()])
        let inventory = F.inventory(F.ownDrawn().items + [F.appItem(foo, x: 300), F.appItem(x, x: 330), F.systemItem("clock", x: 900)])

        await h.request(F.inputs(F.sections(shown: [foo, x])), inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.unresolved) == [foo, x])
        #expect(h.writer.writes.first?.keys[.dot(.hidden)] != nil, "Mantel's own items are placed")
        #expect(report.notPlaced.isEmpty)
    }

    @Test func theLeftIconTakesTheLargerDistanceAndAWriteKeepsTheTablesOrder() async throws {
        // As the matcher names them, `.index(0)` is the left icon. The table has the left one furthest left (250); the arrangement keeps it so.
        let h = Harness(rules: F.rules(.byRank))
        let left = F.nameless("a", 0), right = F.nameless("a", 1)
        let clock = F.systemItem("clock", x: 900)
        let bar = F.slotted(F.ownDrawn().items + [F.appItem(left, x: 400), F.appItem(right, x: 450), clock])
        h.writer.table = rankTable(left, right)
        h.reads.answer([bar])

        await h.request(F.inputs(F.sections(shown: [left, right]), widths: [left: 30, right: 30]), inventory: bar)
        #expect(await h.settled())

        let write = try #require(h.writer.writes.first)
        #expect(write.keys[.item(left)] == rankKey(left, 1) && write.keys[.item(right)] == rankKey(left, 0))
        let leftAt = try #require(write.arrangement.distances[.item(left)]), rightAt = try #require(write.arrangement.distances[.item(right)])
        #expect(leftAt > rightAt, "what is written keeps the left icon further left")
        #expect(try #require(await h.applier.status().lastReport).verdict == "matches")
    }

    /// The table whose clock is at 200 and 30 wide (the apps begin at 230), and the app's one entry at `entry`. The request's read has no
    /// clock (it was taken when the module had no slot): its system item is one the table has no key for, so it has the items a write is
    /// planned from and none that gives a floor. The reads of the verification have the clock.
    private func aRequestReadWithoutTheClock(_ a: ItemID, entry: Double) -> (table: LayoutTableSnapshot, before: Inventory, with: Inventory) {
        let clock = F.systemItem("clock", x: 900)
        return (LayoutTableSnapshot(distances: ["module:Clock": 200, itemKey(a): entry]),
                F.inventory(F.ownDrawn().items + [F.appItem(a, x: 300)]),
                F.inventory(F.ownDrawn().items + [F.appItem(a, x: 150), clock]))
    }

    @Test(arguments: [nil, 600.0])
    func anAppTheFirstWriteMovedAmongTheStayingModulesIsWrittenBackAndTheWriteIsNotAccepted(tableAfterTheFirstWrite: Double?) async throws {
        // a's entry is at 190, right of the clock (200): among the modules that stay. The request's read has no clock, so the first try
        // writes it above the system items; the bar the verification reads has the clock. The second try would leave it out; the write is
        // not accepted, and the first write's move is undone. When the table macOS has after the first write puts the app at 600, left of
        // the clock's reach, the second try would plan from that and not see an app among the modules that stay: the app's place before the
        // write is what counts, and the write puts it back all the same.
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a")
        let world = aRequestReadWithoutTheClock(a, entry: 190)
        h.writer.table = world.table
        if let tableAfterTheFirstWrite {
            h.writer.tablesAfterWrites([LayoutTableSnapshot(distances: ["module:Clock": 200, itemKey(a): tableAfterTheFirstWrite])])
        }
        let differs = F.inventory(F.ownDrawn([.divider, .hiddenDot, .alwaysDot]).items + [F.appItem(a, x: 300), F.systemItem("clock", x: 900)])
        h.reads.answer([differs])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: world.before)
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2, "the first write, and the one that puts the app back")
        #expect(h.writer.writes.first?.keys[.item(a)] == itemKey(a), "with no clock read, nothing is among the modules that stay")
        let back = try #require(h.writer.writes.last)
        #expect(back.keys == [.item(a): itemKey(a)] && back.arrangement.distances[.item(a)] == 190, "only a, at the distance the table had")
        #expect(await h.applier.status().lastError == .notAccepted)
    }

    /// The bar shows the order the first write was meant to make: the check matches, and the app it moved from among the modules that stay
    /// would be accepted. It is written back all the same. The place that counts is the one written: an app that was at 500, left of the
    /// clock, is put near the system items by the first write (the request's read has no clock), at or below the clock's 200.
    @Test(arguments: [(entry: 190.0, firstAtMost: Double?.none, keyCount: Int?.some(1)), (entry: 500.0, firstAtMost: 200.0, keyCount: nil)])
    func anAppTheFirstWriteMovedAmongTheStayingModulesIsWrittenBackWhenTheFirstCheckMatches(
        entry: Double, firstAtMost: Double?, keyCount: Int?
    ) async throws {
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a")
        let world = aRequestReadWithoutTheClock(a, entry: entry)
        h.writer.table = world.table
        h.reads.answer([world.with])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: world.before)
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2)
        if let firstAtMost {
            let first = try #require(h.writer.writes.first?.arrangement.distances[.item(a)])
            #expect(first <= firstAtMost, "the first write put it among the modules that stay")
        }
        #expect(h.writer.writes.last?.arrangement.distances[.item(a)] == entry)
        if let keyCount { #expect(h.writer.writes.last?.keys.count == keyCount) }
        #expect(await h.applier.status().lastError == .notAccepted)
    }

    @Test func anAppTheWriterLeftAloneIsNotCountedAsMoved() async throws {
        // The first write puts only the first token of the arrangement (the dot left of a) in the table: a's key was planned, not written,
        // so the write didn't move a, and the second try, which leaves it out as among the modules that stay, is not a reason to give up.
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a")
        let world = aRequestReadWithoutTheClock(a, entry: 190)
        h.writer.table = world.table
        h.writer.answerWrites([1])
        let differs = F.inventory(F.ownDrawn([.divider, .hiddenDot, .alwaysDot]).items + [F.appItem(a, x: 300), F.systemItem("clock", x: 900)])
        h.reads.answer([differs])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: world.before)
        #expect(await h.settled())

        let first = try #require(h.writer.writes.first)
        #expect(first.keys[.item(a)] == itemKey(a), "a's key was planned in the first write")
        #expect(h.writer.writeCount == 2, "the second try is written: nothing of a's was moved to be put back")
        #expect(h.writer.writes.last?.keys[.item(a)] == nil)
    }

    @Test func anAppThatWasAmongTheModulesAndIsWrittenLeftOfThemIsWrittenBack() async throws {
        // Bluetooth (150) is a module that stays too, and the request's read doesn't draw it: the clock (100) is the left-most it knows, so
        // a's entry at 140 isn't among, and the first write puts it above Bluetooth. The bar after the write draws Bluetooth: a was among.
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a")
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 100, "module:Bluetooth": 150, itemKey(a): 140])
        let before = F.inventory(F.ownDrawn().items + [F.appItem(a, x: 300), F.systemItem("clock", x: 900)])
        let with = F.inventory(F.ownDrawn().items + [F.appItem(a, x: 150), F.systemItem("clock", x: 900), F.systemItem("bluetooth", x: 850)])
        h.reads.answer([with])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: before)
        #expect(await h.settled())

        let first = try #require(h.writer.writes.first?.arrangement.distances[.item(a)])
        #expect(first > 150, "the first write put it left of Bluetooth, so only where it was says it is among the modules that stay")
        #expect(h.writer.writes.last?.arrangement.distances[.item(a)] == 140)
        #expect(await h.applier.status().lastError == .notAccepted)
    }

    @Test func everyKeyTheFirstWriteWroteIsWrittenBackSoNothingEndsUpAcrossADot() async throws {
        // As above, a was at 500 and the first write puts it among the modules that stay. It wrote the dots and the divider too, from a
        // floor of 0: written back alone, a would be left of •• (in Always Hidden). Every key it wrote goes back to its old distance.
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a")
        let world = aRequestReadWithoutTheClock(a, entry: 500)
        let before: [String: Double] = ["module:Clock": 200, itemKey(a): 500, F.ownKey(OwnItems.alwaysDotName): 700,
                                        F.ownKey(OwnItems.hiddenDotName): 450, F.ownKey(OwnItems.dividerName): 400]
        h.writer.table = LayoutTableSnapshot(distances: before)
        h.reads.answer([world.with])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: world.before)
        #expect(await h.settled())

        let first = try #require(h.writer.writes.first)
        #expect(Set(first.keys.keys) == [.item(a), .dot(.always), .dot(.hidden), .divider])
        #expect(h.writer.writeCount == 2)
        let back = try #require(h.writer.writes.last)
        #expect(back.keys == first.keys, "every key the first write wrote")
        for (token, key) in back.keys { #expect(back.arrangement.distances[token] == before[key], "\(key) at its old distance") }
        #expect(await h.applier.status().lastError == .notAccepted)
    }

    @Test func nothingIsWrittenBackOnceMacOSHasRenumberedTheTable() async throws {
        // After the first write macOS re-sorts the bar and renumbers the table (the clock is now at 238): the old distances no longer mean
        // the places they were, so nothing is written back, and the write isn't accepted.
        let h = Harness(rules: F.rules(.byRank))
        let a = F.nameless("a")
        let world = aRequestReadWithoutTheClock(a, entry: 190)
        h.writer.table = world.table
        h.writer.tablesAfterWrites([LayoutTableSnapshot(distances: ["module:Clock": 238, itemKey(a): 200])])
        h.reads.answer([world.with])

        await h.request(F.inputs(F.sections(hidden: [a]), widths: [.system("clock"): 30]), inventory: world.before)
        #expect(await h.settled())

        #expect(h.writer.writeCount == 1, "only the first write")
        #expect(await h.applier.status().lastError == .notAccepted)
    }

    @Test func mantelsOwnSpacerAmongTheStayingModulesIsNotTakenForAnApp() async throws {
        // An own spacer's entry is at 150, right of the clock (200). The read draws the clock, so the write puts the spacer left of the
        // system items, as it does every own item: that is no app moved from among the modules that stay.
        let h = Harness()
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "0000abcd"))
        let spacerKey = F.ownKey("mantel.spacer.0000abcd")
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 200, spacerKey: 150])
        let clock = F.systemItem("clock", x: 900)
        h.reads.answer([F.inventory(matching().items + [clock])])
        var model = F.sections()
        model.addSpacer(spacer, in: .shown, at: 0)

        await h.request(F.inputs(model, widths: [.system("clock"): 30]), inventory: F.inventory(matching().items + [clock]))
        #expect(await h.settled())

        let first = try #require(h.writer.writes.first)
        let written = try #require(first.arrangement.distances[.item(OwnItems.itemID(spacer.id))])
        #expect(first.keys[.item(OwnItems.itemID(spacer.id))] == spacerKey && written > 200, "the spacer is written left of the clock")
        #expect(h.writer.writeCount == 1, "nothing is written back")
        #expect(await h.applier.status().lastError == nil)
    }

    // MARK: The modules that come and go

    /// Each module the table has an entry for that a Mac doesn't always draw, by its name in the inventory and in the table.
    private static let comingAndGoing: [(module: String, name: String)] = [
        ("display", "Display"), ("focusmodes", "FocusModes"), ("screenmirroring", "ScreenMirroring"), ("now-playing", "NowPlaying"),
        ("audiovideo", "AudioVideoModule"), ("airdrop", "AirDrop"),
    ]

    @Test(arguments: comingAndGoing)
    func withAModuleThatComesAndGoesDrawnTheAppsAreWrittenLeftOfItAndTheDotsArePlaced(module: String, name: String) async throws {
        let h = Harness()
        let b = F.named("b"), c = F.named("c")
        // The clock (60) stays; the module (200, 30 wide) comes and goes. The apps begin at 230, left of it. b and c sit right of it.
        h.writer.table = LayoutTableSnapshot(distances: ["module:Clock": 60, "module:\(name)": 200, F.key(b): 120, F.key(c): 140])
        h.reads.answer([matching()])
        let inventory = F.inventory(F.ownDrawn().items + [F.appItem(b, x: 300), F.appItem(c, x: 330), F.systemItem("clock", x: 900),
                                                          F.systemItem(module, x: 800)])

        await h.request(F.inputs(F.sections(shown: [c, b]), widths: [.system("clock"): 30, .system(module): 30]), inventory: inventory)
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(report.unresolved.isEmpty && report.notPlaced.isEmpty, "nothing is left out, and the dots are placed")
        let write = try #require(h.writer.writes.first)
        #expect(write.keys[.item(b)] == F.key(b) && write.keys[.item(c)] == F.key(c))
        #expect(write.keys[.dot(.hidden)] != nil && write.keys[.divider] != nil)
        for token in [LayoutToken.item(b), .item(c), .divider, .dot(.hidden), .dot(.always)] {
            #expect(try #require(write.arrangement.distances[token]) >= 230, "\(token) is written left of \(module)")
        }
    }

    @Test(arguments: [false, true])
    func anAppAmongTheStayingModulesInHiddenStopsNeitherTheDotsNorTheShownApps(withSeveralItems: Bool) async throws {
        let h = Harness(rules: F.rules(.byRank))
        let first = F.nameless("i", 0), second = F.nameless("i", 1), s = F.named("s")
        let app = withSeveralItems ? [first, second] : [first]
        // Between Clock (60) and Bluetooth (120) sit the app's entries (80 and 100, or one at 90), the person put it in Hidden, and (with
        // several items) the plan conceals it: it isn't matched (its frames are where it was last drawn), so it gets no key. s is left of
        // Bluetooth, and its places are right of anything a write places.
        var distances: [String: Double] = ["module:Clock": 60, "module:Bluetooth": 120, F.key(s): 150]
        distances[itemKey(first)] = withSeveralItems ? 80 : 90
        if withSeveralItems { distances[LayoutKey.status(bundleID: first.bundleID, autosaveName: "Item-1")] = 100 }
        h.writer.table = LayoutTableSnapshot(distances: distances)
        h.reads.answer([matching()])
        let items = F.ownDrawn().items + app.enumerated().map { F.appItem($1, x: 300 + Double($0) * 30) }
            + [F.appItem(s, x: 300 + Double(app.count) * 30), F.systemItem("clock", x: 900), F.systemItem("bluetooth", x: 850)]
        let inventory = withSeveralItems ? F.slotted(items) : F.inventory(items)

        await h.request(F.inputs(F.sections(hidden: app, shown: [s]), widths: [.system("clock"): 30, .system("bluetooth"): 30]),
                        inventory: inventory, concealedApps: withSeveralItems ? [first.bundleID] : [])
        #expect(await h.settled())

        let report = try #require(await h.applier.status().lastReport)
        #expect(Set(report.unresolved) == Set(app), "it can't be reordered")
        #expect(report.notPlaced.isEmpty, "and it doesn't stop the dots or the Shown app from being placed")
        let write = try #require(h.writer.writes.first)
        #expect(app.allSatisfy { write.keys[.item($0)] == nil }, "it stays where macOS has it")
        #expect(write.keys[.item(s)] == F.key(s) && write.keys[.dot(.hidden)] != nil && write.keys[.divider] != nil)
    }

    // MARK: Which concealed set a verification is judged by

    @Test func aVerificationIsJudgedByTheSetItsOwnReadWasScannedUnder() async throws {
        let x = F.named("x")
        let table = LayoutTableSnapshot(distances: ["module:Clock": 60, F.key(x): 150])
        // The bar draws x left of the dots, though the arrangement has it right of the divider.
        let bar = F.inventory(F.ownDrawn().items + [F.appItem(x, x: 20), F.systemItem("clock", x: 900)])

        // The request's read was taken while the plan concealed x, and the plan has stopped: the reads draw it, so they compare it.
        let moved = Harness()
        moved.writer.table = table
        moved.reads.answer([bar], concealed: [[]])
        await moved.request(F.inputs(F.sections(shown: [x]), widths: [x: 30]), inventory: bar, concealedApps: [x.bundleID])
        #expect(await moved.settled())
        #expect(await moved.applier.status().lastError == .notAccepted, "x is compared in both verifications")
        #expect(moved.writer.writeCount == 2)

        // A read that was scanned while x was concealed doesn't compare it, whatever the request's set is.
        let concealed = Harness()
        concealed.writer.table = table
        concealed.reads.answer([bar], concealed: [[x.bundleID]])
        await concealed.request(F.inputs(F.sections(shown: [x]), widths: [x: 30]), inventory: bar, concealedApps: [])
        #expect(await concealed.settled())
        #expect(await concealed.applier.status().lastError == nil)
    }

    @Test func theSecondTryIsResolvedWithTheSetOfTheLastRead() async throws {
        // The request's read was taken while the plan concealed the notes app (two items: no match is made from frames left behind). The
        // reads of the verification were taken once it was drawn, and they show it where its entries say: the second try matches it.
        let h = Harness(rules: F.rules(.byRank))
        let first = F.nameless("a", 0), second = F.nameless("a", 1)
        h.writer.table = rankTable(first, second)
        let before = rankBar(first, second)
        let bar = F.slotted(F.ownDrawn([.divider, .hiddenDot, .alwaysDot]).items + [F.appItem(first, x: 450), F.appItem(second, x: 400),
                                                                                    F.systemItem("clock", x: 900)])
        h.reads.answer([bar], concealed: [[]])

        await h.request(F.inputs(F.sections(shown: [first, second]), widths: [first: 30, second: 30]), inventory: before,
                        concealedApps: [first.bundleID])
        #expect(await h.settled())

        #expect(h.writer.writeCount == 2)
        #expect(h.writer.writes.first?.keys[.item(first)] == nil, "the first try, from the request's read, leaves the app out")
        #expect(h.writer.writes.last?.keys[.item(first)] == rankKey(first, 0), "the second matches it from the read that drew it")
    }
}
