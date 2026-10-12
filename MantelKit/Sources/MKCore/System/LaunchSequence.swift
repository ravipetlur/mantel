import Foundation

/// What the app does at launch, other than starting the control socket (which sits between `LaunchSequence.beforeSocket`
/// and `LaunchSequence.steps(after:)`).
public enum LaunchStep: String, Sendable, CaseIterable {
    case createFolders, configureLog
    case replayJournal, loadSettings, registerHotkeys, createStatusItem, observeDisplays, startMenuBar, openOnboardingIfNeeded
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
/// the running copy has journaled for a change it is in the middle of. It must leave the running copy's log alone too, so
/// the log is pointed at its file only after the socket is held: what a second copy says goes to the unified log and not to
/// `mantel.log`.
///
/// - The folders come first, because the socket is in one of them.
/// - The log is pointed at its file by the copy that holds the socket, and everything after that is kept.
/// - The journal is replayed, and the replay finishes before anything can record into it (a record made during a replay is
///   refused).
/// - Every settings document in use is loaded before any is saved: the store only protects a file it has read.
/// - Hotkeys are registered from the bindings that were loaded, never from the defaults.
/// - The menu bar is started (the running apps are watched, and the session begins to hide) once the displays are known and the
///   settings and the journal's replay are behind it: what the session hides is what the sections say, and a replay that came after
///   it could put back what it had just changed.
public enum LaunchSequence {
    /// Before the control socket starts.
    public static let beforeSocket: [LaunchStep] = [.createFolders]

    /// After the control socket has started, or has not: nothing, if another Mantel holds it.
    public static func steps(after socket: SocketStartOutcome) -> [LaunchStep] {
        switch socket {
        case .heldByAnotherMantel:
            []
        case .listening, .notStarted:
            [.configureLog, .replayJournal, .loadSettings, .registerHotkeys, .createStatusItem, .observeDisplays, .startMenuBar,
             .openOnboardingIfNeeded]
        }
    }
}
