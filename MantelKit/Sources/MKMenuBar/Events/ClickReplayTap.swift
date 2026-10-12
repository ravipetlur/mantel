import CoreGraphics
import Foundation
import MKCore
import Synchronization

/// Which mouse event it is, of the three the tap listens to.
enum ClickKind: Equatable {
    case leftDown, leftUp, leftDragged
}

enum ClickDecision: Equatable {
    case pass, swallow
}

/// What the click-replay tap does with each event, as a value that is tested on its own.
///
/// - A left mouse-down inside one of the rects is swallowed; so is everything of that click until its mouse-up (the drags,
///   and the up, wherever the pointer has got to). The app under the pointer never sees half a click.
/// - Anything outside the rects passes, a mouse-up or drag of a click that wasn't swallowed included.
/// - An event the tap posted itself (marked) always passes, or the replay would be swallowed and replayed for ever.
struct ClickReplayPolicy {
    let rects: [CGRect]
    private var swallowing = false

    init(rects: [CGRect]) {
        self.rects = rects
    }

    mutating func decide(_ kind: ClickKind, at point: CGPoint, isOurs: Bool) -> ClickDecision {
        if isOurs { return .pass }
        switch kind {
        case .leftDown:
            swallowing = rects.contains { $0.contains(point) }
            return swallowing ? .swallow : .pass
        case .leftDragged:
            return swallowing ? .swallow : .pass
        case .leftUp:
            defer { swallowing = false }
            return swallowing ? .swallow : .pass
        }
    }
}

/// The tap's life, as a value: idle until it is started, running until it is stopped (by `stop()` or when its lifetime ends),
/// and stopped for good after that.
///
/// A tap that is on holds every click in the system, so the one rule that matters is that it is never on once it has been
/// stopped, and every decision about switching it on is made here, by the tap, under its lock: at the start, on the tap's thread,
/// and again when the system reports that it switched the tap off. `stop()` marks the phase before it switches the tap off, so a
/// switch-on that comes after a stop finds the phase stopped and doesn't happen, whichever thread got there first.
struct ClickReplayLifecycle: Equatable {
    enum Phase: Equatable { case idle, running, stopped }

    private(set) var phase = Phase.idle

    /// The tap starts. False when it already has, or has been stopped.
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .running
        return true
    }

    /// macOS wouldn't make the tap: it never ran.
    mutating func failed() {
        phase = .stopped
    }

    /// The tap is stopped. True the first time, and that one switches the tap off.
    mutating func stop() -> Bool {
        guard phase != .stopped else { return false }
        phase = .stopped
        return true
    }

    /// Whether the tap's thread may switch the tap on when it starts: only while it runs.
    var mayEnableTap: Bool {
        phase == .running
    }

    /// Whether the tap is switched on again after the system reported it had switched it off (it was too slow, or it was asked
    /// to): only while it runs, and only for those two reports. A tap that was stopped stays off.
    func shouldReenable(after type: CGEventType) -> Bool {
        guard phase == .running else { return false }
        return type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    /// Whether the tap's thread goes on running its loop.
    var keepsRunLoopGoing: Bool {
        phase == .running
    }

    /// Whether the thread goes on after one slice of its loop returned `result`: while the tap runs, and not when the loop has nothing
    /// to wait for (`.finished`: it returns at once, and run again it would return at once, for ever) or was stopped (`.stopped`).
    /// A slice that ran out (`.timedOut`) or handled a source (`.handledSource`) is the ordinary end of one.
    func keepsRunLoopGoing(after result: CFRunLoopRunResult) -> Bool {
        guard keepsRunLoopGoing else { return false }
        return result != .finished && result != .stopped
    }
}

/// What happens to a click that was held, apart from the system: the caller is told on the spot, and the click is posted again a
/// moment later.
///
/// - **`onClick` runs first and before anything is scheduled.** It runs where `hold` is called, which is inside the event tap's
///   callback, so that whatever the caller does about the click (the probe lifts the allowlist) is done before the replay is
///   even queued, and not when the caller next gets round to looking.
/// - **The click is posted again `delay` after,** a down and then an up (`pressDuration` later), and `onReplay` is called right
///   after the down has been posted.
///
/// The scheduler and the posting are given, so that a test can run the sequence without a tap or a clock.
struct ClickReplayer: Sendable {
    typealias Schedule = @Sendable (_ after: Duration, _ work: @escaping @Sendable () -> Void) -> Void
    typealias Post = @Sendable (_ type: CGEventType, _ point: CGPoint, _ flags: CGEventFlags) -> Void

    /// How long the replayed click is held down.
    static let pressDuration: Duration = .milliseconds(30)

    let delay: Duration
    let onClick: @Sendable (CGPoint) -> Void
    let onReplay: @Sendable (CGPoint) -> Void
    let schedule: Schedule
    let post: Post

    func hold(at point: CGPoint, flags: CGEventFlags) {
        onClick(point)
        let post = post
        let onReplay = onReplay
        let schedule = schedule
        schedule(delay) {
            post(.leftMouseDown, point, flags)
            onReplay(point)
            schedule(Self.pressDuration) {
                post(.leftMouseUp, point, flags)
            }
        }
    }
}

public enum ClickReplayError: Error, Equatable, LocalizedError {
    /// macOS wouldn't make the tap: Accessibility isn't granted to Mantel.
    case tapUnavailable

    public var errorDescription: String? {
        "macOS wouldn't let Mantel watch clicks. Check that Accessibility is on for Mantel."
    }
}

/// Holds a click on some part of the menu bar, tells the caller about it, and replays it a moment later.
///
/// This is the fix for the clicks the system ignores while an allowlist is live (the clock, Notification Center): the click
/// is swallowed, the caller lifts the allowlist, and the click is posted again at the same point after `delay`.
///
/// - **Only inside the rects.** An active tap on left-mouse events that passes everything outside `rects` and swallows,
///   from a mouse-down inside them, that one click.
/// - **It always ends.** After `lifetime` (60 seconds at most) or on `stop()`, whichever is first. The timer is a
///   `DispatchSourceTimer` on a queue of its own, so that a busy app can't hold the tap, which holds every click in the
///   system, for longer than it was asked to.
/// - **The tap lives on a thread of its own,** not the main one, so that an app that is busy doesn't stall the event stream.
///   If the system disables it for being slow (`tapDisabledByTimeout`) or asks it to stop (`tapDisabledByUserInput`), it is
///   switched on again, but only while the tap runs (`ClickReplayLifecycle`): after a `stop()` nothing switches it on.
/// - **A click already swallowed is still replayed after `stop()`.** The person clicked, and the click comes back.
public final class ClickReplayTap: Sendable {
    /// Written on every event the tap posts, so that it knows them again ('MNTL').
    static let eventMark: Int64 = 0x4D4E_544C
    public static let maximumLifetime: Duration = .seconds(60)

    static func clamped(lifetime: Duration) -> Duration {
        min(max(lifetime, .zero), maximumLifetime)
    }

    /// How long the tap's thread runs its loop before it asks whether the tap is still wanted. `stop()` also stops the loop, but
    /// a stop that comes before the loop is running has nothing to stop, and this is how long such a stop can go unseen.
    static let runLoopSlice: CFTimeInterval = 0.25

    /// Core Foundation objects that are only handed from the thread that made them to the one that stops them, under the lock.
    private struct Handles: @unchecked Sendable {
        var port: CFMachPort?
        var runLoop: CFRunLoop?
        var timer: (any DispatchSourceTimer)?
    }

    private struct State {
        var lifecycle = ClickReplayLifecycle()
        var policy: ClickReplayPolicy
        var handles = Handles()
    }

    private let delay: Duration
    private let lifetime: Duration
    private let onClick: @Sendable (CGPoint) -> Void
    private let onReplay: @Sendable (CGPoint) -> Void
    private let queue = DispatchQueue(label: "\(Log.subsystem).clickreplay", qos: .userInteractive)
    private let state: Mutex<State>

    /// - Parameters:
    ///   - rects: where clicks are held, in CoreGraphics global points.
    ///   - delay: how long after the click it is replayed.
    ///   - lifetime: how long the tap stays, at most 60 seconds.
    ///   - onClick: called for each click that was held, on the tap's own thread, inside the event callback, before the
    ///     replay is scheduled: so it is what lifts the allowlist, and it should be quick, since every click in the system
    ///     waits for it.
    ///   - onReplay: called, on a queue of the tap's own, right after the replayed mouse-down has been posted.
    public init(rects: [CGRect], delay: Duration, lifetime: Duration, onClick: @escaping @Sendable (CGPoint) -> Void,
                onReplay: @escaping @Sendable (CGPoint) -> Void) {
        self.delay = max(delay, .zero)
        self.lifetime = Self.clamped(lifetime: lifetime)
        self.onClick = onClick
        self.onReplay = onReplay
        state = Mutex(State(policy: ClickReplayPolicy(rects: rects)))
    }

    /// Installs the tap. Throws `ClickReplayError.tapUnavailable` when macOS won't make it.
    public func start() throws {
        guard state.withLock({ $0.lifecycle.begin() }) else { return }

        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        // The tap holds the pointer until the thread has ended; that is when the reference taken here is given back.
        let pointer = Unmanaged.passRetained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: clickReplayCallback, userInfo: pointer) else {
            state.withLock { $0.lifecycle.failed() }
            Unmanaged<ClickReplayTap>.fromOpaque(pointer).release()
            throw ClickReplayError.tapUnavailable
        }
        state.withLock { $0.handles.port = port }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.seconds(lifetime))
        timer.setEventHandler { [self] in stop() }
        state.withLock { $0.handles.timer = timer }
        timer.resume()

        let thread = Thread { [self] in runLoopMain() }
        thread.name = "Mantel click replay"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Removes the tap. It can be called more than once, and from any thread.
    public func stop() {
        // The phase is marked before the tap is switched off, under the lock the switch-on is made under, so a switch-on that comes
        // after this finds it stopped.
        let handles = state.withLock { state -> Handles? in
            guard state.lifecycle.stop() else { return nil }
            let handles = state.handles
            state.handles.timer = nil
            return handles
        }
        guard let handles else { return }
        handles.timer?.cancel()
        if let port = handles.port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoop = handles.runLoop { CFRunLoopStop(runLoop) }
    }

    deinit {
        stop()
    }

    // MARK: The tap's thread

    private func runLoopMain() {
        guard let port = state.withLock({ $0.handles.port }),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            Unmanaged.passUnretained(self).release()
            return
        }
        let runLoop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(runLoop, source, .commonModes)
        // Published and switched on in one step, under the lock and only while the tap runs: a `stop()` that came before this
        // has marked the phase, and finds nothing to switch off, and the tap is never switched on after it.
        let switchedOn = state.withLock { state -> Bool in
            state.handles.runLoop = runLoop
            guard state.lifecycle.mayEnableTap else { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
        if switchedOn {
            // In slices, asking each time whether the tap is still wanted: `CFRunLoopStop` from `stop()` ends a slice, and a
            // stop it couldn't deliver (the loop wasn't running yet) is seen at the end of the slice it fell in.
            // The first slice is run because the tap runs; after each, the result says whether to go on.
            var result = CFRunLoopRunResult.timedOut
            while state.withLock({ $0.lifecycle.keepsRunLoopGoing(after: result) }) {
                result = CFRunLoopRunInMode(.defaultMode, Self.runLoopSlice, true)
            }
        }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
        // The reference `start()` took for the callback.
        Unmanaged.passUnretained(self).release()
    }

    // MARK: Events

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let kind: ClickKind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched the tap off because it was slow or asked to. It is switched on again, under the lock and only
            // while the tap runs: after a `stop()` it stays off.
            state.withLock { state in
                if state.lifecycle.shouldReenable(after: type), let port = state.handles.port {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown: kind = .leftDown
        case .leftMouseUp: kind = .leftUp
        case .leftMouseDragged: kind = .leftDragged
        default: return Unmanaged.passUnretained(event)
        }

        let point = event.location
        let isOurs = event.getIntegerValueField(.eventSourceUserData) == Self.eventMark
        let decision = state.withLock { $0.policy.decide(kind, at: point, isOurs: isOurs) }
        guard decision == .swallow else { return Unmanaged.passUnretained(event) }

        if kind == .leftDown { replayer.hold(at: point, flags: event.flags) }
        return nil
    }

    /// Tells the caller about a held click now, and posts it again, a down and then an up, after `delay`.
    private var replayer: ClickReplayer {
        ClickReplayer(delay: delay, onClick: onClick, onReplay: onReplay,
                      schedule: { [queue] after, work in queue.asyncAfter(deadline: .now() + Self.seconds(after), execute: work) },
                      post: { type, point, flags in Self.post(type, at: point, flags: flags) })
    }

    private static func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: eventMark)
        event.post(tap: .cghidEventTap)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The tap's callback: the pointer given to `tapCreate` is the tap itself.
private func clickReplayCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ClickReplayTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
