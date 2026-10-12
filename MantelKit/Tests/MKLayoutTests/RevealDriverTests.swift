import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKLayout

/// What the driver passed on to its caller, in order.
private final class Passed: Sendable {
    private let effects = Mutex<[RevealEffect]>([])

    func record(_ effect: RevealEffect) {
        effects.withLock { $0.append(effect) }
    }

    var all: [RevealEffect] { effects.withLock { $0 } }
}

private func settings(hover: Bool = false, hoverDelay: Int = 300, rehide: RehideDelay = .seconds(10)) -> RevealSettings {
    RevealSettings(hoverReveals: hover, clickReveals: false, scrollReveals: false, hoverDelayMilliseconds: hoverDelay, rehide: rehide)
}

/// A driver on a clock a test moves, and what it passes on.
private struct Rig {
    let clock: FakeClock
    let passed: Passed
    let driver: RevealDriver

    init(_ settings: RevealSettings, machine: RevealMachine? = nil) {
        let passed = Passed()
        let clock = FakeClock()
        self.passed = passed
        self.clock = clock
        driver = RevealDriver(machine: machine ?? RevealMachine(settings: settings), clock: clock, effects: { passed.record($0) })
    }

    /// Returns once `count` timers sleep on the clock; a failure, and not a hang, if they don't within five seconds.
    func sleepers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await clock.waitForSleepers(count, within: .seconds(5)), "\(count) timer(s) sleeping on the clock", sourceLocation: sourceLocation)
    }

    /// Returns once no timer sleeps on the clock.
    func noSleepers(sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = clock
        #expect(await waitUntil { clock.sleeperCount == 0 }, "no timer sleeping on the clock", sourceLocation: sourceLocation)
    }

    /// Returns once the driver has passed on `count` effects.
    func passes(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let passed = passed
        #expect(await waitUntil { passed.all.count >= count }, "\(count) effects passed on", sourceLocation: sourceLocation)
    }

    /// Returns once every effect queued so far has been delivered; a failure, and not a hang, if that doesn't happen within five seconds.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await settled(driver), "the queued effects delivered", sourceLocation: sourceLocation)
    }
}

/// Whether the driver has delivered what it had queued within five seconds. The wait ends when its task is cancelled, which is what the
/// time limit does to it.
private func settled(_ driver: RevealDriver) async -> Bool {
    await withinTimeLimit(.seconds(5)) {
        await driver.settled()
        return true
    } ?? false
}

/// Whether at least `count` calls to `settled()` are waiting within five seconds.
private func settleWaiters(_ driver: RevealDriver, atLeast count: Int) async -> Bool {
    await withinTimeLimit(.seconds(5)) {
        while await driver.settleWaiting < count {
            guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
        }
        return true
    } ?? false
}

/// Where an effect ran, as far as a test can tell.
private struct Where: Sendable, Equatable {
    /// The task-local value the sender had set, if the effect saw it.
    var marker: String?
    /// Whether the task the effect ran on was cancelled.
    var cancelled: Bool
}

private enum SenderMarker {
    @TaskLocal static var current: String?
}

/// A clock whose sleep ends when the task that sleeps is cancelled, and says nothing of it: the end of a sleep that ran out just as
/// the task was cancelled.
private final class WakesQuietlyClock: Clock {
    private struct Counts {
        var sleeping = 0
        var cancelled = 0
    }

    private let gate = Gate()
    private let counts = Mutex(Counts())

    /// How many sleeps are going on.
    var sleeping: Int { counts.withLock { $0.sleeping } }
    /// How many sleeps have ended because their task was cancelled.
    var cancelled: Int { counts.withLock { $0.cancelled } }

    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

    func sleep(for duration: Duration) async throws {
        counts.withLock { $0.sleeping += 1 }
        await gate.wait()
        counts.withLock {
            $0.sleeping -= 1
            if Task.isCancelled { $0.cancelled += 1 }
        }
    }

    /// Lets every sleep end, so that none is left waiting.
    func release() { gate.open() }
}

@Suite("Reveal driver", .timeLimit(.minutes(1)))
struct RevealDriverTests {
    @Test func hoverRevealsAfterDelay() async {
        let rig = Rig(settings(hover: true))
        await rig.driver.send(.pointerEnteredEmptySpace)
        await rig.sleepers(1)

        // One millisecond short of the delay, nothing has happened.
        rig.clock.advance(by: .milliseconds(299))
        #expect(rig.clock.sleeperCount == 1)
        #expect(await rig.driver.state == .collapsed)
        #expect(rig.passed.all.isEmpty)

        rig.clock.advance(by: .milliseconds(1))
        await rig.passes(2)
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom])
        #expect(await rig.driver.state == .hiddenShown)
        // The reveal has its own countdown, waiting on the clock.
        await rig.sleepers(1)
    }

    @Test func hoverDelayIsTheSettingsOwn() async {
        let rig = Rig(settings(hover: true, hoverDelay: 800))
        await rig.driver.send(.pointerEnteredEmptySpace)
        await rig.sleepers(1)
        rig.clock.advance(by: .milliseconds(799))
        #expect(await rig.driver.state == .collapsed)
        rig.clock.advance(by: .milliseconds(1))
        await rig.passes(2)
        #expect(await rig.driver.state == .hiddenShown)
    }

    @Test func pointerLeavingBeforeTheDelayNeverReveals() async {
        let rig = Rig(settings(hover: true))
        await rig.driver.send(.pointerEnteredEmptySpace)
        await rig.sleepers(1)
        rig.clock.advance(by: .milliseconds(200))
        await rig.driver.send(.pointerLeftEmptySpace)
        await rig.noSleepers()

        rig.clock.advance(by: .seconds(5))
        #expect(await rig.driver.state == .collapsed)
        #expect(rig.passed.all.isEmpty)

        // The next time the pointer rests, the delay counts from the start again.
        await rig.driver.send(.pointerEnteredEmptySpace)
        await rig.sleepers(1)
        rig.clock.advance(by: .milliseconds(299))
        #expect(await rig.driver.state == .collapsed)
        rig.clock.advance(by: .milliseconds(1))
        await rig.passes(2)
        #expect(await rig.driver.state == .hiddenShown)
    }

    @Test func rehideAfterTenSeconds() async {
        let rig = Rig(settings())
        await rig.driver.send(.show(.hidden))
        await rig.settle()
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom])
        await rig.sleepers(1)

        rig.clock.advance(by: .milliseconds(9_999))
        #expect(await rig.driver.state == .hiddenShown)
        #expect(rig.clock.sleeperCount == 1)

        rig.clock.advance(by: .milliseconds(1))
        await rig.passes(3)
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom, .stateChanged(.collapsed)])
        #expect(await rig.driver.state == .collapsed)
        await rig.noSleepers()
    }

    @Test func rehideDelayIsTheSettingsOwn() async {
        let rig = Rig(settings(rehide: .seconds(30)))
        await rig.driver.send(.dotClicked(.always))
        await rig.sleepers(1)
        rig.clock.advance(by: .seconds(29))
        #expect(await rig.driver.state == .allShown)
        rig.clock.advance(by: .seconds(1))
        await rig.passes(3)
        #expect(await rig.driver.state == .collapsed)
    }

    @Test func neverRehidesWhenNever() async {
        let rig = Rig(settings(rehide: .never))
        await rig.driver.send(.show(.all))
        // No countdown was started, and none was cancelled: the timer has never been on a generation. (A sleeper count of 0 would also be
        // the case for a countdown whose task hasn't begun to sleep yet.)
        #expect(await rig.driver.currentGeneration(of: .rehide) == 0)
        rig.clock.advance(by: .seconds(3600))
        #expect(await rig.driver.state == .allShown)
        await rig.settle()
        #expect(rig.passed.all == [.stateChanged(.allShown), .checkRoom])
    }

    @Test func pointerInBarHoldsRehide() async {
        let rig = Rig(settings())
        await rig.driver.send(.show(.hidden))
        await rig.sleepers(1)

        await rig.driver.send(.guardsChanged(RehideGuards(pointerInBar: true)))
        await rig.noSleepers()
        // However long the pointer stays, the icons stay.
        rig.clock.advance(by: .seconds(600))
        #expect(await rig.driver.state == .hiddenShown)

        await rig.driver.send(.guardsChanged(RehideGuards()))
        await rig.sleepers(1)
        rig.clock.advance(by: .milliseconds(9_999))
        #expect(await rig.driver.state == .hiddenShown)
        rig.clock.advance(by: .milliseconds(1))
        await rig.passes(3)
        #expect(await rig.driver.state == .collapsed)
    }

    @Test func theRehideCountdownDoesNotWaitForConfirmation() async {
        // The machine the app runs: the bar's own frames often miss a change that did happen, so nothing waits for a reveal to be
        // confirmed. The pointer is on the bar when a dot is clicked, and the countdown starts when it leaves, with no confirmation said.
        let rig = Rig(settings(), machine: .live(settings: settings()))
        await rig.driver.send(.guardsChanged(RehideGuards(pointerInBar: true)))
        await rig.driver.send(.dotClicked(.hidden))
        await rig.noSleepers()
        rig.clock.advance(by: .seconds(600))
        #expect(await rig.driver.state == .hiddenShown, "the pointer is in the bar")

        await rig.driver.send(.guardsChanged(RehideGuards()))
        await rig.sleepers(1)
        rig.clock.advance(by: .milliseconds(9_999))
        #expect(await rig.driver.state == .hiddenShown)
        rig.clock.advance(by: .milliseconds(1))
        await rig.passes(3)
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom, .stateChanged(.collapsed)])
        #expect(await rig.driver.state == .collapsed, "it hid the icons again though no `revealConfirmed` was ever sent")
    }

    @Test func menuOpenHoldsRehide() async {
        let rig = Rig(settings())
        await rig.driver.send(.show(.hidden))
        await rig.sleepers(1)
        rig.clock.advance(by: .seconds(6))

        // A menu opens with four seconds left: the countdown stops.
        await rig.driver.send(.guardsChanged(RehideGuards(menuOpen: true)))
        await rig.noSleepers()
        rig.clock.advance(by: .seconds(60))
        #expect(await rig.driver.state == .hiddenShown)

        // The menu closes: the full ten seconds again, not the four that were left.
        await rig.driver.send(.guardsChanged(RehideGuards()))
        await rig.sleepers(1)
        rig.clock.advance(by: .seconds(9))
        #expect(await rig.driver.state == .hiddenShown)
        rig.clock.advance(by: .seconds(1))
        await rig.passes(3)
        #expect(await rig.driver.state == .collapsed)
    }

    @Test func cancelledTimerFiringIsIgnored() async {
        let rig = Rig(settings())
        await rig.driver.send(.show(.hidden))
        await rig.sleepers(1)
        await rig.settle()
        let live = await rig.driver.currentGeneration(of: .rehide)

        // The countdown is cancelled, which puts the timer on a new generation.
        await rig.driver.send(.guardsChanged(RehideGuards(menuOpen: true)))
        #expect(await rig.driver.currentGeneration(of: .rehide) > live)
        await rig.noSleepers()

        // The task of the cancelled countdown, having woken just as it was cancelled, reports its time up. It is ignored: the machine is
        // never told, so the guard that was holding isn't undone and nothing is passed on.
        await rig.driver.fired(.rehide, generation: live)
        #expect(await rig.driver.state == .hiddenShown)
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom])
        #expect(await rig.driver.ignoredTimerWakeups == 1)
    }

    @Test func aTimerThatWakesAfterItsCancelIsIgnored() async {
        // The same through the real path: a task that sleeps on a clock that doesn't throw when cancelled gets to report its fire.
        let clock = WakesQuietlyClock()
        defer { clock.release() }
        let passed = Passed()
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: clock, effects: { passed.record($0) })
        await driver.send(.show(.hidden))
        #expect(await waitUntil { clock.sleeping == 1 }, "the countdown sleeping")

        await driver.send(.guardsChanged(RehideGuards(panelOpen: true)))
        let reported = await withinTimeLimit(.seconds(5)) {
            while await driver.ignoredTimerWakeups < 1 {
                guard (try? await Task.sleep(for: .milliseconds(1))) != nil else { return false }
            }
            return true
        }
        #expect(reported == true, "the cancelled countdown's wake-up reaching the driver")
        #expect(await driver.state == .hiddenShown)
        #expect(await settled(driver), "the queued effects delivered")
        #expect(passed.all == [.stateChanged(.hiddenShown), .checkRoom])
    }

    @Test func newerStartAndCancelEndTheOldTask() async {
        let clock = WakesQuietlyClock()
        defer { clock.release() }
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: clock, effects: { _ in })
        await driver.send(.show(.hidden))
        #expect(await waitUntil { clock.sleeping == 1 }, "the countdown sleeping")

        // Starting the countdown again ends the task of the first one, and there is one task sleeping again.
        await driver.send(.show(.hidden))
        #expect(await waitUntil { clock.cancelled == 1 && clock.sleeping == 1 }, "the first countdown's task cancelled")

        // Cancelling it ends the second.
        await driver.send(.guardsChanged(RehideGuards(menuOpen: true)))
        #expect(await waitUntil { clock.cancelled == 2 && clock.sleeping == 0 }, "the second countdown's task cancelled")
    }

    @Test func collapseCancelsTimers() async {
        let rig = Rig(settings(hover: true))
        await rig.driver.send(.pointerEnteredEmptySpace)
        await rig.sleepers(1)
        #expect(await rig.driver.currentGeneration(of: .hover) == 1, "the hover started")

        // A click on the dot while the hover runs: the click decides, and the hover is over: its timer is on a new generation, and of the
        // two tasks that slept, only the reveal's countdown is left.
        await rig.driver.send(.dotClicked(.hidden))
        #expect(await rig.driver.currentGeneration(of: .hover) == 2, "the hover was cancelled")
        let clock = rig.clock
        #expect(await waitUntil { clock.sleeperCount == 1 }, "only the countdown sleeping")
        rig.clock.advance(by: .milliseconds(300))
        #expect(await rig.driver.state == .hiddenShown)
        await rig.settle()
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom])

        // Collapsing ends the countdown, and with it every timer.
        await rig.driver.send(.dotClicked(.hidden))
        await rig.noSleepers()
        rig.clock.advance(by: .seconds(60))
        #expect(await rig.driver.state == .collapsed)
        await rig.settle()
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom, .stateChanged(.collapsed)])
    }

    @Test func newerStartReplacesOlderTimer() async {
        let rig = Rig(settings())
        await rig.driver.send(.show(.hidden))
        await rig.sleepers(1)
        rig.clock.advance(by: .seconds(6))

        // The reveal is asked for again: the countdown starts over, and the old one is gone.
        await rig.driver.send(.show(.hidden))
        await rig.sleepers(1)
        rig.clock.advance(by: .seconds(4))
        #expect(await rig.driver.state == .hiddenShown, "ten seconds after the first start, which no longer counts")
        #expect(rig.clock.sleeperCount == 1)

        rig.clock.advance(by: .seconds(6))
        await rig.passes(3)
        #expect(rig.passed.all == [.stateChanged(.hiddenShown), .checkRoom, .stateChanged(.collapsed)])
        await rig.noSleepers()
    }

    @Test func effectsReachTheCallerInOrder() async {
        let rig = Rig(settings())
        await rig.driver.send(.dotClicked(.always))
        await rig.driver.send(.dotClicked(.hidden))
        await rig.driver.send(.toggleFocusMode)
        await rig.driver.send(.dotClicked(.always))
        await rig.settle()
        // Only what the caller has to act on reaches it: the timers are the driver's own.
        #expect(rig.passed.all == [.stateChanged(.allShown), .checkRoom, .stateChanged(.collapsed),
                                   .stateChanged(.focusMode), .stateChanged(.collapsed)])
    }

    @Test func effectsStayInOrderWhileTheCallerIsBusy() async {
        let gate = Gate()
        let passed = Passed()
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: FakeClock(), effects: { effect in
            passed.record(effect)
            // The caller takes its time over the first thing it is told.
            if passed.all.count == 1 { await gate.wait() }
        })
        // Sent on tasks of the test's own, which say when `send` has returned: one that waits for the caller would never say.
        let firstReturned = Mutex(false)
        Task {
            await driver.send(.dotClicked(.hidden))
            firstReturned.withLock { $0 = true }
        }
        #expect(await waitUntil { firstReturned.withLock { $0 } }, "send returning while the caller is yet to be told anything")
        #expect(await waitUntil { passed.all.count == 1 }, "the first effect reaching the caller")

        // Another event is handled at once, though the caller isn't done; what it says to do comes after what was said before.
        let secondReturned = Mutex(false)
        Task {
            await driver.send(.dotClicked(.hidden))
            secondReturned.withLock { $0 = true }
        }
        #expect(await waitUntil { secondReturned.withLock { $0 } }, "send returning while the caller is busy")
        #expect(await driver.state == .collapsed)
        #expect(passed.all == [.stateChanged(.hiddenShown)])

        gate.open()
        #expect(await settled(driver), "the queued effects delivered")
        #expect(passed.all == [.stateChanged(.hiddenShown), .checkRoom, .stateChanged(.collapsed)])
    }

    @Test func theCallerCanSendFromItsOwnEffects() async {
        // A caller that answers an effect with an event, as the session does when it sees the room it was asked to look at.
        let box = Mutex<RevealDriver?>(nil)
        defer { box.withLock { $0 = nil } }
        let passed = Passed()
        let clock = FakeClock()
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: clock, effects: { effect in
            passed.record(effect)
            if effect == .checkRoom { await box.withLock { $0 }?.send(.guardsChanged(RehideGuards(pointerInBar: true))) }
        })
        box.withLock { $0 = driver }

        let sent = Mutex(false)
        Task {
            await driver.send(.show(.hidden))
            sent.withLock { $0 = true }
        }
        #expect(await waitUntil { sent.withLock { $0 } }, "send returning while the caller sends from its effect")
        #expect(await settled(driver), "the queued effects delivered, the one that sends among them")
        #expect(await driver.state == .hiddenShown)
        #expect(passed.all == [.stateChanged(.hiddenShown), .checkRoom])
        // The guard it sent is in force: the countdown that began with the reveal (generation 1) was cancelled by it (generation 2), and
        // however long goes by the icons stay.
        #expect(await driver.currentGeneration(of: .rehide) == 2, "the countdown cancelled")
        clock.advance(by: .seconds(600))
        #expect(await driver.state == .hiddenShown)
    }

    @Test func effectsNeverRunOnTheSendersTask() async {
        let seen = Mutex<[Where]>([])
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: FakeClock(), effects: { _ in
            seen.withLock { $0.append(Where(marker: SenderMarker.current, cancelled: Task.isCancelled)) }
        })
        // A sender that carries a task-local value and has been cancelled: an effect that ran on its task would see both.
        let sender = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await SenderMarker.$current.withValue("the sender") {
                await driver.send(.show(.hidden))
            }
        }
        await sender.value
        #expect(await settled(driver), "the queued effects delivered")
        #expect(seen.withLock { $0 } == [Where(marker: nil, cancelled: false), Where(marker: nil, cancelled: false)],
                "stateChanged and checkRoom, each run on the driver's own task")
    }

    @Test func settledWaitsForQueuedEffects() async {
        let gate = Gate()
        let finished = Mutex<[String]>([])
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: FakeClock(), effects: { effect in
            await gate.wait()
            finished.withLock { $0.append("\(effect)") }
        })
        await driver.send(.show(.hidden))

        let returned = Mutex(false)
        Task {
            await driver.settled()
            finished.withLock { $0.append("settled") }
            returned.withLock { $0 = true }
        }
        // It is waiting, with the caller still busy with the first effect.
        #expect(await waitUntil { finished.withLock { $0.isEmpty } && !returned.withLock { $0 } }, "nothing delivered, settled not returned")
        #expect(await settleWaiters(driver, atLeast: 1), "settled() waiting on the effects")
        #expect(!returned.withLock { $0 })

        gate.open()
        #expect(await waitUntil { returned.withLock { $0 } }, "settled returning")
        // It returned after both effects were finished with, not after the first.
        #expect(finished.withLock { $0 } == ["stateChanged(MKLayout.RevealState.hiddenShown)", "checkRoom", "settled"])
        #expect(await driver.settleWaiting == 0)
    }

    @Test func settledReturnsAtOnceWhenNothingIsQueued() async {
        let rig = Rig(settings())
        #expect(await settled(rig.driver), "nothing queued")
        // And when what was queued has been delivered.
        await rig.driver.send(.show(.hidden))
        await rig.settle()
        #expect(await settled(rig.driver), "everything delivered")
    }

    @Test func settledOnlyWaitsForWhatWasQueuedBeforeIt() async {
        // An event sent from an effect is queued after the call, so the call doesn't wait for it.
        let gate = Gate()
        let box = Mutex<RevealDriver?>(nil)
        defer { box.withLock { $0 = nil } }
        let passed = Passed()
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: FakeClock(), effects: { effect in
            passed.record(effect)
            if effect == .checkRoom {
                await gate.wait()
                await box.withLock { $0 }?.send(.dotClicked(.hidden))
            }
        })
        box.withLock { $0 = driver }
        await driver.send(.show(.hidden))
        #expect(await waitUntil { passed.all.count == 2 }, "both effects reaching the caller")

        let returned = Mutex(false)
        Task {
            await driver.settled()
            returned.withLock { $0 = true }
        }
        gate.open()
        #expect(await waitUntil { returned.withLock { $0 } }, "settled returning")
        // The collapse the effect asked for is queued behind it, and is settled by the next call.
        #expect(await settled(driver), "the collapse delivered")
        #expect(passed.all == [.stateChanged(.hiddenShown), .checkRoom, .stateChanged(.collapsed)])
    }

    @Test func settledEndsWhenItsTaskIsCancelled() async {
        // For a test that waits for it under a time limit: a wait that ignored cancellation would keep the time limit from ending.
        let gate = Gate()
        let driver = RevealDriver(machine: RevealMachine(settings: settings()), clock: FakeClock(), effects: { _ in await gate.wait() })
        defer { gate.open() }
        await driver.send(.show(.hidden))

        let returned = Mutex(false)
        let waiter = Task {
            await driver.settled()
            returned.withLock { $0 = true }
        }
        #expect(await settleWaiters(driver, atLeast: 1), "settled() waiting on the held effects")
        #expect(!returned.withLock { $0 }, "the effects are held, so settled isn't back")
        waiter.cancel()
        #expect(await waitUntil { returned.withLock { $0 } }, "settled returning once its task is cancelled")
        #expect(await driver.settleWaiting == 0)
    }
}
