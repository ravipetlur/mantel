import AppKit
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// A notification center that notes what it was asked, and is never a real one: nothing is observed and nothing is posted.
private final class NotingCenter: SessionNotificationCenter {
    private struct State {
        var observed: [Notification.Name] = []
        var stopped = 0
    }

    private let state = Mutex(State())

    var observed: [Notification.Name] { state.withLock { $0.observed } }
    var stopped: Int { state.withLock { $0.stopped } }

    func observeImmediately(_ observer: SessionNotificationTarget, name: Notification.Name) {
        state.withLock { $0.observed.append(name) }
    }

    func stopObserving(_ observer: SessionNotificationTarget) {
        state.withLock { $0.stopped += 1 }
    }
}

/// How the changes of the session state are listened for: which notification on which center, that each is asked to be delivered at once,
/// and what each becomes. The real centers are never made here.
@Suite("Session notifications", .timeLimit(.minutes(1)))
struct SessionNotificationsTests {
    private let lock = Notification.Name("com.apple.screenIsLocked")
    private let unlock = Notification.Name("com.apple.screenIsUnlocked")

    @Test func theLockIsListenedForOnTheDistributedCenterAndAskedForAtOnce() {
        let workspace = NotingCenter()
        let distributed = NotingCenter()

        _ = SessionNotificationListening.changes(workspace: workspace, distributed: distributed)

        // The distributed center holds back what an inactive app is sent, and Mantel is almost never active: both names are observed
        // through `observeImmediately`, and nothing else is observed there.
        #expect(Set(distributed.observed) == [lock, unlock])
        #expect(distributed.observed.count == 2)
        #expect(!workspace.observed.contains(lock) && !workspace.observed.contains(unlock))
    }

    @Test func theWorkspaceNotificationsAreTheDisplaysTheWakeAndTheSession() {
        let workspace = NotingCenter()
        _ = SessionNotificationListening.changes(workspace: workspace, distributed: NotingCenter())

        #expect(Set(workspace.observed) == [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ])
        #expect(workspace.observed.count == 5)
    }

    @Test func everyChangeComesFromOneNotificationAndEveryNameIsUsedOnce() {
        let all = SessionNotifications.all
        #expect(Set(all.map(\.name)).count == all.count, "no name is listed twice")
        let changes: [SessionChange] = [.displaysAsleep(true), .displaysAsleep(false), .screenLocked(true), .screenLocked(false),
                                        .sessionActive(true), .sessionActive(false), .systemWoke]
        for change in changes {
            #expect(all.filter { $0.change == change }.count == 1, "\(change)")
        }
        #expect(all.count == changes.count)
        #expect(all.first { $0.name == lock }?.change == .screenLocked(true))
        #expect(all.first { $0.name == unlock }?.change == .screenLocked(false))
    }

    @Test func aNotificationBecomesItsChangeAndOthersAreIgnored() async {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionChange.self)
        let target = SessionNotificationTarget(continuation: continuation)

        for notification in SessionNotifications.all { target.received(Notification(name: notification.name)) }
        target.received(Notification(name: Notification.Name("com.example.somethingElse")))
        continuation.finish()

        var seen: [SessionChange] = []
        for await change in stream { seen.append(change) }
        #expect(seen == SessionNotifications.all.map(\.change), "each, in order, and the unknown one nothing")
    }

    @Test func theObservationsAreTakenAwayWhenTheStreamEnds() async {
        let workspace = NotingCenter()
        let distributed = NotingCenter()
        let stream = SessionNotificationListening.changes(workspace: workspace, distributed: distributed)
        #expect(workspace.stopped == 0 && distributed.stopped == 0)

        let listening = Task { for await _ in stream {} }
        listening.cancel()

        #expect(await waitUntil { workspace.stopped == 1 && distributed.stopped == 1 }, "taken away from both centers, once")
        await listening.value
    }
}
