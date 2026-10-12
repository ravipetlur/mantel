import AppKit
import Dispatch
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The list of running apps as a test says it is, in place of the workspace's.
private final class FakeWorkspaceList: Sendable {
    private let apps: Mutex<[RunningApp]>

    init(_ apps: [RunningApp]) {
        self.apps = Mutex(apps)
    }

    var current: [RunningApp] {
        get { apps.withLock { $0 } }
        set { apps.withLock { $0 = newValue } }
    }
}

@MainActor
@Suite("RunningAppsSource", .timeLimit(.minutes(1)))
struct RunningAppsSourceTests {
    private let finder = RunningApp.fake(100, "com.example.finder", "Finder")
    private let daemon = RunningApp.fake(300, "com.example.daemon", "Daemon", backgroundOnly: true)
    private let anonymous = RunningApp.fake(400, nil, "helper")

    private func source(_ list: FakeWorkspaceList) -> RunningAppsSource {
        RunningAppsSource(read: { list.current })
    }

    @Test func allHasABundleIDAndKeepsTheBackgroundOnlyApps() {
        let list = FakeWorkspaceList([finder, daemon, anonymous])
        let source = source(list)
        #expect(source.all == [finder, daemon])
    }

    @Test func regularLeavesOutTheBackgroundOnlyApps() {
        let list = FakeWorkspaceList([finder, daemon, anonymous])
        let source = source(list)
        #expect(source.regular == [finder, anonymous])
    }

    @Test func aChangeIsInTheListBeforeTheHandlerHearsOfIt() {
        let list = FakeWorkspaceList([finder])
        let source = source(list)
        var heard: [(change: RunningAppsChange, listedThen: [RunningApp])] = []
        source.start { change in heard.append((change, source.all)) }

        list.current = [finder, daemon]
        source.reload()
        #expect(heard.count == 1)
        #expect(heard.first?.change.launched == [daemon])
        #expect(heard.first?.change.quit == [])
        #expect(heard.first?.listedThen == [finder, daemon], "the handler reads the list as it is after the change")

        list.current = [daemon]
        source.reload()
        #expect(heard.count == 2)
        #expect(heard.last?.change.quit == [finder])
        #expect(heard.last?.listedThen == [daemon])
    }

    @Test func startingReportsNothingForTheAppsAlreadyRunning() {
        let list = FakeWorkspaceList([finder, daemon])
        let source = source(list)
        var calls = 0
        source.start { _ in calls += 1 }
        #expect(calls == 0)
        // The same list again is no change either.
        source.reload()
        #expect(calls == 0)
        #expect(source.all == [finder, daemon])
    }

    @Test func theListIsReadAgainWhenTheHandlerIsStarted() {
        // An app that launched between making the source and starting it is in the list, without being reported as new.
        let list = FakeWorkspaceList([finder])
        let source = source(list)
        list.current = [finder, daemon]
        var calls = 0
        source.start { _ in calls += 1 }
        #expect(source.all == [finder, daemon])
        #expect(calls == 0)
    }

    @Test func theChangeCallbackFromTheWorkspaceReloadsTheList() {
        // What the real source gives KVO to call: it reloads. The test holds on to the callback and calls it as KVO would.
        let list = FakeWorkspaceList([finder])
        var callback: (@MainActor () -> Void)?
        let source = RunningAppsSource(read: { list.current }, observeChanges: { changed in
            callback = changed
            return nil
        })
        var heard: [RunningAppsChange] = []
        source.start { heard.append($0) }

        list.current = [finder, daemon]
        callback?()
        #expect(heard.map(\.launched) == [[daemon]])
        #expect(source.all == [finder, daemon])
    }

    @Test func theWorkspaceSourceStartsAndListsTheAppsThatAreRunning() {
        // Only reads, and watches: nothing is asked of any app.
        let source = RunningAppsSource()
        source.start { _ in }
        let running = NSWorkspace.shared.runningApplications.count
        #expect(source.all.allSatisfy { $0.bundleID != nil })
        #expect(source.regular.allSatisfy { !$0.isBackgroundOnly })
        #expect(source.all.count <= running, "no app is listed that isn't there")
        #expect(source.regular.count <= running)
    }

    @Test func theListIsReadFromAnotherThreadWhileTheMainThreadIsBusy() {
        // A read that waited for the main thread would never finish: the main thread is held here until the other thread has
        // read the list.
        let list = FakeWorkspaceList([finder, daemon])
        let source = source(list)
        let done = DispatchSemaphore(value: 0)
        let seen = Mutex<(all: [RunningApp], regular: [RunningApp])?>(nil)
        DispatchQueue.global().async {
            seen.withLock { $0 = (source.all, source.regular) }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + .seconds(10))
        #expect(finished == .success, "the read came back without the main thread")
        #expect(seen.withLock { $0?.all } == [finder, daemon])
        #expect(seen.withLock { $0?.regular } == [finder])
    }
}
