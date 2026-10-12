import Testing

@testable import MKLayout

@Suite("Reveal apply policy", .timeLimit(.minutes(1)))
struct RevealApplyPolicyTests {
    private let allStates: [RevealState] = [.collapsed, .hiddenShown, .allShown, .focusMode]

    @Test func aChangeIsAppliedWhileTheMachineIsStillInThatState() {
        let policy = RevealApplyPolicy()
        for state in allStates {
            #expect(policy.shouldApply(state, machineIsIn: state))
        }
    }

    @Test func aChangeTheMachineHasLeftIsNotApplied() {
        let policy = RevealApplyPolicy()
        for state in allStates {
            for current in allStates where current != state {
                #expect(!policy.shouldApply(state, machineIsIn: current), "\(state) when the machine is in \(current)")
            }
        }
    }

    @Test func theStateThatWasAppliedLastIsNotAppliedAgain() {
        var policy = RevealApplyPolicy()
        policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)
        #expect(!policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))
        // The others are, when the machine is in them.
        #expect(policy.shouldApply(.collapsed, machineIsIn: .collapsed))
        #expect(policy.shouldApply(.allShown, machineIsIn: .allShown))
        #expect(policy.shouldApply(.focusMode, machineIsIn: .focusMode))

        // Once another was applied, the first is a change again.
        policy.didApply(.collapsed, machineIsIn: .collapsed)
        #expect(policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))
        #expect(!policy.shouldApply(.collapsed, machineIsIn: .collapsed))
    }

    @Test func revealCollapseRevealIsOneRevealWhenTheCollapseWasNeverApplied() {
        // The first reveal is applied. While it is, the person collapses and reveals again: two changes are queued behind it, and the
        // machine is in the reveal. The collapse isn't applied (the machine left it), and nor is the second reveal (the bar shows it),
        // so what the first reveal's follow-up made (a swap) isn't undone and made again.
        var policy = RevealApplyPolicy()
        #expect(policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))
        policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)

        #expect(!policy.shouldApply(.collapsed, machineIsIn: .hiddenShown), "the collapse")
        #expect(!policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown), "the second reveal")
    }

    @Test func aCollapseThatTheMachineStillHoldsIsAppliedAfterAReveal() {
        var policy = RevealApplyPolicy()
        policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)
        #expect(policy.shouldApply(.collapsed, machineIsIn: .collapsed))
    }

    @Test func aRevealIsFollowedUpOnlyIfTheMachineHasNotLeftItDuringTheApply() {
        for state in [RevealState.hiddenShown, .allShown] {
            var policy = RevealApplyPolicy()
            let stillIn = policy.didApply(state, machineIsIn: state)
            #expect(stillIn, "\(state), still the machine's")
            for left in allStates where left != state {
                var other = RevealApplyPolicy()
                let followedUp = other.didApply(state, machineIsIn: left)
                #expect(!followedUp, "\(state), left for \(left)")
            }
        }
    }

    @Test func aStateThatShowsNothingHasNothingToFollowUpAndIsRemembered() {
        for state in [RevealState.collapsed, .focusMode] {
            for current in allStates {
                var policy = RevealApplyPolicy()
                let followedUp = policy.didApply(state, machineIsIn: current)
                #expect(!followedUp, "\(state) with the machine in \(current)")
                #expect(!policy.shouldApply(state, machineIsIn: state), "it is what the bar shows now")
            }
        }
    }

    @Test func aRevealTheMachineLeftDuringItsApplyIsNotRememberedAsApplied() {
        var policy = RevealApplyPolicy()
        // The reveal was put on the bar, and the machine left it during the apply (a collapse is behind it): nothing followed it up.
        let left = policy.didApply(.hiddenShown, machineIsIn: .collapsed)
        #expect(!left)
        // Should the machine come back to it, it is applied again, and followed up then; the bar doesn't count as showing it.
        #expect(policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))
        let again = policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)
        #expect(again)
    }

    @Test func aRevealTheMachineLeftReplacesWhatWasRememberedBefore() {
        // A reveal applied and followed up, then another that was left during its apply: the memory doesn't go back to the first, which
        // the bar no longer shows.
        var policy = RevealApplyPolicy()
        let first = policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)
        #expect(first)
        let second = policy.didApply(.allShown, machineIsIn: .hiddenShown)
        #expect(!second)
        #expect(policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))
        #expect(policy.shouldApply(.allShown, machineIsIn: .allShown))
    }

    @Test func aResetMakesTheNextRevealApplyEvenIfItIsTheOneAppliedLast() {
        var policy = RevealApplyPolicy()
        let followedUp = policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)
        #expect(followedUp)
        #expect(!policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))

        // The reset collapsed the session: a reveal that lands before the collapse's own change is delivered is applied, not skipped as
        // the one the bar shows.
        policy.forget()
        #expect(policy.shouldApply(.hiddenShown, machineIsIn: .hiddenShown))
        #expect(policy.shouldApply(.collapsed, machineIsIn: .collapsed))
        #expect(policy.shouldApply(.allShown, machineIsIn: .allShown))
        #expect(policy.shouldApply(.focusMode, machineIsIn: .focusMode))
    }

    @Test func aResetStillLeavesAStateTheMachineHasLeftUnapplied() {
        var policy = RevealApplyPolicy()
        policy.didApply(.hiddenShown, machineIsIn: .hiddenShown)
        policy.forget()
        #expect(!policy.shouldApply(.collapsed, machineIsIn: .hiddenShown))
    }
}
