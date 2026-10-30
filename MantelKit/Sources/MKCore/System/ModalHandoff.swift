import Foundation

/// How the app starts a modal alert from code: from the run loop, not from inside the main-queue block or the task that is running.
///
/// `runModal()` called from a task or a queued block runs its loop inside that block, and the main queue isn't drained while it is up: the
/// session's main-actor work, a SIGTERM's own block and a quit's cleanup all wait for the person to answer (`QuitRequest` has the same
/// cause). So the alert is put off to the run loop, in the modes `QuitRequest` explains, and the code that asked awaits the answer. The
/// scheduling itself is the app's (`ModalLoop`), passed in, so that what is asked for is tested without a run loop.
public enum ModalHandoff {
    /// The run loop modes the alert is started in: the default one only. Not the modal-panel mode, so that a second alert asked for while
    /// one is up waits until it has ended; and not event tracking either, so that one asked for while a menu is open or a button is held
    /// down starts when that has ended, not nested inside it.
    public static let modes: [RunLoop.Mode] = [.default]

    /// Runs `body` (the one that starts the modal loop) from the run loop, through `schedule`, which serves `work` in `modes` and never
    /// inline, and gives back what `body` gave back. `body` is never called before `schedule` serves `work`, and never from the caller.
    @MainActor
    public static func run<Answer: Sendable>(
        through schedule: (_ modes: [RunLoop.Mode], _ work: @escaping @Sendable () -> Void) -> Void,
        _ body: @escaping @MainActor () -> Answer
    ) async -> Answer {
        await withCheckedContinuation { continuation in
            schedule(modes) {
                MainActor.assumeIsolated { continuation.resume(returning: body()) }
            }
        }
    }
}
