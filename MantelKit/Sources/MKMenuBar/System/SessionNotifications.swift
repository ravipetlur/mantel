import AppKit
import Foundation
import MKCore

/// Which notifications tell Mantel of a change of the session state, and on which notification center each one comes: a plain list, so
/// that a test can see it without a center to ask.
///
/// The lock's two notifications come on the distributed center, and that center holds back what is posted to an app that isn't active
/// (`DistributedNotificationCenter`'s suspension) until the app is next active. Mantel is a menu bar app and is almost never active, so
/// every observer is added to be told at once (`SessionNotificationCenter.observeImmediately`): a lock that was told after the person
/// had unlocked would hold auto-refresh back for no reason, or never.
struct SessionNotification: Sendable, Equatable {
    enum Center: Sendable, Equatable {
        /// `NSWorkspace.shared.notificationCenter`.
        case workspace
        /// The system-wide center other processes post to.
        case distributed
    }

    let center: Center
    let name: Notification.Name
    let change: SessionChange
}

enum SessionNotifications {
    static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    /// One notification for each thing that can happen to the session state.
    static let all: [SessionNotification] = [
        SessionNotification(center: .workspace, name: NSWorkspace.screensDidSleepNotification, change: .displaysAsleep(true)),
        SessionNotification(center: .workspace, name: NSWorkspace.screensDidWakeNotification, change: .displaysAsleep(false)),
        SessionNotification(center: .workspace, name: NSWorkspace.didWakeNotification, change: .systemWoke),
        SessionNotification(center: .workspace, name: NSWorkspace.sessionDidResignActiveNotification, change: .sessionActive(false)),
        SessionNotification(center: .workspace, name: NSWorkspace.sessionDidBecomeActiveNotification, change: .sessionActive(true)),
        SessionNotification(center: .distributed, name: screenIsLocked, change: .screenLocked(true)),
        SessionNotification(center: .distributed, name: screenIsUnlocked, change: .screenLocked(false)),
    ]
}

/// What the session state asks of a notification center, so that a test can give it one that notes what it was asked.
protocol SessionNotificationCenter: Sendable {
    /// Has `observer` told of `name` as it is posted, whether or not the app is the active one.
    func observeImmediately(_ observer: SessionNotificationTarget, name: Notification.Name)
    /// Takes away every observation `observer` was given.
    func stopObserving(_ observer: SessionNotificationTarget)
}

/// The workspace's center. It is local to the process and holds nothing back, so telling it at once is how it always works.
struct WorkspaceSessionCenter: SessionNotificationCenter {
    func observeImmediately(_ observer: SessionNotificationTarget, name: Notification.Name) {
        NSWorkspace.shared.notificationCenter.addObserver(observer, selector: SessionNotificationTarget.action, name: name, object: nil)
    }

    func stopObserving(_ observer: SessionNotificationTarget) {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
}

/// The distributed center, asked to deliver at once, as the test item's own observer is.
struct DistributedSessionCenter: SessionNotificationCenter {
    func observeImmediately(_ observer: SessionNotificationTarget, name: Notification.Name) {
        DistributedNotificationCenter.default().addObserver(observer, selector: SessionNotificationTarget.action, name: name, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    func stopObserving(_ observer: SessionNotificationTarget) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}

/// What the centers send notifications to: it passes each one on, as the change it stands for, to the stream of changes.
final class SessionNotificationTarget: NSObject, Sendable {
    static let action = #selector(SessionNotificationTarget.received(_:))

    private let changes: [Notification.Name: SessionChange]
    private let continuation: AsyncStream<SessionChange>.Continuation

    init(continuation: AsyncStream<SessionChange>.Continuation) {
        changes = Dictionary(SessionNotifications.all.map { ($0.name, $0.change) }, uniquingKeysWith: { first, _ in first })
        self.continuation = continuation
    }

    /// A notification that isn't one of the list is ignored.
    @objc func received(_ notification: Notification) {
        guard let change = changes[notification.name] else { return }
        continuation.yield(change)
    }
}

/// The changes of the session state as the notification centers tell them.
enum SessionNotificationListening {
    /// Observes every notification of `SessionNotifications.all` on its center, and takes the observations away when the stream ends.
    static func changes(workspace: any SessionNotificationCenter, distributed: any SessionNotificationCenter) -> AsyncStream<SessionChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionChange.self, bufferingPolicy: .unbounded)
        let target = SessionNotificationTarget(continuation: continuation)
        for notification in SessionNotifications.all {
            switch notification.center {
            case .workspace: workspace.observeImmediately(target, name: notification.name)
            case .distributed: distributed.observeImmediately(target, name: notification.name)
            }
        }
        continuation.onTermination = { _ in
            workspace.stopObserving(target)
            distributed.stopObserving(target)
        }
        return stream
    }
}
