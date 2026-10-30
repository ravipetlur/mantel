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
/// - **A correction is stale once any later change has passed its second look.** The correction to the second bar opens the bar on
///   the main actor after the session's work, so it carries the count of changes that had passed when it was asked for, and is dropped
///   if the count has moved (`isStale(stamp:)`).
/// - **The collapse after an icon is clicked in the second bar** is skipped under the same rule (`collapsesAfterIconClick(stamp:)`), the
///   stamp being taken when the cell is clicked.
/// - **A reset makes it forget** what was applied: the session collapsed itself, and the bar shows a collapse, so the next change to a
///   reveal is always applied, however long ago the last one was.
public struct RevealApplyPolicy: Sendable, Equatable {
    private var applied: RevealState?
    /// How many changes have passed their second look (and a reset), for telling a correction that something newer has overtaken.
    public private(set) var looks = 0

    public init() {}

    /// Notes that a change has passed its second look, and is about to open or close the bar and be applied; returns the stamp a
    /// correction to it carries.
    @discardableResult
    public mutating func passedSecondLook() -> Int {
        looks += 1
        return looks
    }

    /// Whether a correction that was asked for at `stamp` has been overtaken: a change has passed its look since.
    public func isStale(stamp: Int) -> Bool {
        stamp != looks
    }

    /// Whether the collapse that follows an icon clicked in the second bar is still wanted. The click may take seconds (room is made for
    /// it), and the cell was shown by the reveal at `stamp` (`looks` when it was clicked): a change that has passed its look since is a
    /// newer reveal (an inline one the person asked for meanwhile, Focus Mode), which the collapse would take down.
    public func collapsesAfterIconClick(stamp: Int) -> Bool {
        !isStale(stamp: stamp)
    }

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
        looks += 1
    }
}
