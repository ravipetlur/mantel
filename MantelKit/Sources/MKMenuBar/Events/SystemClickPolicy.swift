import CoreGraphics

/// One input the system click tap listens to.
enum SystemInput: Sendable, Equatable {
    case mouseDown(left: Bool), mouseUp(left: Bool), mouseDragged(left: Bool), keyDown, keyUp
}

extension SystemInput {
    /// A key event, as opposed to a mouse one.
    var isKey: Bool {
        switch self {
        case .keyDown, .keyUp: true
        case .mouseDown, .mouseUp, .mouseDragged: false
        }
    }

    /// The input that a hold can start with: the tap asks whether an allowlist is armed for these, and for no other.
    var canStartHold: Bool {
        switch self {
        case .mouseDown, .keyDown: true
        case .mouseUp, .mouseDragged, .keyUp: false
        }
    }
}

/// What the policy says about one input.
struct SystemClickVerdict: Sendable, Equatable {
    var decision: ClickDecision
    /// This is the down of a click or key that was swallowed just now: it is the one that is held and replayed. (A swallowed drag, up or
    /// auto-repeat of a key that is held down is part of the same hold, and starts nothing.)
    var startsHold = false
    /// A click was made somewhere other than on a target while nothing is armed. It may be on the panel a lift is for (a notification, a
    /// widget) as well as away from it: the lift's own rules say whether it ends one.
    var isClickOutside = false
}

/// What the system click tap does with each input, as a value that is tested on its own.
///
/// - **Armed** means an allowlist is live and has not been lifted. Only then does anything get held: a mouse-down, left or right, inside
///   a target is swallowed, and so are its drags and its up (wherever the pointer has got to by then). So is the Fn+N key (Globe+N on
///   newer keyboards), and its auto-repeats and its key-up. The app under the pointer never sees half a click.
/// - **Fn+N is key code 45 with the Fn flag and none of ⌘, ⌃, ⌥ or ⇧.** The Fn flag is also set for arrow and function keys on some
///   keyboards, so the key code decides, and any other modifier makes it some other shortcut.
/// - **Not armed,** everything passes: a second click on the clock while a lift is on is an ordinary one.
/// - **An event the tap posted itself (marked) always passes,** or the replay would be swallowed and replayed for ever. It doesn't
///   disturb a click that is being swallowed either.
/// - **Every down starts afresh,** so a hold whose up was lost (the system switched the tap off for a moment) ends with the next down.
struct SystemClickPolicy: Sendable {
    /// The N key.
    static let replayKeyCode: UInt16 = 45

    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    private var swallowingLeft = false
    private var swallowingRight = false
    private var swallowingKey = false

    init() {}

    /// Whether a key down with this key code and these flags is the one that opens Notification Center from the keyboard.
    static func isReplayKey(keyCode: UInt16?, flags: CGEventFlags) -> Bool {
        keyCode == replayKeyCode && flags.contains(.maskSecondaryFn) && flags.isDisjoint(with: otherModifiers)
    }

    /// Whether to swallow `input` or let it pass.
    ///
    /// - Parameters:
    ///   - point: where the pointer is, CoreGraphics global points (for the mouse inputs).
    ///   - keyCode: the key's code (for the key inputs).
    ///   - flags: the modifier flags the event carries.
    ///   - isOurs: the event is one the tap posted itself.
    ///   - armed: an allowlist is live and not lifted.
    ///   - rects: where a click is held.
    mutating func decide(_ input: SystemInput, at point: CGPoint, keyCode: UInt16?, flags: CGEventFlags, isOurs: Bool, armed: Bool,
                         rects: [CGRect]) -> ClickDecision {
        evaluate(input, at: point, keyCode: keyCode, flags: flags, isRepeat: false, isOurs: isOurs, armed: armed, rects: rects).decision
    }

    /// `decide`, with the rest of what the tap needs to know: whether the input starts a hold, and whether it is a click somewhere other
    /// than on a target. `isRepeat` is the key's auto-repeat: a key that is held down is swallowed for as long as its first press was, and
    /// is not held again.
    mutating func evaluate(_ input: SystemInput, at point: CGPoint, keyCode: UInt16?, flags: CGEventFlags, isRepeat: Bool, isOurs: Bool,
                           armed: Bool, rects: [CGRect]) -> SystemClickVerdict {
        if isOurs { return SystemClickVerdict(decision: .pass) }
        switch input {
        case .mouseDown(let left):
            let inside = rects.contains { $0.contains(point) }
            let swallow = armed && inside
            if left { swallowingLeft = swallow } else { swallowingRight = swallow }
            return SystemClickVerdict(decision: swallow ? .swallow : .pass, startsHold: swallow, isClickOutside: !armed && !inside)
        case .mouseDragged(let left):
            return SystemClickVerdict(decision: (left ? swallowingLeft : swallowingRight) ? .swallow : .pass)
        case .mouseUp(let left):
            let swallow = left ? swallowingLeft : swallowingRight
            if left { swallowingLeft = false } else { swallowingRight = false }
            return SystemClickVerdict(decision: swallow ? .swallow : .pass)
        case .keyDown:
            // Only the N key is ever held; any other key neither starts a hold nor ends one.
            guard keyCode == Self.replayKeyCode else { return SystemClickVerdict(decision: .pass) }
            if isRepeat { return SystemClickVerdict(decision: swallowingKey ? .swallow : .pass) }
            let swallow = armed && Self.isReplayKey(keyCode: keyCode, flags: flags)
            swallowingKey = swallow
            return SystemClickVerdict(decision: swallow ? .swallow : .pass, startsHold: swallow)
        case .keyUp:
            guard keyCode == Self.replayKeyCode else { return SystemClickVerdict(decision: .pass) }
            defer { swallowingKey = false }
            return SystemClickVerdict(decision: swallowingKey ? .swallow : .pass)
        }
    }
}
