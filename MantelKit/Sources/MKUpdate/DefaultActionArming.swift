import Foundation

/// When the update window's Return key may install. An offer can open while the person is typing in another app, and a
/// Return meant for that app must not install an update: Return does nothing until the window has been key for `delay`
/// without a break (the pattern of the URL consent prompt's Allow button). Losing key disables it at once, and the wait
/// starts again from the next time the window is key. A click on the button isn't held back, since a click is a choice.
///
/// Time is measured on the continuous clock, which never jumps: a change of the wall clock (a manual change, a network
/// time correction) can neither leave Return disabled after the wait is over nor enable it early.
public struct DefaultActionArming: Sendable {
    /// How long the window has to have been key.
    public static let defaultDelay: TimeInterval = 1.5

    public let delay: TimeInterval
    public private(set) var isEnabled = false
    /// Since when the window has been key without a break; nil while it isn't.
    private var keySince: ContinuousClock.Instant?

    public init(delay: TimeInterval = defaultDelay) {
        self.delay = delay
    }

    /// The window as it is `now`: `isKey` says whether it is the key window. Returns whether Return may install.
    public mutating func observe(isKey: Bool, at now: ContinuousClock.Instant) -> Bool {
        guard isKey else {
            restart()
            return false
        }
        let since = keySince ?? now
        keySince = since
        isEnabled = now - since >= .seconds(delay)
        return isEnabled
    }

    /// Disables Return at once, and starts the wait again from the next time the window is key.
    public mutating func restart() {
        keySince = nil
        isEnabled = false
    }
}
