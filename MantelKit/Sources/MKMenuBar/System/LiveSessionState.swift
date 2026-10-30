import AppKit
import CoreGraphics
import Foundation
import MKCore

/// The state of the session as the system says it: whether the displays are asleep, the screen is locked, and this user's session is on
/// screen. Only the app makes one (a test is given a `SessionStateSource` of its own): it reads the system and listens to its
/// notifications.
///
/// - **Displays:** the workspace's `screensDidSleep` and `screensDidWake`. At the start, `CGDisplayIsAsleep` of the main display.
/// - **The Mac waking:** the workspace's `didWake`, told as an event of its own (`SessionChange.systemWoke`).
/// - **Fast user switching:** the workspace's `sessionDidResignActive` and `sessionDidBecomeActive`. At the start, whether the session
///   dictionary says this session is on the console.
/// - **The lock:** the distributed notifications `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`, observed to be delivered
///   immediately (`SessionNotifications` has the whole list). At the start, whether the session dictionary says the screen is locked (it
///   says nothing when it isn't).
///
/// It only listens: nothing is ever posted, and the observers are taken away when the stream of changes ends.
public final class LiveSessionState: SessionStateSource {
    public init() {}

    public func current() -> SessionState {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // A session the system doesn't describe is taken to be on screen and unlocked: auto-refresh is held back only for a reason that
        // is known.
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        let locked = (session?[Self.screenIsLockedKey] as? Bool) ?? false
        return SessionState(displaysAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0, screenLocked: locked, sessionActive: onConsole)
    }

    /// The notifications of `SessionNotifications.all`, each observed to be told at once: the distributed center holds back what it is
    /// posted while the app is inactive, and Mantel almost never is the active app.
    public func changes() -> AsyncStream<SessionChange> {
        SessionNotificationListening.changes(workspace: WorkspaceSessionCenter(), distributed: DistributedSessionCenter())
    }

    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"
}
