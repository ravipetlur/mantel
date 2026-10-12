import CoreGraphics
import MKCore
import MKLayout
import MKMenuBar

/// Keeps the clock working while the allowlist hides icons.
///
/// macOS ignores a click on the clock, and the Fn+N shortcut, for as long as an allowlist is live. So while the allowlist is the engine
/// that hides icons, a tap holds those inputs: it swallows one, lifts the allowlist on the spot (`AllowlistEngine.liftNow`, the only
/// thing done inside the tap's callback), and posts the input again 100 ms later. The hidden icons show while Notification Center is
/// open, and a lift runner puts the allowlist back when it closes (`LiftRunner`: polled every 200 ms, with its own time limits).
///
/// - **Only with the allowlist.** The tap is made when the state says the allowlist is the engine in charge, and stopped, with its
///   targets cleared, when it isn't and when the app quits. It is told where the clock is on every display from each new state, so a
///   display that was unplugged takes its target with the next read.
/// - **A tap and its runner live together.** Each is made when the tap starts and is stopped for good with it; a later start makes new
///   ones. Stopping doesn't put the allowlist back: when the tap is stopped the allowlist is no longer wanted, and letting go of it, and
///   of any lift, is the engine's teardown.
/// - **The tap can fail to start** (Accessibility isn't on for Mantel): that is logged once, and the next state tries again.
/// - **`shutDown()` is final** (the app is quitting): the session goes on publishing states while what Mantel changed is put back, and
///   a state that says "the allowlist" would otherwise start a tap again, in which a click on the clock lifts the allowlist and puts it
///   back, an assertion macOS holds for about 5 seconds after Mantel has gone.
/// - **Everything that decides is in the package:** the targets (`ClickReplayTargets`), what the tap swallows (`SystemClickPolicy`),
///   and when a lift ends (`LiftSession`, run by `LiftRunner`).
final class ClockClickController {
    private let allowlist: AllowlistEngine
    private let windows: any WindowListReading
    private let layout: @Sendable () -> DisplayLayout
    private var tap: SystemClickTap?
    private var runner: LiftRunner?
    private var targets: [CGRect] = []
    private var hasLoggedFailure = false
    /// Whether the tap may run (`ClockClickGate`: the allowlist is the engine in charge, and `shutDown()` hasn't been called).
    private var gate = ClockClickGate()

    /// - Parameters:
    ///   - allowlist: the engine whose assertion is lifted and put back.
    ///   - windows: where Notification Center's panel is looked for.
    ///   - layout: the displays as they are now.
    init(allowlist: AllowlistEngine, windows: any WindowListReading, layout: @escaping @Sendable () -> DisplayLayout) {
        self.allowlist = allowlist
        self.windows = windows
        self.layout = layout
    }

    /// The menu bar's state changed: the tap is made, stopped or told where the clock is, as the state says.
    func update(_ state: MenuBarState?) {
        // Once shut down, nothing a state says starts it again.
        guard !gate.isShutDown else { return }
        guard let state, gate.isWanted(whileHidingWith: state.engine.kind) else {
            stop()
            return
        }
        let rects = ClickReplayTargets.rects(in: state.inventory)
        guard let tap else {
            start(with: rects)
            return
        }
        if rects != targets {
            targets = rects
            tap.setTargets(rects)
        }
    }

    /// Stops the tap for good: it is stopped as `stop()` does, and no state that comes after starts it again. For quitting, and nothing else.
    /// Safe to call more than once.
    func shutDown() {
        gate.shutDown()
        stop()
    }

    /// Stops the tap and its runner, and clears the targets. Safe to call at any time and more than once. The next state that wants a tap
    /// starts a new one (unless `shutDown()` was called).
    func stop() {
        tap?.stop()
        runner?.stop()
        tap = nil
        runner = nil
        targets = []
    }

    private func start(with rects: [CGRect]) {
        let allowlist = allowlist, windows = windows, layout = layout
        let runner = LiftRunner(isOpen: { OpenedSystemUI.isOpen(windows.onScreenWindows(), layout: layout()) },
                                restore: { await allowlist.restoreAfterLift() })
        let tap = SystemClickTap(
            // Each runs on the tap's own threads: the first two inside the event callback, where every input in the system waits.
            armed: { allowlist.isArmed },
            onHold: { _ = allowlist.liftNow() },
            onReplayed: { runner.replayed() },
            onClickOutside: { runner.clickOutside() })
        tap.setTargets(rects)
        do {
            try tap.start()
        } catch {
            if !hasLoggedFailure {
                hasLoggedFailure = true
                Log.warning("clicks", "the clock can't be clicked while icons are hidden: \(error.localizedDescription)")
            }
            return
        }
        hasLoggedFailure = false
        self.tap = tap
        self.runner = runner
        targets = rects
    }
}
