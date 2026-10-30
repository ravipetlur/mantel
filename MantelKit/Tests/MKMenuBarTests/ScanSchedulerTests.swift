import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The scans a scheduler asked for, in order, and a way to wait for the next.
private final class ScanRecorder: Sendable {
    private struct Waiter {
        let id: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var scans: [Set<ScanScheduler.Reason>] = []
        var waiters: [Waiter] = []
        var nextID = 0
        var running = 0
        var overlapped = false
    }

    private let state = Mutex(State())

    var scans: [Set<ScanScheduler.Reason>] { state.withLock { $0.scans } }
    var overlapped: Bool { state.withLock { $0.overlapped } }

    /// A scan begins; it ends when `end()` is called.
    func begin(_ reasons: Set<ScanScheduler.Reason>) {
        let ready = state.withLock { state -> [Waiter] in
            state.running += 1
            if state.running > 1 { state.overlapped = true }
            state.scans.append(reasons)
            let ready = state.waiters.filter { $0.count <= state.scans.count }
            state.waiters.removeAll { $0.count <= state.scans.count }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    func end() {
        state.withLock { $0.running -= 1 }
    }

    /// Returns once at least `count` scans have begun.
    func waitForScans(_ count: Int) async {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let enough = state.withLock { state -> Bool in
                    if state.scans.count >= count || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if enough { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }
}

/// What a wait that doesn't end in a few seconds says: the test fails, and doesn't hang until its time limit.
private struct WaitTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "Waited 5 seconds for \(what), which didn't come." }
}

private func sleepers(_ clock: FakeClock, _ count: Int) async throws {
    guard await clock.waitForSleepers(count, within: .seconds(5)) else { throw WaitTimedOut(what: "\(count) sleeper(s) on the clock") }
}

private func scans(_ recorder: ScanRecorder, _ count: Int) async throws {
    let reached = await withinTimeLimit(.seconds(5)) {
        await recorder.waitForScans(count)
        return recorder.scans.count >= count
    }
    guard reached == true else { throw WaitTimedOut(what: "scan number \(count)") }
}

private func idle(_ scheduler: ScanScheduler) async throws {
    guard await withinTimeLimit(.seconds(5), { await scheduler.waitUntilIdle(); return true }) == true else {
        throw WaitTimedOut(what: "the scheduler to be idle")
    }
}

private func makeScheduler(clock: any Clock, recorder: ScanRecorder, hold: Gate? = nil) -> ScanScheduler {
    ScanScheduler(clock: clock) { reasons in
        recorder.begin(reasons)
        if let hold { await hold.wait() }
        recorder.end()
    }
}

@Suite("Scan scheduler", .timeLimit(.minutes(1)))
struct ScanSchedulerTests {
    @Test func requestsWithin100msCoalesce() async throws {
        let clock = FakeClock()
        let recorder = ScanRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)

        await scheduler.request(.appsChanged)
        try await sleepers(clock, 1)
        clock.advance(by: .milliseconds(60))
        await scheduler.request(.displaysChanged)
        await scheduler.request(.appsChanged)
        #expect(recorder.scans.isEmpty, "not before the 100 ms are up")
        clock.advance(by: .milliseconds(40))
        try await scans(recorder, 1)

        #expect(recorder.scans == [[.appsChanged, .displaysChanged]], "one scan, told both reasons")
        // And nothing more comes of it.
        #expect(clock.sleeperCount == 0)
    }

    @Test func refreshAndRevealScanAtOnce() async throws {
        let clock = FakeClock()
        let recorder = ScanRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)

        await scheduler.request(.refresh)
        try await scans(recorder, 1)
        #expect(recorder.scans == [[.refresh]], "no waiting for it")
        try await idle(scheduler)

        // A reveal doesn't wait either, and takes what was waiting along.
        await scheduler.request(.appsChanged)
        try await sleepers(clock, 1)
        await scheduler.request(.reveal)
        try await scans(recorder, 2)
        #expect(recorder.scans == [[.refresh], [.appsChanged, .reveal]])
        #expect(clock.sleeperCount == 0, "the wait it cut short is over")
    }

    @Test func stopCancelsPolling() async throws {
        let clock = FakeClock()
        let recorder = ScanRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        await scheduler.start()
        try await sleepers(clock, 1)
        await scheduler.request(.appsChanged)
        try await sleepers(clock, 2)

        await scheduler.stop()
        #expect(clock.sleeperCount == 0, "the poll and the wait were both cancelled")
        clock.advance(by: .seconds(60))
        // Nothing asked for is scanned, and nothing asked for now is either.
        await scheduler.request(.refresh)
        try await idle(scheduler)
        #expect(recorder.scans.isEmpty)

        // Started again, it polls again.
        await scheduler.start()
        try await sleepers(clock, 1)
        clock.advance(by: .seconds(10))
        try await sleepers(clock, 2)
        clock.advance(by: .milliseconds(100))
        try await scans(recorder, 1)
        #expect(recorder.scans == [[.poll]])
        await scheduler.stop()
    }

    @Test func scansNeverOverlapAndWhatIsAskedMeanwhileIsOneMoreScan() async throws {
        let clock = FakeClock()
        let recorder = ScanRecorder()
        let gate = Gate()
        let scheduler = makeScheduler(clock: clock, recorder: recorder, hold: gate)

        await scheduler.request(.refresh)
        try await scans(recorder, 1)
        // The first scan is under way; these come while it is.
        await scheduler.request(.appsChanged)
        await scheduler.request(.displaysChanged)
        await scheduler.request(.reveal)
        #expect(recorder.scans.count == 1)
        gate.open()
        try await scans(recorder, 2)
        #expect(recorder.scans == [[.refresh], [.appsChanged, .displaysChanged, .reveal]])
        #expect(!recorder.overlapped)
    }
}
