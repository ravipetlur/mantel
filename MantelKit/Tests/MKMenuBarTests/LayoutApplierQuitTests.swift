import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// What a quit does to a write the applier's own task has begun (the flush's own cases are in `LayoutApplierTests`).
@Suite("Layout applier: quitting", .timeLimit(.minutes(1)))
struct LayoutApplierQuitTests {
    private typealias F = LayoutFixtures

    private func applier(clock: FakeClock, writer: FakeLayoutWriter, read: @escaping @Sendable () async -> CheckRead? = { nil },
                         held: @escaping @Sendable () async -> String? = { nil }) -> LayoutApplier {
        LayoutApplier(writer: writer, rules: F.rules(), clock: clock, read: read, shownBars: { Set($0.bars.map(\.displayUUID)) },
                      phase: { _, _, _ in }, held: held)
    }

    private func request(_ applier: LayoutApplier) async {
        await applier.request(F.inputs(), ownBundleID: F.own, inventory: F.ownDrawn(), memory: [:], concealedApps: [], cause: .person)
    }

    @Test func aWorkerPastItsDebounceDoesNotWriteOnceTheQuitHasBegun() async {
        let clock = FakeClock(), writer = FakeLayoutWriter()
        let gate = Gate()
        let calls = CallCounter()
        // The worker is at its check of whether the write is held (two actor hops on a real Mac) when the quit begins.
        let applier = applier(clock: clock, writer: writer, held: {
            if calls.next() == 1 { await gate.wait() }
            return nil
        })
        defer { gate.open() }
        await request(applier)
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { calls.count == 1 })

        let flushing = Task { await applier.flushForQuit() }
        // The quit has begun (the flush waits for the worker, which is held at its check) before the limit passes and the worker moves.
        #expect(await withinTimeLimit(.seconds(10)) {
            while await !applier.quitHasBegun { await Task.yield() }
            return true
        } == true)
        // The caller's limit passes before the worker has handed anything to the writer.
        #expect(await applier.abandonQuitFlush() == .stopped, "a change that hasn't begun to be written is dropped")
        gate.open()
        await flushing.value
        #expect(writer.writeCount == 0, "the worker doesn't begin it after the limit, and the flush has been told to leave it")
    }

    @Test func aWorkerPastItsDebounceHandsItsRequestToTheFlushWhenTheLimitHasNotPassed() async {
        let clock = FakeClock(), writer = FakeLayoutWriter()
        let gate = Gate()
        let calls = CallCounter()
        let applier = applier(clock: clock, writer: writer, held: {
            if calls.next() == 1 { await gate.wait() }
            return nil
        })
        defer { gate.open() }
        await request(applier)
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { calls.count == 1 })

        let flushing = Task { await applier.flushForQuit() }
        gate.open()
        await flushing.value
        #expect(writer.writeCount == 1, "written once, by the flush, and not waited for")
        #expect(await applier.abandonQuitFlush() == .finished)
    }

    @Test func aQuitDuringTheCheckOfAnEarlierWriteHasNothingToDrop() async {
        let clock = FakeClock(), writer = FakeLayoutWriter()
        let gate = Gate()
        let reading = CallCounter()
        // The write is made; the worker is reading the bar to check it, and the read is slow.
        let applier = applier(clock: clock, writer: writer, read: {
            reading.bump()
            await gate.wait()
            return nil
        })
        defer { gate.open() }
        await request(applier)
        let began = await withinTimeLimit(.seconds(10)) {
            while reading.count == 0 {
                if await clock.waitForSleepers(1, within: .milliseconds(20)) { clock.advance(by: .milliseconds(250)) }
            }
            return true
        }
        #expect(began == true)
        #expect(writer.writeCount == 1)

        let flushing = Task { await applier.flushForQuit() }
        // Nothing is waiting to be written: the session has no change to say it dropped.
        #expect(await applier.abandonQuitFlush() == .nothingWaiting)
        gate.open()
        await flushing.value
        #expect(writer.writeCount == 1)
    }
}

/// How often a closure has been called, for a test to tell which call it is.
private final class CallCounter: Sendable {
    private let state = Mutex2()
    func next() -> Int { state.bump() }
    func bump() { _ = state.bump() }
    var count: Int { state.value }
}

private final class Mutex2: Sendable {
    private let box = Synchronization.Mutex(0)
    func bump() -> Int { box.withLock { $0 += 1; return $0 } }
    var value: Int { box.withLock { $0 } }
}
