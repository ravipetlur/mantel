import Foundation
import MKCore
import MKTestSupport
import Testing

@Suite("RunningAppsChange", .timeLimit(.minutes(2)))
struct RunningAppsChangeTests {
    private let finder = RunningApp.fake(100, "com.example.finder", "Finder")
    private let notes = RunningApp.fake(200, "com.example.notes", "Notes")
    private let daemon = RunningApp.fake(300, "com.example.daemon", "Daemon", backgroundOnly: true)

    @Test func launchedAndQuitByPid() {
        let change = RunningAppsChange.between([finder, notes], [notes, daemon])
        #expect(change.launched == [daemon])
        #expect(change.quit == [finder])
        #expect(!change.isEmpty)
    }

    @Test func listsKeepTheOrderTheAppsCameIn() {
        let first = RunningApp.fake(1, "com.example.one")
        let second = RunningApp.fake(2, "com.example.two")
        let third = RunningApp.fake(3, "com.example.three")
        let change = RunningAppsChange.between([third, first, second], [])
        #expect(change.quit == [third, first, second])
        #expect(RunningAppsChange.between([], [second, third, first]).launched == [second, third, first])
    }

    @Test func samePidNewBundleCountsAsBoth() {
        // The system gave the number to another program, or the process became one.
        let became = RunningApp.fake(200, "com.example.mail", "Mail")
        let change = RunningAppsChange.between([finder, notes], [finder, became])
        #expect(change.launched == [became])
        #expect(change.quit == [notes])
    }

    @Test func emptyWhenUnchanged() {
        #expect(RunningAppsChange.between([finder, notes], [notes, finder]).isEmpty)
        #expect(RunningAppsChange.between([], []).isEmpty)
        // A change of name or location is not a launch.
        let renamed = RunningApp(pid: 100, bundleID: "com.example.finder", name: "Another name",
                                 bundleURL: URL(filePath: "/Applications/Finder.app"), isBackgroundOnly: false)
        #expect(RunningAppsChange.between([finder], [renamed]).isEmpty)
    }

    @Test func anAppWithoutABundleIDIsToldByItsPid() {
        let helper = RunningApp.fake(400, nil, "helper")
        let change = RunningAppsChange.between([], [helper])
        #expect(change.launched == [helper])
        #expect(RunningAppsChange.between([helper], [helper]).isEmpty)
    }
}
