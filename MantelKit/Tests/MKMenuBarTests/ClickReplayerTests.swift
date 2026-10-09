import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import MKMenuBar

/// What the tap does with a click it has held, apart from the system: the caller is told on the spot, before anything is
/// scheduled, and the click is posted again `delay` after. The scheduler and the posting are a test's own, so nothing is
/// posted and nothing waits.
@Suite("Click replayer", .timeLimit(.minutes(1)))
struct ClickReplayerTests {
    /// The order things happened in, and the work that was scheduled and hasn't run.
    private final class Stage: Sendable {
        private struct State {
            var events: [String] = []
            var scheduled: [(after: Duration, work: @Sendable () -> Void)] = []
        }

        private let state = Mutex(State())

        var events: [String] { state.withLock { $0.events } }
        var scheduledDelays: [Duration] { state.withLock { $0.scheduled.map(\.after) } }

        func note(_ event: String) { state.withLock { $0.events.append(event) } }

        func schedule(after: Duration, work: @escaping @Sendable () -> Void) {
            state.withLock {
                $0.events.append("scheduled \(Int(after.components.attoseconds / 1_000_000_000_000_000)) ms")
                $0.scheduled.append((after, work))
            }
        }

        /// Runs what was scheduled first (which may schedule more).
        func runNext() {
            let next = state.withLock { $0.scheduled.isEmpty ? nil : $0.scheduled.removeFirst() }
            next?.work()
        }
    }

    private func replayer(_ stage: Stage, delay: Duration) -> ClickReplayer {
        ClickReplayer(delay: delay,
                      onClick: { stage.note("click \(Int($0.x)),\(Int($0.y))") },
                      onReplay: { stage.note("replayed \(Int($0.x)),\(Int($0.y))") },
                      schedule: { stage.schedule(after: $0, work: $1) },
                      post: { type, point, flags in
                          stage.note("post \(type == .leftMouseDown ? "down" : "up") \(Int(point.x)),\(Int(point.y)) \(flags.rawValue)")
                      })
    }

    @Test(arguments: [20, 100, 400])
    func theCallerIsToldBeforeTheReplayIsScheduledAtEveryDelay(delay: Int) {
        let stage = Stage()
        replayer(stage, delay: .milliseconds(delay)).hold(at: CGPoint(x: 3320, y: 10), flags: [])

        #expect(stage.events == ["click 3320,10", "scheduled \(delay) ms"], "the click callback ran, and returned, before anything was scheduled")
    }

    @Test(arguments: [20, 100, 400])
    func theClickIsPostedAgainAfterTheDelayAndTheReplayIsReportedOnceItIsPosted(delay: Int) {
        let stage = Stage()
        replayer(stage, delay: .milliseconds(delay)).hold(at: CGPoint(x: 3320, y: 10), flags: .maskCommand)
        #expect(stage.scheduledDelays == [.milliseconds(delay)])

        stage.runNext()
        #expect(stage.events == [
            "click 3320,10", "scheduled \(delay) ms",
            "post down 3320,10 \(CGEventFlags.maskCommand.rawValue)", "replayed 3320,10", "scheduled 30 ms",
        ], "the lift came first, the down was posted after the delay, and the replay is reported when it has been posted")

        stage.runNext()
        #expect(stage.events.last == "post up 3320,10 \(CGEventFlags.maskCommand.rawValue)", "the up follows the down by 30 ms")
    }

    @Test func eachClickIsHeldAndReplayedOnItsOwn() {
        let stage = Stage()
        let replayer = replayer(stage, delay: .milliseconds(50))
        replayer.hold(at: CGPoint(x: 1, y: 2), flags: [])
        replayer.hold(at: CGPoint(x: 3, y: 4), flags: [])
        #expect(stage.events == ["click 1,2", "scheduled 50 ms", "click 3,4", "scheduled 50 ms"])
    }
}
