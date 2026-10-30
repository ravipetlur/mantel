import Foundation

/// Whether "Replay now" in Diagnostics may run, and if not, what to tell the person.
public enum ReplayNowDecision: Sendable, Equatable {
    case allowed
    /// The words for the Diagnostics pane's message.
    case refused(String)
}

/// "Replay now" puts back what Mantel has changed in the system, from the journal. That is only right when nothing is using those
/// changes at the moment: a hiding method that is holding changes in place would stop hiding. So it is refused then, with the reason.
public enum ReplayNowPolicy {
    /// The first reason that applies: nothing to put back, or the hiding method is using what is journaled.
    ///
    /// `journalEmpty` means no temporary change is waiting (`Journal.untilQuitRecords` is empty). What Mantel keeps (`.kept` records)
    /// is not waiting for anything: Replay now doesn't touch it, and only "Restore original layout" and "Restore original spacing"
    /// put it back.
    public static func decide(journalEmpty: Bool, engineHoldsJournal: Bool) -> ReplayNowDecision {
        if journalEmpty { return .refused("Nothing is waiting to be put back.") }
        if engineHoldsJournal { return .refused("The hiding method is using these changes. Use Reset menu bar to undo them.") }
        return .allowed
    }
}
