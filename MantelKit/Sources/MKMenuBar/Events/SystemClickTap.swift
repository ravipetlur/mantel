import CoreGraphics
import Foundation
import MKCore
import Synchronization

/// What the tap held, so that it can be made again.
enum HeldInput: Sendable, Equatable {
    case click(left: Bool, at: CGPoint)
    case key(UInt16)
}

/// What happens to a click or key that was held, apart from the system: the caller is told on the spot, and the input is made again a
/// moment later.
///
/// - **`onHold` runs first and before anything is scheduled.** It runs where `hold` is called, inside the event tap's callback, so that
///   what the caller does about it (lifts the allowlist) is done before the replay is even queued.
/// - **The input is posted again `delay` after,** a down and then an up (`pressDuration` later), with the flags it had, and
///   `onReplayed` is called right after the down has been posted.
///
/// The scheduler and the posting are given, so that a test can run the sequence without a tap or a clock.
struct SystemInputReplayer: Sendable {
    typealias Schedule = @Sendable (_ after: Duration, _ work: @escaping @Sendable () -> Void) -> Void
    typealias Post = @Sendable (_ held: HeldInput, _ isDown: Bool, _ flags: CGEventFlags) -> Void

    /// How long the replayed input is held down.
    static let pressDuration: Duration = .milliseconds(30)

    let delay: Duration
    let onHold: @Sendable () -> Void
    let onReplayed: @Sendable () -> Void
    let schedule: Schedule
    let post: Post

    func hold(_ held: HeldInput, flags: CGEventFlags) {
        onHold()
        let post = post
        let onReplayed = onReplayed
        let schedule = schedule
        schedule(delay) {
            post(held, true, flags)
            onReplayed()
            schedule(Self.pressDuration) {
                post(held, false, flags)
            }
        }
    }
}

/// Keeps the clock working while the allowlist hides icons: holds a click on it (and the Fn+N shortcut), tells the caller, and makes
/// it again a moment later.
///
/// macOS ignores the clock and Notification Center's shortcut while any allowlist is live. The tap swallows the input, the caller lifts
/// the allowlist in `onHold` (which runs inside the event callback), and the input is posted again `delay` after, marked as the tap's
/// own so that it passes. The caller puts the allowlist back once the panel is closed.
///
/// - **What is held** is decided by `SystemClickPolicy`: a mouse-down inside a target, and Fn+N, while `armed` says an allowlist is live
///   and not lifted. Everything else passes untouched. The tap looks at a key's code and modifier flags and nothing else, and no
///   input is logged.
/// - **`onHold` holds every input in the system while it runs.** It is for one lock and one invalidation, nothing more.
/// - **`onClickOutside`** runs, in the callback, for a click somewhere other than on a target while nothing is armed, which is how the
///   caller knows the person has clicked while a lift is on (on the panel it lifted for, or away from it; the caller decides which
///   it was and what to do). It is called for every such click, so it has to be quick.
/// - **If macOS won't let the tap watch keys,** it watches clicks only: the clock works, and Fn+N is the one thing not covered (logged).
/// - **The tap lives on a thread of its own,** not the main one. If the system switches it off for being slow (`tapDisabledByTimeout`)
///   or asks it to stop (`tapDisabledByUserInput`), it is switched on again, but only while the tap runs (`ClickReplayLifecycle`):
///   after a `stop()` nothing switches it on. A loop with nothing to wait for ends rather than spinning.
/// - **It lasts until `stop()`,** which the owner calls when the allowlist stops being the one that hides icons, and when the app quits.
///   A tap that has been stopped can't be started again: make another.
/// - **An input already swallowed is still replayed after `stop()`.** The person clicked, and the click comes back.
public final class SystemClickTap: Sendable {
    /// Core Foundation objects that are only handed from the thread that made them to the one that stops them, under the lock.
    private struct Handles: @unchecked Sendable {
        var port: CFMachPort?
        var runLoop: CFRunLoop?
    }

    private struct State {
        var lifecycle = ClickReplayLifecycle()
        var policy = SystemClickPolicy()
        var rects: [CGRect] = []
        var handles = Handles()
    }

    private let delay: Duration
    private let armed: @Sendable () -> Bool
    private let onHold: @Sendable () -> Void
    private let onReplayed: @Sendable () -> Void
    private let onClickOutside: @Sendable () -> Void
    private let queue = DispatchQueue(label: "\(Log.subsystem).systemclick", qos: .userInteractive)
    private let state = Mutex(State())

    /// - Parameters:
    ///   - delay: how long after the hold the input is made again.
    ///   - armed: whether an allowlist is live and not lifted; asked, inside the callback, for a mouse-down and for the N key.
    ///   - onHold: called, on the tap's own thread inside the event callback, for each input that was held, before the replay is
    ///     scheduled: it lifts the allowlist.
    ///   - onReplayed: called, on a queue of the tap's own, right after the replayed down has been posted.
    ///   - onClickOutside: called, inside the callback, for a mouse-down somewhere other than on a target while nothing is armed.
    public init(delay: Duration = .milliseconds(100), armed: @escaping @Sendable () -> Bool, onHold: @escaping @Sendable () -> Void,
                onReplayed: @escaping @Sendable () -> Void, onClickOutside: @escaping @Sendable () -> Void) {
        self.delay = max(delay, .zero)
        self.armed = armed
        self.onHold = onHold
        self.onReplayed = onReplayed
        self.onClickOutside = onClickOutside
    }

    /// Where a click is held, CoreGraphics global points. From any thread; the next input is judged against the new places.
    public func setTargets(_ rects: [CGRect]) {
        state.withLock { $0.rects = rects }
    }

    /// Installs the tap. Throws `ClickReplayError.tapUnavailable` when macOS won't make it.
    public func start() throws {
        guard state.withLock({ $0.lifecycle.begin() }) else { return }

        func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }
        let mouse = bit(.leftMouseDown) | bit(.leftMouseUp) | bit(.leftMouseDragged)
            | bit(.rightMouseDown) | bit(.rightMouseUp) | bit(.rightMouseDragged)
        let keys = bit(.keyDown) | bit(.keyUp)
        // The tap holds the pointer until the thread has ended; that is when the reference taken here is given back.
        let pointer = Unmanaged.passRetained(self).toOpaque()
        func makePort(_ mask: CGEventMask) -> CFMachPort? {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                              callback: systemClickCallback, userInfo: pointer)
        }
        var port = makePort(mouse | keys)
        if port == nil {
            // Watching keys can need a permission that watching clicks doesn't. Without it the clock still works, and only the shortcut
            // isn't covered.
            port = makePort(mouse)
            if port != nil { Log.warning("clicks", "macOS wouldn't let Mantel watch keys, so Fn+N isn't covered") }
        }
        guard let port else {
            state.withLock { $0.lifecycle.failed() }
            Unmanaged<SystemClickTap>.fromOpaque(pointer).release()
            throw ClickReplayError.tapUnavailable
        }
        state.withLock { $0.handles.port = port }

        let thread = Thread { [self] in runLoopMain() }
        thread.name = "Mantel system clicks"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Removes the tap. It can be called more than once, and from any thread.
    public func stop() {
        // The phase is marked before the tap is switched off, under the lock the switch-on is made under, so a switch-on that comes
        // after this finds it stopped.
        let handles = state.withLock { state -> Handles? in
            guard state.lifecycle.stop() else { return nil }
            return state.handles
        }
        guard let handles else { return }
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
        // Published and switched on in one step, under the lock and only while the tap runs: a `stop()` that came before this has
        // marked the phase, and finds nothing to switch off, and the tap is never switched on after it.
        let switchedOn = state.withLock { state -> Bool in
            state.handles.runLoop = runLoop
            guard state.lifecycle.mayEnableTap else { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
        if switchedOn {
            // In slices, asking each time whether the tap is still wanted: `CFRunLoopStop` from `stop()` ends a slice, and a stop it
            // couldn't deliver (the loop wasn't running yet) is seen at the end of the slice it fell in. The first slice is run because
            // the tap runs; after each, the result says whether to go on (not when the loop has nothing to wait for: it would return
            // at once, for ever).
            var result = CFRunLoopRunResult.timedOut
            while state.withLock({ $0.lifecycle.keepsRunLoopGoing(after: result) }) {
                result = CFRunLoopRunInMode(.defaultMode, ClickReplayTap.runLoopSlice, true)
            }
        }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
        // The reference `start()` took for the callback.
        Unmanaged.passUnretained(self).release()
    }

    // MARK: Events

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let input: SystemInput
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched the tap off because it was slow or asked to. It is switched on again, under the lock and only while
            // the tap runs: after a `stop()` it stays off.
            state.withLock { state in
                if state.lifecycle.shouldReenable(after: type), let port = state.handles.port {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown: input = .mouseDown(left: true)
        case .rightMouseDown: input = .mouseDown(left: false)
        case .leftMouseUp: input = .mouseUp(left: true)
        case .rightMouseUp: input = .mouseUp(left: false)
        case .leftMouseDragged: input = .mouseDragged(left: true)
        case .rightMouseDragged: input = .mouseDragged(left: false)
        case .keyDown: input = .keyDown
        case .keyUp: input = .keyUp
        default: return Unmanaged.passUnretained(event)
        }

        let keyCode: UInt16? = input.isKey ? UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) : nil
        // Keys that are not the N key are typing, and they go by without a lock being taken.
        if input.isKey, keyCode != SystemClickPolicy.replayKeyCode { return Unmanaged.passUnretained(event) }

        let isOurs = event.getIntegerValueField(.eventSourceUserData) == ClickReplayTap.eventMark
        let isRepeat = input == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        let point = event.location
        // Asked only for what can start a hold.
        let isArmed = input.canStartHold && !isOurs && !isRepeat && armed()

        let verdict = state.withLock { state in
            state.policy.evaluate(input, at: point, keyCode: keyCode, flags: flags, isRepeat: isRepeat, isOurs: isOurs, armed: isArmed,
                                  rects: state.rects)
        }
        if verdict.isClickOutside { onClickOutside() }
        guard verdict.decision == .swallow else { return Unmanaged.passUnretained(event) }

        if verdict.startsHold {
            let held: HeldInput
            switch input {
            case .mouseDown(let left): held = .click(left: left, at: point)
            default: held = .key(SystemClickPolicy.replayKeyCode)
            }
            replayer.hold(held, flags: flags)
        }
        return nil
    }

    /// Tells the caller about a held input now, and posts it again, a down and then an up, after `delay`.
    private var replayer: SystemInputReplayer {
        SystemInputReplayer(delay: delay, onHold: onHold, onReplayed: onReplayed,
                            schedule: { [queue] after, work in queue.asyncAfter(deadline: .now() + Self.seconds(after), execute: work) },
                            post: { held, isDown, flags in Self.post(held, isDown: isDown, flags: flags) })
    }

    private static func post(_ held: HeldInput, isDown: Bool, flags: CGEventFlags) {
        let event: CGEvent?
        switch held {
        case .click(let left, let point):
            let type: CGEventType = switch (left, isDown) {
            case (true, true): .leftMouseDown
            case (true, false): .leftMouseUp
            case (false, true): .rightMouseDown
            case (false, false): .rightMouseUp
            }
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: left ? .left : .right)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        case .key(let code):
            event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: isDown)
        }
        guard let event else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: ClickReplayTap.eventMark)
        event.post(tap: .cghidEventTap)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The tap's callback: the pointer given to `tapCreate` is the tap itself.
private func systemClickCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SystemClickTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
