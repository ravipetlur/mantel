import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// Which apps the fake allowlist is hiding at the moment. A slot of a hidden app has no frame. It remembers what it hid before the
/// last change and when that was, so that something that lags behind the allowlist can show the old state for a while.
final class HiddenApps: Sendable {
    private struct State {
        var current: Set<String> = []
        var previous: Set<String> = []
        var changedAt: Date?
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    var all: Set<String> { state.withLock { $0.current } }

    func set(_ apps: Set<String>) {
        state.withLock { state in
            guard apps != state.current else { return }
            state.previous = state.current
            state.current = apps
            state.changedAt = now()
        }
    }

    func contains(_ app: String) -> Bool { state.withLock { $0.current.contains(app) } }

    /// Whether the app is hidden as something that is `lag` behind the allowlist shows it at `time`: what it hid before the last
    /// change until `lag` after the change, and what it hides now after.
    func isHidden(_ app: String, at time: Date, lag: Duration) -> Bool {
        state.withLock { state in
            let seconds = Double(lag.components.seconds) + Double(lag.components.attoseconds) / 1e18
            if let changedAt = state.changedAt, time < changedAt.addingTimeInterval(seconds) { return state.previous.contains(app) }
            return state.current.contains(app)
        }
    }
}
