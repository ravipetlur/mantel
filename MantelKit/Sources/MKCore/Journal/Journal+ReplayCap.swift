import Foundation
import Synchronization

/// How a replay with a cap ended.
public enum JournalReplayOutcome: Sendable, Equatable {
    /// Every entry was tried; these couldn't be restored and stay in the journal.
    case completed([ReplayFailure])
    /// The cap came first: the replay was cancelled, and the entries not yet restored stay in the journal for the next launch.
    case timedOut
}

extension Journal {
    /// `replay(using:lifetimes:)`, given up on after `cap`.
    ///
    /// A restore that hangs (a file that doesn't answer) would keep the launch from going on, and with it the • and Settings.
    /// After the cap the replay's task is cancelled, which makes the restorers that look at cancellation (the plist one does)
    /// restore nothing more, and this returns `.timedOut` at once, whether or not the restore that is under way ever
    /// returns. What wasn't restored is still in the journal; the journal stays closed to `record` until the replay is over.
    public nonisolated func replay(using restorer: any JournalRestoring, cap: Duration, clock: any Clock = SystemClock(),
                                   lifetimes: Set<JournalLifetime> = [.untilQuit]) async -> JournalReplayOutcome {
        let race = ReplayRace()
        return await withCheckedContinuation { (continuation: CheckedContinuation<JournalReplayOutcome, Never>) in
            race.install(continuation)
            let timer = Task {
                do {
                    try await clock.sleep(for: cap)
                    race.finish(.timedOut)
                } catch {
                    // Cancelled: the replay has finished first.
                }
            }
            let replay = Task {
                race.finish(.completed(await self.replay(using: restorer, lifetimes: lifetimes)))
            }
            race.tasks(timer: timer, replay: replay)
        }
    }
}

/// Whichever of the replay and the timer comes first decides the outcome, once; the other is cancelled. The caller hears of
/// it only when the two tasks have been handed over, so that the one that lost is always found and cancelled first.
private final class ReplayRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<JournalReplayOutcome, Never>?
        var outcome: JournalReplayOutcome?
        var timer: Task<Void, Never>?
        var replay: Task<Void, Never>?
        var resumed = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<JournalReplayOutcome, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    func tasks(timer: Task<Void, Never>, replay: Task<Void, Never>) {
        state.withLock { state in
            state.timer = timer
            state.replay = replay
        }
        completeIfDecided()
    }

    /// The first outcome stands; a later one is ignored.
    func finish(_ outcome: JournalReplayOutcome) {
        state.withLock { state in
            if state.outcome == nil { state.outcome = outcome }
        }
        completeIfDecided()
    }

    private func completeIfDecided() {
        let decision = state.withLock { state -> (CheckedContinuation<JournalReplayOutcome, Never>, JournalReplayOutcome, Task<Void, Never>, Task<Void, Never>)? in
            guard !state.resumed, let continuation = state.continuation, let outcome = state.outcome,
                  let timer = state.timer, let replay = state.replay else { return nil }
            state.resumed = true
            return (continuation, outcome, timer, replay)
        }
        guard let (continuation, outcome, timer, replay) = decision else { return }
        switch outcome {
        case .completed: timer.cancel()
        case .timedOut: replay.cancel()
        }
        continuation.resume(returning: outcome)
    }
}
