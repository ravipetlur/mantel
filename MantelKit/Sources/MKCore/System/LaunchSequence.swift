import Foundation

/// What the app does at launch, other than starting the control socket (which sits between `LaunchSequence.beforeSocket`
/// and `LaunchSequence.steps(after:)`).
public enum LaunchStep: String, Sendable, CaseIterable {
    case createFolders, configureLog
    case replayJournal, loadSettings, registerHotkeys, createStatusItem, observeDisplays, openOnboardingIfNeeded
}

/// How starting the control socket went.
public enum SocketStartOutcome: Sendable, Equatable {
    case listening
    /// It couldn't be started for a reason of its own (a path that is too long, a bind that failed). Mantel works without it.
    case notStarted
    /// Another running Mantel holds the socket's lock.
    case heldByAnotherMantel
}

/// The order of the launch, and the one rule that decides whether it goes on.
///
/// The socket comes before the journal replay because the lock on it is the single-instance lock: it is the one check that
/// can't miss another running Mantel. A copy that doesn't hold it must never replay the journal, which restores whatever
/// the running copy has journaled for a change it is in the middle of.
///
/// - Folders and the log come first, so that everything after is kept in the log.
/// - The journal is replayed, and the replay finishes before anything can record into it (a record made during a replay is
///   refused).
/// - Every settings document in use is loaded before any is saved: the store only protects a file it has read.
/// - Hotkeys are registered from the bindings that were loaded, never from the defaults.
public enum LaunchSequence {
    /// Before the control socket starts.
    public static let beforeSocket: [LaunchStep] = [.createFolders, .configureLog]

    /// After the control socket has started, or has not: nothing, if another Mantel holds it.
    public static func steps(after socket: SocketStartOutcome) -> [LaunchStep] {
        switch socket {
        case .heldByAnotherMantel:
            []
        case .listening, .notStarted:
            [.replayJournal, .loadSettings, .registerHotkeys, .createStatusItem, .observeDisplays, .openOnboardingIfNeeded]
        }
    }
}
