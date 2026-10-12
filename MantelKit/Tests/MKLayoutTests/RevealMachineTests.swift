import MKCore
import Testing

@testable import MKLayout

// MARK: Fixtures

/// Reveal settings with only what a test turns on.
private func settings(hover: Bool = false, click: Bool = false, scroll: Bool = false, hoverDelay: Int = 300,
                      rehide: RehideDelay = .seconds(10)) -> RevealSettings {
    RevealSettings(hoverReveals: hover, clickReveals: click, scrollReveals: scroll, hoverDelayMilliseconds: hoverDelay, rehide: rehide)
}

private let everythingOn = settings(hover: true, click: true, scroll: true)

/// A machine that has reached `state` by the events that lead there (what they said is dropped), with a rehide of 10 seconds unless
/// the settings say another.
private func makeMachine(in state: RevealState, _ settings: RevealSettings = everythingOn, gated: Bool = false) -> RevealMachine {
    var machine = RevealMachine(settings: settings, confirmationGatesRehide: gated)
    switch state {
    case .collapsed: break
    case .hiddenShown: _ = machine.handle(.show(.hidden))
    case .allShown: _ = machine.handle(.show(.all))
    case .focusMode: _ = machine.handle(.setFocusMode(true))
    }
    return machine
}

private let allStates: [RevealState] = [.collapsed, .hiddenShown, .allShown, .focusMode]

private let tenSeconds = RevealEffect.startTimer(.rehide, .seconds(10))

// MARK: The table

/// One row of the transition table: the state that each starting state ends in, in the order collapsed, hiddenShown, allShown,
/// focusMode. A nil is a pair that isn't listed: nothing changes, and nothing is asked for.
private struct TableRow: Sendable {
    let event: RevealEvent
    let ends: [RevealState?]
}

struct RevealTableCase: Sendable, CustomTestStringConvertible {
    let start: RevealState
    let event: RevealEvent
    let end: RevealState?

    var testDescription: String { "\(event) in \(start) -> \(end.map { "\($0)" } ?? "no change")" }
}

// The settings have hover, click and scroll on: the rows that say "(on)" are the ones in this table.
private let rows: [TableRow] = [
    TableRow(event: .dotClicked(.hidden), ends: [.hiddenShown, .collapsed, .collapsed, .collapsed]),
    TableRow(event: .dotClicked(.always), ends: [.allShown, .allShown, .collapsed, .collapsed]),
    TableRow(event: .timerFired(.hover), ends: [.hiddenShown, nil, nil, nil]),
    TableRow(event: .emptySpaceClicked, ends: [.hiddenShown, .collapsed, .collapsed, nil]),
    TableRow(event: .scrolled(down: true), ends: [.hiddenShown, nil, nil, nil]),
    TableRow(event: .scrolled(down: false), ends: [nil, .collapsed, .collapsed, nil]),
    TableRow(event: .show(.hidden), ends: [.hiddenShown, .hiddenShown, .hiddenShown, .hiddenShown]),
    TableRow(event: .show(.all), ends: [.allShown, .allShown, .allShown, .allShown]),
    TableRow(event: .show(.off), ends: [.collapsed, .collapsed, .collapsed, .collapsed]),
    TableRow(event: .toggle(.hidden), ends: [.hiddenShown, .collapsed, .hiddenShown, .hiddenShown]),
    TableRow(event: .toggle(.all), ends: [.allShown, .allShown, .collapsed, .allShown]),
    // Not a hotkey there is: toggling "nothing" does nothing.
    TableRow(event: .toggle(.off), ends: [nil, nil, nil, nil]),
    TableRow(event: .setFocusMode(true), ends: [.focusMode, .focusMode, .focusMode, nil]),
    TableRow(event: .setFocusMode(false), ends: [nil, nil, nil, .collapsed]),
    TableRow(event: .toggleFocusMode, ends: [.focusMode, .focusMode, .focusMode, .collapsed]),
    TableRow(event: .timerFired(.rehide), ends: [nil, .collapsed, .collapsed, nil]),
]

private let tableCases: [RevealTableCase] = rows.flatMap { row in
    zip(allStates, row.ends).map { RevealTableCase(start: $0, event: row.event, end: $1) }
}

/// Events that are about something other than the state: whatever state the machine is in, they leave it where it is.
private let eventsThatDontMoveTheState: [RevealEvent] = [
    .pointerEnteredEmptySpace,
    .pointerLeftEmptySpace,
    .guardsChanged(RehideGuards(menuOpen: true)),
    .guardsChanged(RehideGuards(pointerInBar: true)),
    .guardsChanged(RehideGuards(panelOpen: true)),
    .guardsChanged(RehideGuards()),
    .revealConfirmed,
    .settingsChanged(RevealSettings()),
    .settingsChanged(settings(hover: true, click: true, scroll: true, hoverDelay: 800, rehide: .never)),
]

struct RevealStateAndEvent: Sendable, CustomTestStringConvertible {
    let state: RevealState
    let event: RevealEvent
    var testDescription: String { "\(event) in \(state)" }
}

private let stateAndEventCases: [RevealStateAndEvent] = allStates.flatMap { state in
    eventsThatDontMoveTheState.map { RevealStateAndEvent(state: state, event: $0) }
}

// MARK: Tests

@Suite("Reveal machine", .timeLimit(.minutes(1)))
struct RevealMachineTests {
    @Test(arguments: tableCases) func transitionTable(_ row: RevealTableCase) {
        var machine = makeMachine(in: row.start)
        let before = machine
        let effects = machine.handle(row.event)

        guard let end = row.end else {
            // A pair that isn't listed changes nothing and asks for nothing.
            #expect(machine.state == row.start)
            #expect(effects.isEmpty)
            #expect(machine == before)
            return
        }
        #expect(machine.state == end)
        let moved = end != row.start
        if moved { #expect(effects.first == .stateChanged(end)) }
        #expect(effects.contains(.stateChanged(end)) == moved)
        #expect(effects.count(where: { if case .stateChanged = $0 { true } else { false } }) == (moved ? 1 : 0))
        // A reveal asks for a look at the room; nothing else does.
        #expect(effects.contains(.checkRoom) == (moved && (end == .hiddenShown || end == .allShown)))
    }

    @Test(arguments: stateAndEventCases) func otherEventsNeverMoveTheState(_ row: RevealStateAndEvent) {
        var machine = makeMachine(in: row.state)
        _ = machine.handle(row.event)
        #expect(machine.state == row.state)
    }

    @Test func statesAskForTheRevealTheyShow() {
        #expect(RevealState.collapsed.level == .off)
        #expect(RevealState.focusMode.level == .off)
        #expect(RevealState.hiddenShown.level == .hidden)
        #expect(RevealState.allShown.level == .all)
        #expect(RevealMachine(settings: everythingOn).state == .collapsed)
    }

    @Test func guardsAreAnyOfThree() {
        #expect(!RehideGuards().anyActive)
        #expect(RehideGuards(menuOpen: true).anyActive)
        #expect(RehideGuards(pointerInBar: true).anyActive)
        #expect(RehideGuards(panelOpen: true).anyActive)
        #expect(RehideGuards(menuOpen: true, pointerInBar: true, panelOpen: true).anyActive)
    }

    // MARK: Hover

    @Test func hoverStartsOnlyWhenEnabled() {
        // Off, the pointer resting in empty space asks for nothing.
        var off = makeMachine(in: .collapsed, settings(click: true, scroll: true))
        #expect(off.handle(.pointerEnteredEmptySpace).isEmpty)

        // On, it starts the hover timer for the hover delay the settings give.
        var on = makeMachine(in: .collapsed, settings(hover: true, hoverDelay: 500))
        #expect(on.handle(.pointerEnteredEmptySpace) == [.startTimer(.hover, .milliseconds(500))])
        // The pointer going on resting is the same hover, not a new one.
        #expect(on.handle(.pointerEnteredEmptySpace).isEmpty)
        // When the timer is up the icons are revealed, and the countdown to hide them again starts.
        #expect(on.handle(.timerFired(.hover)) == [.stateChanged(.hiddenShown), tenSeconds, .checkRoom])
        #expect(on.state == .hiddenShown)

        // It is only a hidden bar that a hover reveals.
        for state in [RevealState.hiddenShown, .allShown, .focusMode] {
            var shown = makeMachine(in: state, settings(hover: true))
            #expect(shown.handle(.pointerEnteredEmptySpace).isEmpty, "hover starts nothing in \(state)")
        }

        // Hover turned on after the machine was made counts; the timer of a hover that is off when it fires reveals nothing.
        var later = makeMachine(in: .collapsed, settings())
        _ = later.handle(.settingsChanged(settings(hover: true)))
        #expect(later.handle(.pointerEnteredEmptySpace) == [.startTimer(.hover, .milliseconds(300))])
        var stale = makeMachine(in: .collapsed, settings(click: true))
        #expect(stale.handle(.timerFired(.hover)).isEmpty)
        #expect(stale.state == .collapsed)
    }

    @Test func pointerLeftBeforeDelayCancelsHover() {
        var machine = makeMachine(in: .collapsed, settings(hover: true))
        _ = machine.handle(.pointerEnteredEmptySpace)

        // The pointer leaves before the delay is up: the timer is cancelled, and the bar stays as it was.
        #expect(machine.handle(.pointerLeftEmptySpace) == [.cancelTimer(.hover)])
        #expect(machine.state == .collapsed)
        // Nothing runs now, so leaving again says nothing.
        #expect(machine.handle(.pointerLeftEmptySpace).isEmpty)
        // Coming back starts a new hover, with the full delay.
        #expect(machine.handle(.pointerEnteredEmptySpace) == [.startTimer(.hover, .milliseconds(300))])

        // Leaving without having come in is nothing to cancel.
        var fresh = RevealMachine(settings: settings(hover: true))
        #expect(fresh.handle(.pointerLeftEmptySpace).isEmpty)
    }

    @Test func hoverOffCancelsRunningHover() {
        var machine = makeMachine(in: .collapsed, settings(hover: true, click: true))
        _ = machine.handle(.pointerEnteredEmptySpace)

        // Turned off while it runs: the timer is cancelled, and a click still counts as it did.
        #expect(machine.handle(.settingsChanged(settings(click: true))) == [.cancelTimer(.hover)])
        #expect(machine.state == .collapsed)
        #expect(machine.handle(.pointerEnteredEmptySpace).isEmpty)
        // With none running, turning it off says nothing; turning it on starts nothing by itself.
        #expect(machine.handle(.settingsChanged(settings(click: true))).isEmpty)
        #expect(machine.handle(.settingsChanged(settings(hover: true, click: true))).isEmpty)

        // A hover that goes on has the delay it started with; the new delay is for the next one.
        var running = RevealMachine(settings: settings(hover: true, hoverDelay: 100))
        _ = running.handle(.pointerEnteredEmptySpace)
        #expect(running.handle(.settingsChanged(settings(hover: true, hoverDelay: 800))).isEmpty)
        _ = running.handle(.pointerLeftEmptySpace)
        #expect(running.handle(.pointerEnteredEmptySpace) == [.startTimer(.hover, .milliseconds(800))])
    }

    @Test func dotClickWhileHoverRunsCancelsTheHover() {
        for (dot, end) in [(DotKind.hidden, RevealState.hiddenShown), (.always, .allShown)] {
            var machine = makeMachine(in: .collapsed, settings(hover: true))
            _ = machine.handle(.pointerEnteredEmptySpace)
            // The click decides; the hover that was running is over before it can reveal anything.
            #expect(machine.handle(.dotClicked(dot)) == [.stateChanged(end), .cancelTimer(.hover), tenSeconds, .checkRoom])
            #expect(machine.state == end)
            #expect(machine.handle(.pointerLeftEmptySpace).isEmpty)
        }
    }

    // MARK: Click, scroll and Focus Mode

    @Test func clickAndScrollIgnoredWhenOff() {
        for state in allStates {
            var allOff = makeMachine(in: state, settings())
            let before = allOff
            for event in [RevealEvent.emptySpaceClicked, .scrolled(down: true), .scrolled(down: false), .pointerEnteredEmptySpace] {
                #expect(allOff.handle(event).isEmpty, "\(event) in \(state) with everything off")
            }
            #expect(allOff == before)

            // Each does what it is for, and only when it is on itself.
            var clickOnly = makeMachine(in: state, settings(click: true))
            #expect(clickOnly.handle(.scrolled(down: true)).isEmpty)
            #expect(clickOnly.handle(.scrolled(down: false)).isEmpty)
            var scrollOnly = makeMachine(in: state, settings(scroll: true))
            #expect(scrollOnly.handle(.emptySpaceClicked).isEmpty)
        }
        var clickOnly = RevealMachine(settings: settings(click: true))
        #expect(clickOnly.handle(.emptySpaceClicked) == [.stateChanged(.hiddenShown), tenSeconds, .checkRoom])
        var scrollOnly = RevealMachine(settings: settings(scroll: true))
        #expect(scrollOnly.handle(.scrolled(down: true)) == [.stateChanged(.hiddenShown), tenSeconds, .checkRoom])
        #expect(scrollOnly.handle(.scrolled(down: false)) == [.stateChanged(.collapsed), .cancelTimer(.rehide)])
    }

    @Test func focusModeIgnoresEmptySpaceAndScroll() {
        var machine = makeMachine(in: .focusMode)
        let before = machine
        for event in [RevealEvent.pointerEnteredEmptySpace, .pointerLeftEmptySpace, .emptySpaceClicked, .scrolled(down: true),
                      .scrolled(down: false), .timerFired(.hover), .timerFired(.rehide)] {
            #expect(machine.handle(event).isEmpty, "\(event) in Focus Mode")
        }
        #expect(machine == before)
        #expect(machine.state == .focusMode)
    }

    @Test func eitherDotExitsFocusMode() {
        for dot in [DotKind.hidden, .always] {
            var machine = makeMachine(in: .focusMode)
            #expect(machine.handle(.dotClicked(dot)) == [.stateChanged(.collapsed)], "the \(dot) dot in Focus Mode")
            #expect(machine.state == .collapsed)
        }
    }

    @Test func showExitsFocusMode() {
        let cases: [(RevealLevel, RevealState, [RevealEffect])] = [
            (.hidden, .hiddenShown, [.stateChanged(.hiddenShown), tenSeconds, .checkRoom]),
            (.all, .allShown, [.stateChanged(.allShown), tenSeconds, .checkRoom]),
            (.off, .collapsed, [.stateChanged(.collapsed)]),
        ]
        for (level, end, effects) in cases {
            var machine = makeMachine(in: .focusMode)
            #expect(machine.handle(.show(level)) == effects, "show \(level) in Focus Mode")
            #expect(machine.state == end)
        }
        // A hotkey leaves it as well.
        for level in [RevealLevel.hidden, .all] {
            var machine = makeMachine(in: .focusMode)
            _ = machine.handle(.toggle(level))
            #expect(machine.state != .focusMode)
        }
        // Focus Mode set on a reveal ends the countdown to hide it, and what it asks for is nothing more.
        var shown = makeMachine(in: .hiddenShown)
        #expect(shown.handle(.setFocusMode(true)) == [.stateChanged(.focusMode), .cancelTimer(.rehide)])
    }

    @Test func showingWhatIsShowingStartsTheCountdownAgain() {
        var machine = makeMachine(in: .hiddenShown)
        // The icons are on the bar already: no state changes and no room to check, but the reveal counts from now.
        #expect(machine.handle(.show(.hidden)) == [tenSeconds])
        #expect(machine.state == .hiddenShown)
        // The same with a guard holding: nothing runs, so nothing starts.
        _ = machine.handle(.guardsChanged(RehideGuards(menuOpen: true)))
        #expect(machine.handle(.show(.hidden)).isEmpty)
        // Hiding what is hidden is nothing.
        var collapsed = RevealMachine(settings: everythingOn)
        #expect(collapsed.handle(.show(.off)).isEmpty)
    }

    // MARK: Rehide

    @Test func rehideRunsOnlyWhileGuardsClear() {
        let guards = [RehideGuards(menuOpen: true), RehideGuards(pointerInBar: true), RehideGuards(panelOpen: true)]
        for held in guards {
            for level in [RevealLevel.hidden, .all] {
                var machine = RevealMachine(settings: settings())
                // A guard that holds when the reveal begins keeps the countdown from starting; clearing it starts it.
                #expect(machine.handle(.guardsChanged(held)).isEmpty, "guards set while the bar is collapsed")
                let entered = machine.handle(.show(level))
                #expect(!entered.contains(tenSeconds), "no countdown while \(held) holds")
                #expect(entered.contains(.checkRoom))
                #expect(machine.handle(.guardsChanged(RehideGuards())) == [tenSeconds])
                // A guard that comes on stops it.
                #expect(machine.handle(.guardsChanged(held)) == [.cancelTimer(.rehide)])
            }
        }

        // The countdown waits for every guard: one that clears while another holds starts nothing.
        var machine = makeMachine(in: .hiddenShown)
        #expect(machine.handle(.guardsChanged(RehideGuards(menuOpen: true))) == [.cancelTimer(.rehide)])
        #expect(machine.handle(.guardsChanged(RehideGuards(menuOpen: true, pointerInBar: true))).isEmpty)
        #expect(machine.handle(.guardsChanged(RehideGuards(pointerInBar: true))).isEmpty)
        #expect(machine.handle(.guardsChanged(RehideGuards())) == [tenSeconds])

        // A rehide that fires while a guard holds is one that was already on its way when the guard came on: it hides nothing.
        _ = machine.handle(.guardsChanged(RehideGuards(menuOpen: true)))
        #expect(machine.handle(.timerFired(.rehide)).isEmpty)
        #expect(machine.state == .hiddenShown)
        // When the guard clears there is a countdown again.
        #expect(machine.handle(.guardsChanged(RehideGuards())) == [tenSeconds])
    }

    @Test func guardClearingRestartsFullDelay() {
        var machine = makeMachine(in: .hiddenShown, settings(rehide: .seconds(30)))
        // Moving on to the other reveal starts the countdown again as well, from the full delay.
        #expect(machine.handle(.dotClicked(.always)) == [.stateChanged(.allShown), .startTimer(.rehide, .seconds(30)), .checkRoom])

        // A guard comes on part way through and clears: the full 30 seconds again, whatever was left.
        #expect(machine.handle(.guardsChanged(RehideGuards(panelOpen: true))) == [.cancelTimer(.rehide)])
        #expect(machine.handle(.guardsChanged(RehideGuards())) == [.startTimer(.rehide, .seconds(30))])
        // The same guards said again don't start a countdown that is running over.
        #expect(machine.handle(.guardsChanged(RehideGuards())).isEmpty)
        // The countdown that fires hides the reveal.
        #expect(machine.handle(.timerFired(.rehide)) == [.stateChanged(.collapsed)])
    }

    @Test func rehideNeverWhenNever() {
        var machine = RevealMachine(settings: settings(rehide: .never))
        #expect(machine.handle(.show(.hidden)) == [.stateChanged(.hiddenShown), .checkRoom])
        #expect(machine.handle(.guardsChanged(RehideGuards(menuOpen: true))).isEmpty)
        #expect(machine.handle(.guardsChanged(RehideGuards())).isEmpty)
        #expect(machine.handle(.show(.hidden)).isEmpty)
        #expect(machine.handle(.dotClicked(.always)) == [.stateChanged(.allShown), .checkRoom])
        // With nothing running there is nothing to cancel on the way out.
        #expect(machine.handle(.dotClicked(.always)) == [.stateChanged(.collapsed)])
    }

    @Test func rehideDelayChangeAppliesFromTheNextStart() {
        var machine = makeMachine(in: .hiddenShown, settings(rehide: .seconds(10)))
        // The countdown that runs is the one that was started; the new delay isn't a start.
        #expect(machine.handle(.settingsChanged(settings(rehide: .seconds(30)))).isEmpty)
        #expect(machine.handle(.show(.hidden)) == [.startTimer(.rehide, .seconds(30))])
        // A reveal that began under never gets no countdown from the change either.
        var never = RevealMachine(settings: settings(rehide: .never))
        _ = never.handle(.show(.hidden))
        #expect(never.handle(.settingsChanged(settings(rehide: .seconds(5)))).isEmpty)
        _ = never.handle(.dotClicked(.hidden))
        #expect(never.handle(.dotClicked(.hidden)) == [.stateChanged(.hiddenShown), .startTimer(.rehide, .seconds(5)), .checkRoom])
    }

    @Test func switchingToNeverStopsTheCountdown() {
        // A countdown is running; the person chooses never: the icons are to stay, so it is stopped, and nothing starts it again.
        var machine = makeMachine(in: .hiddenShown, settings(rehide: .seconds(10)))
        #expect(machine.handle(.settingsChanged(settings(rehide: .never))) == [.cancelTimer(.rehide)])
        #expect(machine.state == .hiddenShown)
        // Nothing asks for another countdown: not a guard that clears, and not a reveal asked for again.
        #expect(machine.handle(.guardsChanged(RehideGuards())).isEmpty)
        #expect(machine.handle(.show(.hidden)).isEmpty)

        // With no countdown running there is nothing to stop.
        var idle = makeMachine(in: .collapsed, settings(rehide: .seconds(10)))
        #expect(idle.handle(.settingsChanged(settings(rehide: .never))).isEmpty)

        // A guard holds the countdown, so none is running: nothing to stop either.
        var held = makeMachine(in: .hiddenShown, settings(rehide: .seconds(10)))
        _ = held.handle(.guardsChanged(RehideGuards(menuOpen: true)))
        #expect(held.handle(.settingsChanged(settings(rehide: .never))).isEmpty)

        // Switching to another number is not a stop.
        var seconds = makeMachine(in: .allShown, settings(rehide: .seconds(10)))
        #expect(seconds.handle(.settingsChanged(settings(rehide: .seconds(5)))).isEmpty)
    }

    @Test func collapsingStopsTheCountdown() {
        for end in [RevealState.collapsed, .focusMode] {
            var machine = makeMachine(in: .allShown)
            let effects = machine.handle(end == .collapsed ? .dotClicked(.always) : .setFocusMode(true))
            #expect(effects == [.stateChanged(end), .cancelTimer(.rehide)])
        }
        // The timer that has fired is over: collapsing then has nothing to cancel.
        var fired = makeMachine(in: .hiddenShown)
        #expect(fired.handle(.timerFired(.rehide)) == [.stateChanged(.collapsed)])
    }

    @Test func confirmationGatesRehideWhenSet() {
        var machine = makeMachine(in: .collapsed, gated: true)
        // The reveal isn't on the bar yet as far as anyone knows: no countdown.
        #expect(machine.handle(.show(.hidden)) == [.stateChanged(.hiddenShown), .checkRoom])
        #expect(machine.handle(.revealConfirmed) == [tenSeconds])
        // Said again, it starts nothing over.
        #expect(machine.handle(.revealConfirmed).isEmpty)

        // The other reveal has to be confirmed in its turn: the first confirmation was of the first one.
        #expect(machine.handle(.dotClicked(.always)) == [.stateChanged(.allShown), .cancelTimer(.rehide), .checkRoom])
        #expect(machine.handle(.revealConfirmed) == [tenSeconds])

        // A confirmation that comes while a guard holds is kept until the guards clear.
        #expect(machine.handle(.guardsChanged(RehideGuards(pointerInBar: true))) == [.cancelTimer(.rehide)])
        _ = machine.handle(.dotClicked(.always))
        _ = machine.handle(.dotClicked(.hidden))
        #expect(machine.handle(.revealConfirmed).isEmpty)
        #expect(machine.handle(.guardsChanged(RehideGuards())) == [tenSeconds])

        // Confirmed means nothing when nothing is revealed.
        var collapsed = RevealMachine(settings: everythingOn, confirmationGatesRehide: true)
        #expect(collapsed.handle(.revealConfirmed).isEmpty)
        _ = collapsed.handle(.show(.hidden))
        _ = collapsed.handle(.show(.off))
        #expect(collapsed.handle(.revealConfirmed).isEmpty)
    }

    @Test func rehideRunsWithoutConfirmationWhenNotGated() {
        // Not gated, which is how Mantel runs: the countdown starts with the reveal, and no confirmation is waited for.
        var machine = RevealMachine(settings: settings())
        #expect(machine.handle(.show(.hidden)) == [.stateChanged(.hiddenShown), tenSeconds, .checkRoom])
        // A confirmation that never arrives changes nothing, and one that does arrive isn't a start either.
        #expect(machine.handle(.revealConfirmed).isEmpty)
        #expect(machine.handle(.timerFired(.rehide)) == [.stateChanged(.collapsed)])
        // The default is not gated.
        var byDefault = RevealMachine(settings: settings())
        #expect(byDefault.handle(.dotClicked(.always)).contains(tenSeconds))
    }

    // MARK: Checking the room

    @Test func revealEmitsCheckRoom() {
        // Every way into a reveal asks for the room to be looked at, once.
        let ways: [(String, RevealState, RevealEvent)] = [
            ("the • dot", .collapsed, .dotClicked(.hidden)),
            ("the •• dot", .collapsed, .dotClicked(.always)),
            ("the •• dot over Hidden", .hiddenShown, .dotClicked(.always)),
            ("a hover", .collapsed, .timerFired(.hover)),
            ("a click", .collapsed, .emptySpaceClicked),
            ("a scroll", .collapsed, .scrolled(down: true)),
            ("show hidden", .collapsed, .show(.hidden)),
            ("show all", .hiddenShown, .show(.all)),
            ("show all from Focus Mode", .focusMode, .show(.all)),
            ("the hidden hotkey", .allShown, .toggle(.hidden)),
            ("the all hotkey", .focusMode, .toggle(.all)),
        ]
        for (name, start, event) in ways {
            var machine = makeMachine(in: start)
            let effects = machine.handle(event)
            #expect(effects.count(where: { $0 == .checkRoom }) == 1, "\(name) asks for a check of the room, once")
            #expect(effects.last == .checkRoom, "\(name) asks after the rest")
        }

        // Ending a reveal, or Focus Mode, doesn't.
        let ends: [(RevealState, RevealEvent)] = [
            (.hiddenShown, .dotClicked(.hidden)), (.allShown, .dotClicked(.always)), (.hiddenShown, .timerFired(.rehide)),
            (.allShown, .scrolled(down: false)), (.hiddenShown, .setFocusMode(true)), (.collapsed, .setFocusMode(true)),
            (.hiddenShown, .show(.off)),
        ]
        for (start, event) in ends {
            var machine = makeMachine(in: start)
            #expect(!machine.handle(event).contains(.checkRoom), "\(event) in \(start)")
        }
    }
}
