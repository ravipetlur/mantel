import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The scanner on a busy Mac: apps and MenuBarAgent that answer late (or not at all), on slow fakes whose time is the test's clock.
@Suite("Menu bar scanner under load", .timeLimit(.minutes(1)))
struct MenuBarScannerLoadTests {
    private let weather = InventoryFixtures.weather
    private let notes = InventoryFixtures.notes

    private struct Rig {
        let fixture = InventoryFixtures.desk()
        let clock = FakeClock()
        let slow: SlowAX
        let scanner: MenuBarScanner

        init(patient: Bool, patience: AXPatience = .standard) {
            let fixture = fixture
            let clock = clock
            slow = SlowAX(fixture.ax, clock: clock)
            let ax: any AXReading = patient
                ? PatientAX(inner: slow, patience: patience, clock: clock, pidOf: { [tree = fixture.ax] in tree.ownerPID(of: $0) ?? 0 })
                : slow
            let layout = fixture.layout
            scanner = MenuBarScanner(ax: ax, extrasReader: AXAppExtrasReader(reader: AppExtrasReader(ax: ax)), runningApps: { fixture.running },
                                     layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: clock,
                                     patience: patience, readLimit: 8)
        }

        func pid(_ bundleID: String) -> pid_t { fixture.pid(of: bundleID)! }
    }

    @Test func anAppThatAnswersLateIsReadOnABusyMac() async {
        // The weather app's first answer takes 0.6 s: more than the quarter of a second every query used to wait.
        let plain = Rig(patient: false)
        plain.slow.setDelay(0.6, for: plain.pid(weather), forCalls: 1)
        let lost = await plain.scanner.scan()
        #expect(lost.unansweredApps.contains(weather), "as it was: the app is taken for one that didn't answer")
        #expect(!lost.items.contains { $0.ownerBundleID == weather })

        let busy = Rig(patient: true)
        busy.slow.setDelay(0.6, for: busy.pid(weather), forCalls: 1)
        let read = await busy.scanner.scan()
        #expect(!read.unansweredApps.contains(weather))
        #expect(read.items.contains { $0.ownerBundleID == weather }, "its items are in the read")
        #expect(busy.slow.calls(to: busy.pid(weather)).prefix(2).map(\.wait) == [0.25, 1], "asked again with a longer wait")
    }

    @Test func anAppThatNeverAnswersCostsTheNextReadOneShortWait() async {
        let rig = Rig(patient: true)
        let hung = rig.pid(notes)
        rig.slow.hang(hung)

        _ = await rig.scanner.scan()
        #expect(rig.slow.calls(to: hung).map(\.wait) == [0.25, 1], "the first read asks it twice")
        // Silent only after its first minute (`AXPatience.youngFor`): asked twice again, and then known never to answer.
        rig.clock.advance(by: .seconds(61))
        _ = await rig.scanner.scan()

        let before = rig.slow.calls.count
        _ = await rig.scanner.scan()
        #expect(rig.slow.calls.dropFirst(before).filter { $0.pid == hung }.map(\.wait) == [0.25],
                "the next costs a quarter of a second, not its timeouts again")
    }

    @Test func aReadWithNoBarIsTakenAgainBeforeAnythingActsOnIt() async throws {
        let rig = Rig(patient: true)
        let agent = rig.pid(MenuBarReader.menuBarAgentBundleID)
        rig.slow.hang(agent)
        let scanner = rig.scanner
        let scanning = Task { await scanner.scan() }

        // The first read found no window; MenuBarAgent is asked again after a short wait.
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)))
        rig.slow.release(agent)
        rig.clock.advance(by: .milliseconds(250))
        let read = await scanning.value

        #expect(!read.bars.isEmpty, "the second try had the bar")
        #expect(read.problems.isEmpty)
        #expect(read.agentAnswered)
        #expect(await scanner.agentFailureStreak == 0, "an empty read that was made good isn't a failure")
    }

    @Test func aBarThatNeverComesIsTheProblemItWas() async throws {
        let rig = Rig(patient: true)
        rig.slow.hang(rig.pid(MenuBarReader.menuBarAgentBundleID))
        let scanner = rig.scanner
        let scanning = Task { await scanner.scan() }

        for wait in EmptyReadRetry.waits {
            #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)))
            rig.clock.advance(by: wait)
        }
        let read = await scanning.value

        #expect(read.problems == [.agentHasNoWindows])
        #expect(await scanner.agentFailureStreak == 1, "one failure, however many times it was asked")
    }

    @Test func accessibilityThatIsNotGrantedIsNotAskedAgain() async {
        let rig = Rig(patient: true)
        let layout = rig.fixture.layout
        let fixture = rig.fixture
        let scanner = MenuBarScanner(ax: rig.slow, runningApps: { fixture.running }, layout: { layout },
                                     ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { false }, clock: rig.clock, readLimit: 8)
        let read = await scanner.scan()
        #expect(read.problems == [.accessibilityNotGranted])
        #expect(rig.clock.sleeperCount == 0)
    }

    @Test func quittingEndsTheWaitingOfReadsThatAreUnderWay() async {
        let rig = Rig(patient: true)
        rig.scanner.stopWaiting()
        #expect(rig.slow.stopWaitingCalls == 1)
    }

    // MARK: MenuBarAgent that is late

    @Test func menuBarAgentThatIsLateAtLaunchIsWaitedForAndTheFirstReadHasTheBar() async throws {
        let rig = Rig(patient: true)
        let agent = rig.pid(MenuBarReader.menuBarAgentBundleID)
        // Its first answers take 1.3 s: more than the first two waits, which is all an app nothing is known of is given.
        rig.slow.setDelay(1.3, for: agent, forCalls: 2)

        // A scan that is asleep for a retry on a clock nothing moves is not waited for beyond the limit: the test fails, and doesn't hang.
        let scanner = rig.scanner
        let result = Mutex<Inventory?>(nil)
        let scanning = Task { let taken = await scanner.scan(); result.withLock { $0 = taken } }
        defer { scanning.cancel() }
        #expect(await waitUntil { result.withLock { $0 } != nil }, "the scan came back: it wasn't asleep waiting to ask again")
        let read = try #require(result.withLock { $0 })

        #expect(!read.bars.isEmpty, "the third wait had the answer, and nothing was read again")
        #expect(read.problems.isEmpty)
        #expect(rig.clock.sleeperCount == 0, "no retry was needed")
        #expect(await rig.scanner.agentFailureStreak == 0)
    }

    @Test func theRetriesOfAnEmptyReadHaveTheirOwnTimeToAskAndTheLadder() async throws {
        // The first try spends everything MenuBarAgent is given in a read (3.25 s of waits and no more to spend); then the first two waits of
        // the retry are missed too, and the third has the answer. A retry that is made from what the first left has nothing to ask with, and
        // one that is given the first wait only (MenuBarAgent taken for hung, as an app is after a ladder was missed) is empty again, and
        // needs another try.
        let patience = AXPatience(waits: [0.25, 1, 2], unknownAppWaits: 2, silentAppWaits: 1, perAppBudget: 3.25, learnedFor: 30)
        let rig = Rig(patient: true, patience: patience)
        let agent = rig.pid(MenuBarReader.menuBarAgentBundleID)
        rig.slow.miss(AXName.windows, of: agent, calls: 5)
        let scanner = rig.scanner
        let result = Mutex<Inventory?>(nil)
        let scanning = Task { let read = await scanner.scan(); result.withLock { $0 = read } }
        defer { scanning.cancel() }

        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)))
        rig.clock.advance(by: EmptyReadRetry.waits[0])

        // A scan that wasn't given the retry's ladder is asleep for its second try, and this ends the wait.
        #expect(await waitUntil { result.withLock { $0 } != nil }, "the first retry had the bar: nothing was asked again")
        let read = try #require(result.withLock { $0 })
        #expect(!read.bars.isEmpty, "the first retry was a read of its own, with its own ladder")
        #expect(await scanner.agentFailureStreak == 0)
    }

    @Test func theAgentsReadsTakeTheirTurnsAtTheGateLikeTheApps() async throws {
        let rig = Rig(patient: true)
        let agent = rig.pid(MenuBarReader.menuBarAgentBundleID)
        let scanner = rig.scanner
        rig.slow.hang(agent)
        // No scan has run, so no app is read: what holds a turn at the gate while MenuBarAgent is asked is MenuBarAgent's read.
        let held = Mutex<[Int]>([])
        rig.slow.onTimeout { held.withLock { $0.append(scanner.readGateCounts.running) } }

        _ = await scanner.lookAtBar()
        let byTheLook = held.withLock { $0 }
        held.withLock { $0 = [] }
        _ = await scanner.slotSnapshot(on: nil)
        let byTheSnapshot = held.withLock { $0 }

        #expect(!byTheLook.isEmpty && byTheLook.allSatisfy { $0 == 1 }, "the look holds a turn while it waits: \(byTheLook)")
        #expect(!byTheSnapshot.isEmpty && byTheSnapshot.allSatisfy { $0 == 1 }, "so does the bar's read for a click: \(byTheSnapshot)")
        #expect(scanner.readGateCounts == (0, 0), "and the turn is given back")
    }

    @Test func theFrontAppsMenusAreReadInAScopeAndThroughTheGate() async throws {
        let rig = Rig(patient: true)
        let scanner = rig.scanner
        _ = await scanner.scan()
        let front = rig.pid(notes)
        rig.slow.hang(front)
        let held = Mutex<[Int]>([])
        rig.slow.onTimeout { held.withLock { $0.append(scanner.readGateCounts.running) } }
        let began = rig.clock.now()

        _ = await scanner.appMenuFrames(pid: front)

        let took = rig.clock.now().timeIntervalSince(began)
        #expect(took <= AXPatience.lookBudget + 0.001, "a front app that doesn't answer holds the session's events for a look's time, not its whole ladder (\(took))")
        #expect(!held.withLock { $0 }.isEmpty && held.withLock { $0 }.allSatisfy { $0 == 1 }, "and takes its turn at the gate")
    }

    /// Extras that answer nothing, and of which the lowest process takes nine seconds of the clock (a scan's time is eight).
    private final class SlowestFirst: AppExtrasReading {
        private let clock: FakeClock
        private let slowest: pid_t
        private let state = Mutex((eating: true, asked: [pid_t]()))

        init(clock: FakeClock, slowest: pid_t) {
            self.clock = clock
            self.slowest = slowest
        }

        var asked: [pid_t] { state.withLock { $0.asked } }

        func stopEating() { state.withLock { $0.eating = false; $0.asked = [] } }

        func read(_ app: RunningApp) async -> ExtrasOutcome {
            let eat = state.withLock { state -> Bool in
                state.asked.append(app.pid)
                return state.eating && app.pid == slowest
            }
            if eat { clock.advance(by: .seconds(9)) }
            return .timedOut
        }
    }

    @Test func anAppTheScansTimeLeftUnaskedIsNotCountedAsTimingOut() async {
        let fixture = InventoryFixtures.desk()
        let clock = FakeClock()
        let apps = fixture.running.filter { $0.bundleID != MenuBarReader.menuBarAgentBundleID && !HelperBundles.isHelper($0.bundleID ?? "") }
            .sorted { $0.pid < $1.pid }
        let slowest = apps[0].pid, unlucky = apps[1]
        let extras = SlowestFirst(clock: clock, slowest: slowest)
        let layout = fixture.layout
        let scanner = MenuBarScanner(ax: SlowAX(fixture.ax, clock: clock), extrasReader: extras, runningApps: { fixture.running },
                                     layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: clock, readLimit: 1)

        // The slowest app takes the whole scan's time, one at a time: the apps behind it are asked nothing, three scans in a row.
        var last = await scanner.scan()
        for _ in 0..<2 { last = await scanner.scan() }
        #expect(last.reach.first { $0.bundleID == unlucky.bundleID }?.status == .skipped, "left alone this time, and not timed out")

        // The next scan has time for everyone. An app that was asked nothing three times hasn't been skipped for half a minute for it.
        extras.stopEating()
        _ = await scanner.scan()
        #expect(extras.asked.contains(unlucky.pid), "it is asked again")
    }

    @Test func aReadThatIsCutIsSaidToBe() async {
        let rig = Rig(patient: true)
        // A slot of MenuBarAgent whose reads time out: the read has no frame or name for it.
        let tree = rig.fixture.ax
        for window in rig.fixture.windows.flatMap({ $0 }) {
            for slot in (try? tree.children(of: tree.ref(window))) ?? [] { tree.failReads(on: tree.id(of: slot), with: .timeout) }
        }

        let read = await rig.scanner.scan()

        #expect(!read.bars.isEmpty)
        #expect(read.agentReadCut, "the bars are what was seen, and may be short of what is there")
    }

    @Test func aReadThatWasntCutIsntSaidToBe() async {
        let read = await Rig(patient: true).scanner.scan()
        #expect(!read.agentReadCut)
    }

    // MARK: One app that hangs, on a Mac that isn't busy

    @Test func oneAppThatHangsCostsAClickOnAnotherAppsIconAQuarterOfASecondAndNotItsLadder() async throws {
        let rig = Rig(patient: true)
        let hung = rig.pid(notes)
        let item = ItemID(bundleID: weather, key: .identifier("weather.temp"))
        // Every app answers once, as on a Mac that isn't busy; then the notes app, which has an icon on the bar, hangs.
        _ = await rig.scanner.scan()
        rig.slow.hang(hung)
        let before = rig.slow.calls.count
        let began = rig.clock.now()

        _ = await rig.scanner.locate(item, on: nil, since: nil)

        let asked = rig.slow.calls.dropFirst(before).filter { $0.pid == hung }.map(\.wait)
        #expect(!asked.isEmpty, "it is asked, as a bystander whose frames claim slots")
        #expect(Set(asked) == [0.25], "with the first wait only, not 0.25, 1 and 2")
        #expect(rig.clock.now().timeIntervalSince(began) < 1, "so the click isn't held up by it")
    }

    @Test func theSnapshotOfTheBarAsksTheAppsThatNameTheOwnersOfSlotsWithTheFirstWaitOnly() async throws {
        let rig = Rig(patient: true)
        _ = await rig.scanner.scan()
        rig.slow.hang(rig.pid(notes))
        let before = rig.slow.calls.count

        _ = await rig.scanner.slotSnapshot(on: nil)

        #expect(Set(rig.slow.calls.dropFirst(before).filter { $0.pid == rig.pid(notes) }.map(\.wait)) == [0.25])
    }

    @Test func anAppThatHangsCostsEachScanItsFirstWaitOnlyAfterTheFirst() async {
        let rig = Rig(patient: true)
        let hung = rig.pid(notes)
        _ = await rig.scanner.scan()
        rig.slow.hang(hung)
        let before = rig.slow.calls.count
        _ = await rig.scanner.scan()
        #expect(rig.slow.calls.dropFirst(before).filter { $0.pid == hung }.map(\.wait).prefix(3) == [0.25, 1, 2], "the first read that finds it hung")

        let again = rig.slow.calls.count
        _ = await rig.scanner.scan()
        #expect(rig.slow.calls.dropFirst(again).filter { $0.pid == hung }.map(\.wait).prefix(3).allSatisfy { $0 == 0.25 })
    }

    // MARK: A read's own time

    @Test func aReadAskedForWithinAScopeHasNoMoreThanWhatIsLeftOfIt() async {
        let rig = Rig(patient: true)
        let hung = rig.pid(notes)
        _ = await rig.scanner.scan()
        rig.slow.hang(hung)
        let outer = AXReadScope(budget: 0.3, perAppBudget: 4, clock: rig.clock)
        let began = rig.clock.now()

        let frames = await AXReadScope.run(outer) { await rig.scanner.itemFrames(ofApps: [notes]) }

        #expect(frames[notes] == nil)
        #expect(rig.clock.now().timeIntervalSince(began) <= 0.6, "the check's own four seconds were cut to what the round had")
    }

    @Test func theRetryWaitsGrowAndAreBounded() {
        #expect(EmptyReadRetry.wait(afterAttempt: 0) == .milliseconds(250))
        #expect(EmptyReadRetry.wait(afterAttempt: 2) == .seconds(1))
        #expect(EmptyReadRetry.wait(afterAttempt: 3) == nil)
    }
}
