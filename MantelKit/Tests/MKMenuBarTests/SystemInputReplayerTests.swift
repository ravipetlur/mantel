import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import MKMenuBar

/// What the tap does with an input it has held, apart from the system: the caller is told on the spot, before anything is scheduled, and
/// the input is posted again `delay` after. The scheduler and the posting are a test's own, so nothing is posted and nothing waits.
@Suite("System input replayer", .timeLimit(.minutes(1)))
struct SystemInputReplayerTests {
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

    private func replayer(_ stage: Stage, delay: Duration) -> SystemInputReplayer {
        SystemInputReplayer(delay: delay, onHold: { stage.note("hold") }, onReplayed: { stage.note("replayed") },
                            schedule: { stage.schedule(after: $0, work: $1) },
                            post: { held, isDown, flags in
                                let what: String
                                switch held {
                                case .click(let left, let point): what = "\(left ? "left" : "right") click \(Int(point.x)),\(Int(point.y))"
                                case .key(let code): what = "key \(code)"
                                }
                                stage.note("post \(isDown ? "down" : "up") \(what) \(flags.rawValue)")
                            })
    }

    @Test(arguments: [20, 100, 400])
    func theCallerIsToldBeforeTheReplayIsScheduledAtEveryDelay(delay: Int) {
        let stage = Stage()
        replayer(stage, delay: .milliseconds(delay)).hold(.click(left: true, at: CGPoint(x: 3300, y: 10)), flags: [])

        #expect(stage.events == ["hold", "scheduled \(delay) ms"], "onHold ran, and returned, before anything was scheduled")
    }

    @Test func aClickIsPostedAgainAfterTheDelayAndTheReplayIsReportedOnceItIsPosted() {
        let stage = Stage()
        replayer(stage, delay: .milliseconds(100)).hold(.click(left: true, at: CGPoint(x: 3300, y: 10)), flags: .maskCommand)
        #expect(stage.scheduledDelays == [.milliseconds(100)])

        stage.runNext()
        #expect(stage.events == [
            "hold", "scheduled 100 ms",
            "post down left click 3300,10 \(CGEventFlags.maskCommand.rawValue)", "replayed", "scheduled 30 ms",
        ], "the hold came first, the down was posted after the delay, and the replay is reported when it has been posted")

        stage.runNext()
        #expect(stage.events.last == "post up left click 3300,10 \(CGEventFlags.maskCommand.rawValue)", "the up follows the down by 30 ms")
    }

    @Test func aRightClickIsReplayedAsOne() {
        let stage = Stage()
        replayer(stage, delay: .milliseconds(100)).hold(.click(left: false, at: CGPoint(x: 3300, y: 10)), flags: [])
        stage.runNext()
        stage.runNext()
        #expect(stage.events == [
            "hold", "scheduled 100 ms",
            "post down right click 3300,10 0", "replayed", "scheduled 30 ms",
            "post up right click 3300,10 0",
        ])
    }

    @Test func fnNIsReplayedWithTheFlagsItHad() {
        let stage = Stage()
        let flags: CGEventFlags = [.maskSecondaryFn, .maskNonCoalesced]
        replayer(stage, delay: .milliseconds(100)).hold(.key(45), flags: flags)
        stage.runNext()
        stage.runNext()

        #expect(stage.events == [
            "hold", "scheduled 100 ms",
            "post down key 45 \(flags.rawValue)", "replayed", "scheduled 30 ms",
            "post up key 45 \(flags.rawValue)",
        ])
    }

    @Test func eachHoldIsReplayedOnItsOwn() {
        let stage = Stage()
        let replayer = replayer(stage, delay: .milliseconds(50))
        replayer.hold(.click(left: true, at: CGPoint(x: 1, y: 2)), flags: [])
        replayer.hold(.key(45), flags: [])
        #expect(stage.events == ["hold", "scheduled 50 ms", "hold", "scheduled 50 ms"])
    }
}

/// The parts of the tap that don't need an event stream: it is never started here, and nothing is installed.
@Suite("System click tap, not installed", .timeLimit(.minutes(1)))
struct SystemClickTapOffTests {
    private func tap() -> SystemClickTap {
        SystemClickTap(armed: { false }, onHold: {}, onReplayed: {}, onClickOutside: {})
    }

    @Test func aTapThatWasNeverStartedStopsQuietlyAndMoreThanOnce() {
        let tap = tap()
        tap.setTargets([CGRect(x: 3268, y: 0, width: 80, height: 30)])
        tap.stop()
        tap.stop()
    }

    @Test func targetsCanBeSetFromAnyThread() async {
        let tap = tap()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { tap.setTargets(index.isMultiple(of: 2) ? [] : [CGRect(x: CGFloat(index), y: 0, width: 80, height: 30)]) }
            }
        }
        tap.stop()
    }
}
