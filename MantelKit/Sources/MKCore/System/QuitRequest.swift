import AppKit

/// How the app asks AppKit to quit from code (the hand-off quit, the move to Applications, the onboarding's quit, a SIGTERM).
///
/// `NSApp.terminate(nil)` called from inside a main-queue block or a main-actor task doesn't let the quit finish: when the delegate
/// answers "later", AppKit waits for the reply in a nested run loop inside that block, and the main queue isn't drained meanwhile, so the
/// cleanup and the quit timer that answer it (both main-actor tasks) never run. The Quit command isn't affected: AppKit calls `terminate`
/// from an event. So code asks from the run loop instead: the request is scheduled with a zero delay, and made after the block or task
/// that asked has returned.
///
/// The modes are the default one and event tracking (a menu being open), and **not** the modal-panel mode, so not `.common` either: AppKit
/// waits for the delegate's reply in that mode, and a request served inside the wait (a second one, made while a quit is under way) would
/// end the app at once, without asking the delegate and without the cleanup. A request made while a modal alert is up (`runModal()`) is
/// served when the alert ends, rather than inside its loop, where it would be held as in a block. The cost: a SIGTERM while a panel is up
/// waits for it to close, or for the SIGTERM's fallback. The scheduling itself is the app's (`AppQuit`), passed in, so that what is asked
/// for is tested without a run loop.
public enum QuitRequest {
    /// How long after the asking the request is made: as soon as the run loop is next served.
    public static let delay: TimeInterval = 0

    /// The run loop modes the request is served in.
    public static let modes: [RunLoop.Mode] = [.default, .eventTracking]

    /// Asks for the quit through `schedule`, which makes the request `delay` seconds from now, in `modes`.
    public static func ask(through schedule: (_ delay: TimeInterval, _ modes: [RunLoop.Mode]) -> Void) {
        schedule(delay, modes)
    }
}
