import MKCore

/// What the menu bar is showing of the icons that are put away.
public enum RevealState: String, Codable, Sendable {
    /// Hidden and Always Hidden are off the bar.
    case collapsed
    /// Hidden is on the bar; Always Hidden isn't.
    case hiddenShown
    /// Hidden and Always Hidden are both on the bar.
    case allShown
    /// Only Mantel, the clock and Control Center are on the bar.
    case focusMode

    /// The reveal that this state asks the visibility plan for. Focus Mode isn't a reveal, it is a layer of its own.
    public var level: RevealLevel {
        switch self {
        case .collapsed, .focusMode: .off
        case .hiddenShown: .hidden
        case .allShown: .all
        }
    }
}

/// Which dot was clicked: • reveals Hidden, •• reveals everything.
public enum DotKind: Sendable, Equatable {
    case hidden
    case always
}

/// What keeps a reveal on the bar, whatever the time: while any of these holds, the icons aren't hidden again.
public struct RehideGuards: Sendable, Equatable {
    /// A menu of an icon on the bar is open.
    public var menuOpen = false
    /// The pointer is in a menu bar.
    public var pointerInBar = false
    /// One of Mantel's own panels is open.
    public var panelOpen = false

    /// Whether any of them holds.
    public var anyActive: Bool { menuOpen || pointerInBar || panelOpen }

    public init(menuOpen: Bool = false, pointerInBar: Bool = false, panelOpen: Bool = false) {
        self.menuOpen = menuOpen
        self.pointerInBar = pointerInBar
        self.panelOpen = panelOpen
    }
}

/// The two waits the machine asks for.
public enum RevealTimer: Sendable, Hashable {
    /// The pointer resting in empty space before a hover reveals.
    case hover
    /// The time after a reveal before the icons are hidden again.
    case rehide
}

/// Everything that can happen to the reveal.
public enum RevealEvent: Sendable, Equatable {
    case dotClicked(DotKind)
    case pointerEnteredEmptySpace
    case pointerLeftEmptySpace
    case emptySpaceClicked
    /// The pointer scrolled on the bar: down reveals, up hides.
    case scrolled(down: Bool)
    /// A command: shows that much, whatever is on the bar now (`.off` hides it all). It leaves Focus Mode.
    case show(RevealLevel)
    /// A hotkey: `.hidden` or `.all`. It shows that much, or hides it all if that much is already showing.
    case toggle(RevealLevel)
    case setFocusMode(Bool)
    case toggleFocusMode
    case guardsChanged(RehideGuards)
    /// The inventory shows the reveal on the bar.
    case revealConfirmed
    case timerFired(RevealTimer)
    case settingsChanged(RevealSettings)
}

/// What the machine asks the world to do.
public enum RevealEffect: Sendable, Equatable {
    /// The state changed: the visibility plan is built again.
    case stateChanged(RevealState)
    /// Starts the timer, or starts it again from the full time if it is running.
    case startTimer(RevealTimer, Duration)
    case cancelTimer(RevealTimer)
    /// A reveal began: check whether the revealed icons all have room. Nothing acts on this one: the follow-up of a reveal checks the room
    /// as a part of it (`MenuBarSession.setReveal`), and the app takes the effect as a no-op (`RevealController`). It stays as the machine's
    /// statement of when a reveal begins (once, and after the rest of what it asks), which the tests of the machine pin, and which an
    /// effect to be acted on can come from.
    case checkRoom
}

/// The pure part of revealing: which of the icons that are put away are on the bar. A value that takes events and says what to do;
/// it keeps no time, so what it asks of a timer is carried out by whoever owns the timers (`RevealDriver`).
///
/// - **Dots.** • reveals Hidden, or hides it again if it is showing; •• does the same for everything. Either dot leaves Focus Mode.
/// - **Empty space,** each off until Settings turns it on. Hover: the pointer rests in empty space of a hidden bar for the hover
///   delay. Click: toggles the reveal. Scroll: down reveals Hidden, up hides a reveal. None of them does anything in Focus Mode.
/// - **Commands and hotkeys** set the state directly, and leave Focus Mode.
/// - **Rehide.** A reveal is hidden again after the rehide delay, counted from the start of the reveal and from the moment every
///   guard (an open menu, the pointer in a bar, an open panel of Mantel's) is clear. A guard that comes on stops the countdown; the
///   next one counts the full delay. With `confirmationGatesRehide` the countdown starts only once the reveal is confirmed on the bar.
///   A change of the delay is for the next countdown, but never stops the one that is running.
public struct RevealMachine: Sendable, Equatable {
    public private(set) var state: RevealState = .collapsed

    private var settings: RevealSettings
    private let confirmationGatesRehide: Bool
    private var guards = RehideGuards()
    /// Whether the reveal now showing has been seen on the bar.
    private var isConfirmed = false
    // The timers the machine has asked to run and not yet cancelled or heard from.
    private var isHoverRunning = false
    private var isRehideRunning = false

    /// - Parameter confirmationGatesRehide: whether the rehide countdown waits for `revealConfirmed`. Off, the countdown starts when
    ///   the reveal does, and an event that never comes can't stop it.
    public init(settings: RevealSettings, confirmationGatesRehide: Bool = false) {
        self.settings = settings
        self.confirmationGatesRehide = confirmationGatesRehide
    }

    public mutating func handle(_ event: RevealEvent) -> [RevealEffect] {
        var effects: [RevealEffect] = []
        switch event {
        case .dotClicked(.hidden):
            move(to: state == .collapsed ? .hiddenShown : .collapsed, &effects)
        case .dotClicked(.always):
            switch state {
            case .collapsed, .hiddenShown: move(to: .allShown, &effects)
            case .allShown, .focusMode: move(to: .collapsed, &effects)
            }

        case .pointerEnteredEmptySpace:
            if state == .collapsed, settings.hoverReveals, !isHoverRunning {
                isHoverRunning = true
                effects.append(.startTimer(.hover, .milliseconds(settings.hoverDelayMilliseconds)))
            }
        case .pointerLeftEmptySpace:
            cancelHover(&effects)
        case .emptySpaceClicked:
            guard settings.clickReveals else { break }
            switch state {
            case .collapsed: move(to: .hiddenShown, &effects)
            case .hiddenShown, .allShown: move(to: .collapsed, &effects)
            case .focusMode: break
            }
        case .scrolled(down: true):
            if settings.scrollReveals, state == .collapsed { move(to: .hiddenShown, &effects) }
        case .scrolled(down: false):
            if settings.scrollReveals, state.isRevealed { move(to: .collapsed, &effects) }

        case .show(let level):
            let target = RevealState(showing: level)
            if target == state {
                // Asked for again, what is showing stays and its countdown starts over.
                if state.isRevealed { restartRehide(&effects) }
            } else {
                move(to: target, &effects)
            }
        case .toggle(.hidden):
            move(to: state == .hiddenShown ? .collapsed : .hiddenShown, &effects)
        case .toggle(.all):
            move(to: state == .allShown ? .collapsed : .allShown, &effects)
        case .toggle(.off):
            break

        case .setFocusMode(let on):
            if on, state != .focusMode {
                move(to: .focusMode, &effects)
            } else if !on, state == .focusMode {
                move(to: .collapsed, &effects)
            }
        case .toggleFocusMode:
            move(to: state == .focusMode ? .collapsed : .focusMode, &effects)

        case .guardsChanged(let new):
            guards = new
            reconcileRehide(&effects)
        case .revealConfirmed:
            if confirmationGatesRehide, state.isRevealed, !isConfirmed {
                isConfirmed = true
                reconcileRehide(&effects)
            }
        case .timerFired(.hover):
            isHoverRunning = false
            if state == .collapsed, settings.hoverReveals { move(to: .hiddenShown, &effects) }
        case .timerFired(.rehide):
            isRehideRunning = false
            // A guard that came on has cancelled the timer; a fire that gets here anyway is one that was already on its way.
            if state.isRevealed, !guards.anyActive { move(to: .collapsed, &effects) }

        case .settingsChanged(let new):
            settings = new
            // A hover that is running goes on until it is over, unless hover is off now. A new rehide delay is for the next start,
            // except never: the person has just said the icons are to stay, so a countdown that is running is stopped.
            if !new.hoverReveals { cancelHover(&effects) }
            if new.rehide == .never { cancelRehide(&effects) }
        }
        return effects
    }

    // MARK: Moving

    /// Takes the new state, if it is another one, and what comes with it: any hover is over; the countdown stops, or starts over for
    /// a reveal; a reveal asks for a check of the room.
    private mutating func move(to new: RevealState, _ effects: inout [RevealEffect]) {
        guard new != state else { return }
        state = new
        isConfirmed = false
        effects.append(.stateChanged(new))
        cancelHover(&effects)
        if new.isRevealed {
            restartRehide(&effects)
            effects.append(.checkRoom)
        } else {
            cancelRehide(&effects)
        }
    }

    // MARK: Timers

    private mutating func cancelHover(_ effects: inout [RevealEffect]) {
        guard isHoverRunning else { return }
        isHoverRunning = false
        effects.append(.cancelTimer(.hover))
    }

    private mutating func cancelRehide(_ effects: inout [RevealEffect]) {
        guard isRehideRunning else { return }
        isRehideRunning = false
        effects.append(.cancelTimer(.rehide))
    }

    /// Whether the countdown may run now: a reveal is showing, no guard holds, and, if it waits for it, the reveal is confirmed.
    private var mayRehide: Bool {
        state.isRevealed && !guards.anyActive && (!confirmationGatesRehide || isConfirmed)
    }

    /// Starts the countdown from the full delay if it may run, and otherwise stops it. A delay of never doesn't start one.
    private mutating func restartRehide(_ effects: inout [RevealEffect]) {
        guard mayRehide, case .seconds(let seconds) = settings.rehide else {
            cancelRehide(&effects)
            return
        }
        isRehideRunning = true
        effects.append(.startTimer(.rehide, .seconds(seconds)))
    }

    /// After a guard or a confirmation changed: starts the countdown if it may run and isn't, stops it if it runs and may not.
    /// A countdown that is running isn't started over.
    private mutating func reconcileRehide(_ effects: inout [RevealEffect]) {
        if !mayRehide {
            cancelRehide(&effects)
        } else if !isRehideRunning {
            restartRehide(&effects)
        }
    }
}

extension RevealMachine {
    /// The machine the app runs. Seeing a reveal on the bar is advisory: the bar's own frames often miss a change that did happen, so
    /// the rehide countdown starts with the reveal and never waits for `revealConfirmed`.
    public static func live(settings: RevealSettings) -> RevealMachine {
        RevealMachine(settings: settings, confirmationGatesRehide: false)
    }
}

extension RevealState {
    /// The state that a command to show `level` ends in.
    fileprivate init(showing level: RevealLevel) {
        switch level {
        case .off: self = .collapsed
        case .hidden: self = .hiddenShown
        case .all: self = .allShown
        }
    }

    /// Whether Hidden is on the bar.
    fileprivate var isRevealed: Bool { self == .hiddenShown || self == .allShown }
}
