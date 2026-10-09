import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// An assertion that counts how often it was let go.
private final class RecordingHandle: AllowlistAssertionHandle {
    private let count = Mutex(0)

    var invalidations: Int { count.withLock { $0 } }
    func invalidate() { count.withLock { $0 += 1 } }
}

/// What a fake activator was asked, and the completion handler it was given, to call whenever a test says macOS would.
private final class FakeActivator: Sendable {
    private struct State {
        var calls = 0
        var handles: [RecordingHandle] = []
        var completions: [@Sendable (AllowlistError?) -> Void] = []
        var script: (@Sendable (@Sendable (AllowlistError?) -> Void) throws -> Void)?
        var refusal: AllowlistError?
    }

    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    var handle: RecordingHandle? { state.withLock { $0.handles.first } }
    var completion: (@Sendable (AllowlistError?) -> Void)? { state.withLock { $0.completions.first } }

    func refuse(with error: AllowlistError) { state.withLock { $0.refusal = error } }
    /// Runs inside the activator, before it returns: macOS calling the handler at once.
    func onActivate(_ script: @escaping @Sendable (@Sendable (AllowlistError?) -> Void) throws -> Void) {
        state.withLock { $0.script = script }
    }

    var activator: LiveAllowlist.Activator {
        { [self] _, _, completion in
            let (refusal, script) = state.withLock { state -> (AllowlistError?, (@Sendable (@Sendable (AllowlistError?) -> Void) throws -> Void)?) in
                state.calls += 1
                return (state.refusal, state.script)
            }
            if let refusal { throw refusal }
            let handle = RecordingHandle()
            state.withLock {
                $0.handles.append(handle)
                $0.completions.append(completion)
            }
            try script?(completion)
            return handle
        }
    }
}

@Suite("Allowlist activation", .timeLimit(.minutes(1)))
struct AllowlistActivationTests {
    private func live(_ clock: FakeClock, _ activator: FakeActivator) -> LiveAllowlist {
        LiveAllowlist(timeout: LiveAllowlist.activationTimeout, clock: clock, activator: activator.activator)
    }

    @Test func theTimeoutIsThreeSeconds() {
        #expect(LiveAllowlist.activationTimeout == .seconds(3))
    }

    @Test func anActivationThatCompletesAtOnceReturnsItsAssertionAndNoTimerIsLeft() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        activator.onActivate { completion in completion(nil) }
        let handle = try await live(clock, activator).activate(systemItems: [2], bundleIDs: ["com.example.a"])
        #expect(activator.handle.map { $0 === (handle as AnyObject) } == true)
        #expect(activator.handle?.invalidations == 0, "the caller holds it now")
        #expect(clock.sleeperCount == 0)
    }

    @Test func anActivationThatCompletesLaterReturnsItsAssertionAndStopsTheTimer() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        let allowlist = live(clock, activator)
        let task = Task { try await allowlist.activate(systemItems: [], bundleIDs: []) }
        await clock.waitForSleepers(1)
        activator.completion?(nil)
        let handle = try await task.value
        #expect(activator.handle.map { $0 === (handle as AnyObject) } == true)
        #expect(activator.handle?.invalidations == 0)
        #expect(clock.sleeperCount == 0, "the timer was cancelled by the completion")
    }

    @Test func anActivationThatNeverCompletesIsGivenUpOnAndItsAssertionIsInvalidated() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        let allowlist = live(clock, activator)
        let task = Task { try await allowlist.activate(systemItems: [], bundleIDs: []) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        #expect(activator.handle?.invalidations == 0, "not yet")
        clock.advance(by: .seconds(1))

        await #expect(throws: AllowlistError.failed("macOS didn't finish activating the allowlist within 3 s.")) {
            try await task.value
        }
        #expect(activator.handle?.invalidations == 1)
    }

    @Test func aCompletionThatComesAfterTheTimeoutChangesNothing() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        let allowlist = live(clock, activator)
        let task = Task { try await allowlist.activate(systemItems: [], bundleIDs: []) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(3))
        _ = await task.result
        activator.completion?(nil)
        activator.completion?(.failed("late"))
        #expect(activator.handle?.invalidations == 1, "let go once, when it was given up on")
    }

    @Test func aCancelledActivationInvalidatesItsAssertionAndStopsTheTimer() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        let allowlist = live(clock, activator)
        let task = Task { try await allowlist.activate(systemItems: [], bundleIDs: []) }
        await clock.waitForSleepers(1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(activator.handle?.invalidations == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func anActivationCancelledBeforeItStartsActivatesNothing() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        let allowlist = live(clock, activator)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await allowlist.activate(systemItems: [], bundleIDs: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(activator.calls == 0, "nothing was asked of macOS")
    }

    @Test func anErrorFromMacOSIsThrownAndTheAssertionInvalidatedWhicheverComesFirst() async throws {
        // The error before the assertion object is back (the handler runs inside the call)...
        let first = FakeActivator()
        first.onActivate { completion in completion(.failed("no")) }
        await #expect(throws: AllowlistError.failed("no")) {
            try await live(FakeClock(), first).activate(systemItems: [], bundleIDs: [])
        }
        #expect(first.handle?.invalidations == 1)

        // ...and after it.
        let clock = FakeClock()
        let second = FakeActivator()
        let allowlist = live(clock, second)
        let task = Task { try await allowlist.activate(systemItems: [], bundleIDs: []) }
        await clock.waitForSleepers(1)
        second.completion?(.failed("later"))
        await #expect(throws: AllowlistError.failed("later")) { try await task.value }
        #expect(second.handle?.invalidations == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func anActivatorThatRefusesIsRethrownWithNoTimer() async throws {
        let clock = FakeClock()
        let activator = FakeActivator()
        activator.refuse(with: .refused("encoding"))
        await #expect(throws: AllowlistError.refused("encoding")) {
            try await live(clock, activator).activate(systemItems: [], bundleIDs: [])
        }
        #expect(clock.sleeperCount == 0)
    }

    @Test func theJoinLetsGoOfTheAssertionOnceItHasResumed() async throws {
        // Otherwise assertion → block → join → assertion would be a cycle that keeps a released assertion alive.
        let join = ActivationJoin()
        let watched = WeakBox()
        let wasTheSame = try await runJoin(join, watching: watched)
        #expect(wasTheSame)
        #expect(watched.value == nil, "nothing but the caller held it, and the caller is done")
        withExtendedLifetime(join) {}
    }
}

/// A reference that doesn't keep what it points to alive.
private final class WeakBox {
    weak var value: RecordingHandle?
}

/// Runs a join to its end with an assertion that only `box` knows weakly, and lets the assertion go.
private func runJoin(_ join: ActivationJoin, watching box: WeakBox) async throws -> Bool {
    let handle = RecordingHandle()
    box.value = handle
    let returned = try await resolve(join, giving: handle)
    return (returned as? RecordingHandle) === handle
}

private func resolve(_ join: ActivationJoin, giving handle: RecordingHandle) async throws -> any AllowlistAssertionHandle {
    try await withCheckedThrowingContinuation { continuation in
        _ = join.install(continuation)
        join.provide(handle)
        join.complete(nil)
    }
}
