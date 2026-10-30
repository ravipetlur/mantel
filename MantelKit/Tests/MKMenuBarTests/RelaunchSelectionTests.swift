import Foundation
import Testing

@testable import MKMenuBar

@Suite("Relaunch selection", .timeLimit(.minutes(1)))
struct RelaunchSelectionTests {
    private let candidates = ["com.example.a", "com.example.b", "com.example.c"].enumerated().map { index, id in
        RelaunchCandidate(id: id, name: "App \(index)", pid: pid_t(100 + index), bundleURL: URL(filePath: "/Applications/App\(index).app"))
    }

    @Test func startsWithNothingTicked() {
        let selection = RelaunchSelection(candidates: candidates)
        #expect(selection.ticked.isEmpty)
        #expect(!selection.canRelaunch)
        #expect(selection.chosen.isEmpty)
        // Nothing offered, nothing ticked.
        #expect(!RelaunchSelection(candidates: []).canRelaunch)
    }

    @Test func selectAllTicksEvery() {
        var selection = RelaunchSelection(candidates: candidates)
        selection.selectAll()
        #expect(selection.ticked == Set(candidates.map(\.id)))
        #expect(selection.chosen == candidates)
        #expect(selection.canRelaunch)
        // Select All with nothing offered ticks nothing.
        var empty = RelaunchSelection(candidates: [])
        empty.selectAll()
        #expect(!empty.canRelaunch)
    }

    @Test func relaunchNeedsSomethingTicked() {
        var selection = RelaunchSelection(candidates: candidates)
        selection.toggle("com.example.b")
        #expect(selection.canRelaunch)
        selection.toggle("com.example.b")
        #expect(!selection.canRelaunch)
        // Only what was offered can be ticked: an app that isn't in the list (Mantel itself) never makes Relaunch available.
        selection.toggle("com.example.mantel")
        #expect(!selection.canRelaunch)
        #expect(selection.ticked.isEmpty)
    }

    @Test func toggleRoundTrip() {
        var selection = RelaunchSelection(candidates: candidates)
        selection.toggle("com.example.c")
        selection.toggle("com.example.a")
        #expect(selection.ticked == ["com.example.a", "com.example.c"])
        // The apps asked are in the order of the list, not of the ticking.
        #expect(selection.chosen.map(\.id) == ["com.example.a", "com.example.c"])
        selection.toggle("com.example.a")
        #expect(selection.ticked == ["com.example.c"])
        selection.toggle("com.example.c")
        #expect(selection == RelaunchSelection(candidates: candidates))
    }

    @Test func eachOutcomeSaysItsWord() {
        #expect(RelaunchOutcome.relaunched.rowText == "Relaunched")
        #expect(RelaunchOutcome.didNotQuit.rowText == "Didn't quit")
        #expect(RelaunchOutcome.couldNotOpen("no such app").rowText == "Couldn't open")
    }

    @Test func aRelaunchedAppIsUntickedAndStaysSo() {
        var selection = RelaunchSelection(candidates: candidates)
        selection.selectAll()
        selection.finish(["com.example.a": .relaunched, "com.example.b": .didNotQuit, "com.example.c": .couldNotOpen("no such app")])
        // What is still ticked is what can be tried again; Relaunch is available for it alone.
        #expect(selection.ticked == ["com.example.b", "com.example.c"])
        #expect(selection.relaunched == ["com.example.a"])
        #expect(selection.canRelaunch)
        // The relaunched app can't be ticked again, by hand or by Select All.
        selection.toggle("com.example.a")
        #expect(selection.ticked == ["com.example.b", "com.example.c"])
        selection.toggle("com.example.b")
        selection.toggle("com.example.c")
        #expect(!selection.canRelaunch)
        selection.selectAll()
        #expect(selection.ticked == ["com.example.b", "com.example.c"])
        // An ID that was never offered isn't taken in.
        selection.finish(["com.example.mantel": .relaunched])
        #expect(selection.relaunched == ["com.example.a"])
    }

    @Test func aRunHandsOutTheAppsInOrder() {
        var run = RelaunchRun(chosen: candidates)
        #expect(run.next()?.id == "com.example.a")
        #expect(run.next()?.id == "com.example.b")
        #expect(run.next()?.id == "com.example.c")
        #expect(run.next() == nil)
        #expect(!run.stopRequested)
        var empty = RelaunchRun(chosen: [])
        #expect(empty.next() == nil)
    }

    @Test func aStopTakesEffectBetweenApps() {
        var run = RelaunchRun(chosen: candidates)
        #expect(run.next()?.id == "com.example.a")
        // Asked while the first app is being relaunched: the first is not taken back, and none after it is started.
        run.requestStop()
        #expect(run.stopRequested)
        #expect(run.next() == nil)
        #expect(run.next() == nil)
    }
}
