/// Which of the changes of state the reveal machine asks for are put on the bar, and when one is followed up: what the app's delivery
/// of them decides, kept here so that it is tested.
///
/// The changes are delivered one at a time, in order, each after the one before it has been applied, and the machine may have gone on
/// meanwhile (the person clicked again while a slow apply ran). So, for a change to a state:
/// - **It is applied only if the machine is still in that state.** One the machine has left is not applied: the newest is, when its
///   change comes.
/// - **It is not applied if that state is what was applied last.** The bar already shows it: reveal, collapse, reveal, with the
///   collapse skipped, is the same reveal, and applying it again would undo what the follow-up of the first made (a swap) and make
///   it again.
/// - **It is followed up only if the machine is still in that state when the apply is over.** One that was left during the apply has
///   a newer change behind it, and the follow-up would only be stale. It isn't remembered as applied either: nothing followed it up,
///   so if the machine comes back to it, it is applied again, and followed up then.
/// - **A reset makes it forget** what was applied: the session collapsed itself, and the bar shows a collapse, so the next change to a
///   reveal is always applied, however long ago the last one was.
public struct RevealApplyPolicy: Sendable, Equatable {
    private var applied: RevealState?

    public init() {}

    /// Whether to apply a change to `state`, the machine being in `current`.
    public func shouldApply(_ state: RevealState, machineIsIn current: RevealState) -> Bool {
        state == current && state != applied
    }

    /// Notes that `state` has been put on the bar, the machine being in `current` now, and says whether it is to be followed up (the
    /// revealed icons looked for, and room made for them).
    ///
    /// - A state that shows nothing (a collapse, Focus Mode) is remembered as applied and has nothing to follow up.
    /// - A reveal the machine is still in is remembered and followed up.
    /// - A reveal the machine left while it was applied isn't remembered, and isn't followed up.
    @discardableResult
    public mutating func didApply(_ state: RevealState, machineIsIn current: RevealState) -> Bool {
        guard state.level != .off else {
            applied = state
            return false
        }
        guard state == current else {
            applied = nil
            return false
        }
        applied = state
        return true
    }

    /// Forgets what was applied: the next change is applied, whatever it is.
    public mutating func forget() {
        applied = nil
    }
}
