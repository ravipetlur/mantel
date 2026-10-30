import CoreGraphics
import Foundation
import MKCore
import MKLayout
import Testing

@testable import MKMenuBar

private let display = "display-main"
private let own = "com.example.mantel"
private let one = "com.example.one"
private let two = "com.example.two"
private let pidOne: Set<pid_t> = [101]
private let pidTwo: Set<pid_t> = [102]

private enum Bar {
    static let geometry = MenuBarGeometry(displayUUID: display, rect: CGRect(x: 0, y: 0, width: 3000, height: 30), notch: nil)

    enum Place {
        case slot, none, overflowed
    }

    static func item(_ bundleID: String, _ place: Place = .slot) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier("main")), ownerBundleID: bundleID, appName: nil, label: nil,
                    frames: place == .slot ? [display: CGRect(x: 100, y: 0, width: 38, height: 30)] : [:],
                    overflowedOn: place == .overflowed ? [display] : [], isMantel: false, reportedWidth: 24)
    }

    static func dot(_ place: Place = .slot) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: own, key: .identifier("mantel.dot")), ownerBundleID: own, appName: nil, label: nil,
                    frames: place == .slot ? [display: CGRect(x: 40, y: 0, width: 24, height: 30)] : [:],
                    overflowedOn: place == .overflowed ? [display] : [], isMantel: true, ownKind: .hiddenDot)
    }

    static func read(_ items: [MenuBarItem], problems: [InventoryProblem] = [], unanswered: Set<String> = [], untied: [CGRect] = [],
                     contested: Set<String> = []) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [geometry], items: items, chevrons: [:], reach: [],
                  problems: problems, unansweredApps: unanswered, untiedSlots: untied.isEmpty ? [:] : [display: untied],
                  contestedApps: contested)
    }
}

private extension UnattachedReadGate {
    static let open = UnattachedReadGate(allowlistInCharge: true, armedBefore: true, armedAfter: true, showsThePlan: true, collapsed: true,
                                         awake: true, beingMadeAgain: false)
}

@Suite("Stuck bar: the look", .timeLimit(.minutes(1)))
struct StuckBarLookTests {
    private func look(_ read: Inventory, gate: UnattachedReadGate = .open, hadASlot: [String: Set<pid_t>] = [one: pidOne, two: pidTwo],
                      processes: [String: Set<pid_t>] = [one: pidOne, two: pidTwo], notDrawn: Set<String> = [],
                      fits: @escaping (String) -> Bool = { _ in true }) -> StuckBar.Look {
        let plan = VisibilityPlan(visibleBundleIDs: [one, two, own], concealedBundleIDs: [],
                                  visibleSystemItems: Set(VisibilityPlan.allSystemItems), concealedSections: [], source: .sections)
        return StuckBar.look(at: read, gate: gate, plan: plan, sections: sections(shown: [one, two]), running: [one, two, own],
                             notDrawn: notDrawn, ownBundleID: own, hadASlot: hadASlot, processes: processes, fits: fits)
    }

    @Test func anAppThatHadASlotAndHasNoneWithRoomIsStuck() {
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()])) == .stuck(StuckBarFinding(apps: [one], ownItems: false)))
    }

    @Test func anAppThatNeverHadASlotIsNotStuck() {
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()]), hadASlot: [two: pidTwo]) == .whole)
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()]), hadASlot: [:]) == .whole)
    }

    @Test func anAppThatHadASlotInAnotherProcessIsNotStuck() {
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()]), processes: [one: [999], two: pidTwo]) == .whole)
    }

    @Test func anAppThatHasNoRoomOrIsOutOfTheWayIsNotStuck() {
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()]), fits: { _ in false }) == .whole)
        #expect(look(Bar.read([Bar.item(one, .overflowed), Bar.item(two), Bar.dot()])) == .whole)
    }

    @Test func anAppWithAnUntiedSlotOrContestedIsNotStuck() {
        let untied = [CGRect(x: 10, y: 0, width: 38, height: 30)]
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()], untied: untied)) == .whole)
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()], contested: [one])) == .whole)
    }

    @Test func oneUntiedSlotExcusesOneMissingAppAndNotTwo() {
        let untied = [CGRect(x: 10, y: 0, width: 38, height: 30)]
        let both = Bar.read([Bar.item(one, .none), Bar.item(two, .none), Bar.dot()], untied: untied)
        #expect(look(both) == .stuck(StuckBarFinding(apps: [one, two], ownItems: false)), "one of the two is missing, whichever the slot is")
        // An app that never had a slot is one the slot could be as much as the ones that had: it counts against the slot too.
        #expect(look(both, hadASlot: [one: pidOne]) == .stuck(StuckBarFinding(apps: [one], ownItems: false)))
        // A slot of another width is nobody's: the apps are missing whatever it is.
        let wide = Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()], untied: [CGRect(x: 10, y: 0, width: 90, height: 30)])
        #expect(look(wide) == .stuck(StuckBarFinding(apps: [one], ownItems: false)))
        // Two slots for the two apps: both are excused.
        let twoSlots = Bar.read([Bar.item(one, .none), Bar.item(two, .none), Bar.dot()],
                                untied: [CGRect(x: 10, y: 0, width: 38, height: 30), CGRect(x: 60, y: 0, width: 38, height: 30)])
        #expect(look(twoSlots) == .whole)
    }

    @Test func theAppsWithNoSlotDontNeedAHistory() {
        let plan = VisibilityPlan(visibleBundleIDs: [one, two, own], concealedBundleIDs: [],
                                  visibleSystemItems: Set(VisibilityPlan.allSystemItems), concealedSections: [], source: .sections)
        func noSlot(_ read: Inventory, gate: UnattachedReadGate = .open) -> Set<String>? {
            StuckBar.appsWithNoSlot(in: read, gate: gate, plan: plan, sections: sections(shown: [one, two]), running: [one, two, own],
                                    notDrawn: [], ownBundleID: own, fits: { _ in true })
        }
        #expect(noSlot(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()])) == [one])
        #expect(noSlot(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()])) == [])
        var closed = UnattachedReadGate.open
        closed.awake = false
        #expect(noSlot(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()]), gate: closed) == nil)
    }

    @Test func anAppThatIsNotDrawnOrNotAnsweringIsNotStuck() {
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()]), notDrawn: [one]) == .whole)
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()], unanswered: [one])) == .whole)
    }

    @Test func aDotWithNoSlotAndRoomIsStuckWhateverTheApps() {
        #expect(look(Bar.read([Bar.item(one), Bar.item(two), Bar.dot(.none)]), hadASlot: [:])
            == .stuck(StuckBarFinding(apps: [], ownItems: true)))
        #expect(look(Bar.read([Bar.item(one), Bar.item(two), Bar.dot(.none)]), fits: { $0 != own }) == .whole, "no room for the dots")
        #expect(look(Bar.read([Bar.item(one), Bar.item(two), Bar.dot(.overflowed)])) == .whole)
    }

    @Test func mantelsOwnItemsAreNoFindingWhileMantelIsTurnedOff() {
        let dotless = Bar.read([Bar.item(one), Bar.item(two), Bar.dot(.none)])
        #expect(look(dotless, hadASlot: [:], notDrawn: [own]) == .whole)
        #expect(look(dotless, hadASlot: [:]) == .stuck(StuckBarFinding(apps: [], ownItems: true)))
        // The apps are looked at all the same.
        let both = Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot(.none)])
        #expect(look(both, notDrawn: [own]) == .stuck(StuckBarFinding(apps: [one], ownItems: false)))
    }

    @Test func theAppsPlacedAreTheOnesInASlotOrOutOfTheWayAndNotContested() {
        let plan = VisibilityPlan(visibleBundleIDs: [one, two, own], concealedBundleIDs: [],
                                  visibleSystemItems: Set(VisibilityPlan.allSystemItems), concealedSections: [], source: .sections)
        func placed(_ read: Inventory, hidden: [String] = [], notDrawn: Set<String> = [], gate: UnattachedReadGate = .open) -> Set<String>? {
            StuckBar.appsPlaced(in: read, gate: gate, plan: plan, sections: sections(shown: [one, two].filter { !hidden.contains($0) }, hidden: hidden),
                                running: [one, two, own], notDrawn: notDrawn, ownBundleID: own)
        }
        #expect(placed(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()])) == [one, two])
        #expect(placed(Bar.read([Bar.item(one, .overflowed), Bar.item(two, .none), Bar.dot()])) == [one], "out of the way is placed; no slot isn't")
        #expect(placed(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()], contested: [one])) == [two])
        #expect(placed(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()]), hidden: [one]) == [two], "not in Shown")
        #expect(placed(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()]), notDrawn: [two]) == [one], "turned off")
        var closed = UnattachedReadGate.open
        closed.awake = false
        #expect(placed(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()]), gate: closed) == nil)
    }

    @Test func aReadThatCantSaySaysNothing() {
        let stuck = Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()])
        var closed = UnattachedReadGate.open
        closed.layoutWriteInProgress = true
        #expect(look(stuck, gate: closed) == .none)
        closed = .open
        closed.beingMadeAgain = true
        #expect(look(stuck, gate: closed) == .none)
        closed = .open
        closed.awake = false
        #expect(look(stuck, gate: closed) == .none)
        #expect(look(Bar.read([Bar.item(one, .none), Bar.item(two), Bar.dot()], problems: [.accessibilityNotGranted])) == .none)
        #expect(look(Bar.read([Bar.item(one), Bar.item(two), Bar.dot()])) == .whole)
    }
}

@Suite("Stuck bar: the watch", .timeLimit(.minutes(1)))
struct StuckBarWatchTests {
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let stuck = StuckBar.Look.stuck(StuckBarFinding(apps: [one, two], ownItems: false))
    private let suspects: [String: Set<pid_t>] = [one: pidOne, two: pidTwo]

    private func at(_ seconds: Double) -> Date { Self.origin.addingTimeInterval(seconds) }

    /// A watch for a change of displays at 0 s.
    private func changed() -> StuckBarWatch {
        var watch = StuckBarWatch()
        watch.changeHappened(at: at(0))
        return watch
    }

    @Test func nothingIsJudgedBeforeAChange() {
        var watch = StuckBarWatch()
        for seconds in stride(from: 0.0, through: 100, by: 10) { #expect(watch.look(stuck, at: at(seconds)) == .nothing) }
    }

    @Test func aRecoveryNeedsTwoLooksFiveSecondsApartAndTenSecondsAfterTheChange() {
        var watch = changed()
        #expect(watch.look(stuck, at: at(4)) == .nothing, "too soon after the change: it doesn't begin a run")
        #expect(watch.look(stuck, at: at(10)) == .nothing, "the first look")
        #expect(watch.look(stuck, at: at(12)) == .nothing, "too close to the first")
        #expect(watch.look(stuck, at: at(15)) == .recover(StuckBarFinding(apps: [one, two], ownItems: false), afterTheChange: 15))
    }

    @Test func onlyTheMeasuredShapeIsRestarted() {
        // One app alone, with the dots drawn, is never restarted by itself, however long it lasts.
        var alone = changed()
        let lone = StuckBar.Look.stuck(StuckBarFinding(apps: [one], ownItems: false))
        for seconds in stride(from: 10.0, through: 200, by: 5) { #expect(alone.look(lone, at: at(seconds)) == .nothing) }

        // Two apps, or Mantel's own items, are.
        var dots = changed()
        let dotsOnly = StuckBar.Look.stuck(StuckBarFinding(apps: [], ownItems: true))
        _ = dots.look(dotsOnly, at: at(10))
        #expect(dots.look(dotsOnly, at: at(16)) != .nothing)
        var oneAndDots = changed()
        let both = StuckBar.Look.stuck(StuckBarFinding(apps: [one], ownItems: true))
        _ = oneAndDots.look(both, at: at(10))
        #expect(oneAndDots.look(both, at: at(16)) != .nothing)

        // A single app between two looks of the shape ends the run.
        var between = changed()
        _ = between.look(stuck, at: at(10))
        #expect(between.look(lone, at: at(14)) == .nothing)
        #expect(between.look(stuck, at: at(20)) == .nothing, "a new run")
        #expect(between.look(stuck, at: at(26)) != .nothing)
    }

    @Test func aSingleAppAfterARestartIsStillJudged() {
        // The restart was made for two apps; one is still missing 10 seconds on: it didn't help.
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        _ = watch.look(stuck, at: at(16))
        watch.recoveryBegan(at: at(16))
        watch.recoveryEnded(at: at(20), suspects: suspects)
        let alone = StuckBar.Look.stuck(StuckBarFinding(apps: [one], ownItems: false))
        #expect(watch.look(alone, at: at(30)) == .didntHelp(StuckBarFinding(apps: [one], ownItems: false)))
    }

    @Test func aRecoveryRefusedForAReasonThatStaysIsNotDecidedAgainBeforeTheNextChange() {
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        guard case .recover = watch.look(stuck, at: at(16)) else {
            Issue.record("expected a recovery")
            return
        }
        watch.recoveryRefused()
        for seconds in stride(from: 26.0, through: 300, by: 10) { #expect(watch.look(stuck, at: at(seconds)) == .nothing) }
        #expect(!watch.didntHelp && !watch.holdsFlags, "nothing was restarted, so nothing is held or said")
        watch.changeHappened(at: at(400))
        _ = watch.look(stuck, at: at(410))
        #expect(watch.look(stuck, at: at(416)) != .nothing, "the next change is judged afresh")
    }

    @Test func aLookThatFindsTheBarWholeOrCantSayEndsTheRun() {
        var watch = changed()
        #expect(watch.look(stuck, at: at(10)) == .nothing)
        #expect(watch.look(.whole, at: at(14)) == .nothing)
        #expect(watch.look(stuck, at: at(20)) == .nothing, "a new run")
        #expect(watch.look(.none, at: at(22)) == .nothing)
        #expect(watch.look(stuck, at: at(30)) == .nothing, "a new run again")
        #expect(watch.look(stuck, at: at(36)) != .nothing)
    }

    @Test func aNewChangeStartsTheRunAgain() {
        var watch = changed()
        #expect(watch.look(stuck, at: at(10)) == .nothing)
        watch.changeHappened(at: at(12))
        #expect(watch.look(stuck, at: at(16)) == .nothing, "less than 10 seconds after the new change")
        #expect(watch.look(stuck, at: at(22)) == .nothing, "the first look after it")
        #expect(watch.look(stuck, at: at(28)) != .nothing)
    }

    @Test func oneRecoveryForEachChange() {
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        guard case .recover = watch.look(stuck, at: at(16)) else {
            Issue.record("expected a recovery")
            return
        }
        watch.recoveryBegan(at: at(16))
        watch.recoveryEnded(at: at(20), suspects: suspects)
        for seconds in stride(from: 21.0, through: 29, by: 2) { #expect(watch.look(stuck, at: at(seconds)) == .nothing) }
        // Judged 10 s on: still stuck.
        #expect(watch.look(stuck, at: at(30)) == .didntHelp(StuckBarFinding(apps: [one, two], ownItems: false)))
        #expect(watch.didntHelp)
        for seconds in stride(from: 40.0, through: 100, by: 10) { #expect(watch.look(stuck, at: at(seconds)) == .nothing) }
        // A restart that didn't help is no reason for another at the next change.
        watch.changeHappened(at: at(200))
        for seconds in stride(from: 210.0, through: 260, by: 6) { #expect(watch.look(stuck, at: at(seconds)) == .nothing) }
        #expect(watch.didntHelp)
    }

    @Test func aRecoveryThatDidntHelpHoldsBackEveryOtherUntilTheBarIsWhole() {
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        _ = watch.look(stuck, at: at(16))
        watch.recoveryBegan(at: at(16))
        watch.recoveryEnded(at: at(20), suspects: suspects)
        _ = watch.look(stuck, at: at(30))
        #expect(watch.didntHelp)

        // A change and a wake, and the pattern on every look: nothing.
        for change in [100.0, 300] {
            watch.changeHappened(at: at(change))
            for seconds in stride(from: change + 10, through: change + 60, by: 6) { #expect(watch.look(stuck, at: at(seconds)) == .nothing) }
        }
        #expect(watch.didntHelp)

        // The bar is seen whole: the note goes, and the change that came meanwhile has its recovery.
        #expect(watch.look(.whole, at: at(400)) == .nothing)
        #expect(!watch.didntHelp)
        _ = watch.look(stuck, at: at(410))
        #expect(watch.look(stuck, at: at(416)) != .nothing)
    }

    @Test func aResetAllowsARecoveryAtTheNextChange() {
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        _ = watch.look(stuck, at: at(16))
        watch.recoveryBegan(at: at(16))
        watch.recoveryEnded(at: at(20), suspects: suspects)
        _ = watch.look(stuck, at: at(30))
        watch.resetDone()
        watch.changeHappened(at: at(100))
        _ = watch.look(stuck, at: at(110))
        #expect(watch.look(stuck, at: at(116)) != .nothing)
    }

    @Test func theHoldOnFlagsIsSetByTheRestartAndStaysUntilTheBarIsSeenWholeOrAResetIsDone() {
        var watch = changed()
        #expect(!watch.holdsFlags)
        watch.recoveryBegan(at: at(16))
        #expect(watch.holdsFlags, "from the restart, before it ends")
        watch.recoveryEnded(at: at(20), suspects: suspects)
        #expect(watch.holdsFlags)
        #expect(watch.look(.whole, at: at(25)) == .nothing, "10 seconds haven't passed since it ended")
        #expect(watch.holdsFlags)
        _ = watch.look(stuck, at: at(31))
        #expect(watch.holdsFlags, "the note stands")
        _ = watch.look(.none, at: at(41))
        #expect(watch.holdsFlags)
        _ = watch.look(.whole, at: at(51))
        #expect(!watch.holdsFlags)

        var failed = changed()
        failed.recoveryBegan(at: at(16))
        failed.recoveryFailed(at: at(17), suspects: suspects)
        #expect(failed.holdsFlags)
        failed.resetDone()
        #expect(!failed.holdsFlags)
    }

    @Test func aRecoveryThatCouldntBeginEndsTheRun() {
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        guard case .recover = watch.look(stuck, at: at(16)) else {
            Issue.record("expected a recovery")
            return
        }
        watch.recoveryNotBegun()
        #expect(watch.look(stuck, at: at(26)) == .nothing, "one look after it isn't two in a row")
        #expect(watch.look(stuck, at: at(32)) != .nothing)
        #expect(!watch.holdsFlags)
    }

    @Test func threeInAnHourAtMost() {
        var watch = StuckBarWatch()
        var time = 0.0
        func cycle() -> StuckBarWatch.Verdict {
            watch.changeHappened(at: at(time))
            _ = watch.look(stuck, at: at(time + 10))
            let verdict = watch.look(stuck, at: at(time + 16))
            if case .recover = verdict {
                watch.recoveryBegan(at: at(time + 16))
                watch.recoveryEnded(at: at(time + 20), suspects: suspects)
                _ = watch.look(.whole, at: at(time + 31))
            }
            time += 100
            return verdict
        }
        for _ in 0..<3 {
            guard case .recover = cycle() else {
                Issue.record("expected a recovery")
                return
            }
        }
        #expect(cycle() == .limitReached)
        // Said once for the change, and nothing is restarted while the hour holds.
        #expect(watch.look(stuck, at: at(time - 100 + 40)) == .nothing)
        // An hour after the first one.
        time = 3600 + 100
        guard case .recover = cycle() else {
            Issue.record("expected a recovery after the hour")
            return
        }
    }

    @Test func theNoteStaysUntilTheBarIsWholeOrAResetIsDone() {
        var watch = changed()
        _ = watch.look(stuck, at: at(10))
        _ = watch.look(stuck, at: at(16))
        watch.recoveryBegan(at: at(16))
        watch.recoveryEnded(at: at(20), suspects: suspects)
        #expect(watch.look(.whole, at: at(25)) == .nothing, "10 seconds haven't passed")
        #expect(!watch.didntHelp)
        #expect(watch.look(stuck, at: at(31)) != .nothing)
        #expect(watch.didntHelp)
        #expect(watch.suspects(from: [:]) == suspects, "what is looked for is what was missing")
        #expect(watch.look(.none, at: at(41)) == .nothing)
        #expect(watch.didntHelp)
        #expect(watch.look(.whole, at: at(51)) == .nothing)
        #expect(!watch.didntHelp)
        #expect(watch.suspects(from: [:]).isEmpty)

        var failed = changed()
        failed.recoveryBegan(at: at(16))
        failed.recoveryFailed(at: at(17), suspects: suspects)
        #expect(failed.didntHelp)
        failed.resetDone()
        #expect(!failed.didntHelp)
        #expect(failed.look(stuck, at: at(100)) == .nothing, "a reset left nothing to judge")
    }

    @Test func aChangeBeforeTheRecoveryIsJudgedMovesTheJudgementAndAllowsNoOther() {
        var watch = changed()
        watch.recoveryBegan(at: at(16))
        watch.recoveryEnded(at: at(20), suspects: suspects)
        watch.changeHappened(at: at(22))
        #expect(watch.suspects(from: [:]) == suspects, "what was missing is still what is looked for")
        #expect(watch.look(stuck, at: at(31)) == .nothing, "10 seconds haven't passed since the change")
        #expect(!watch.didntHelp)
        #expect(watch.look(stuck, at: at(32)) == .didntHelp(StuckBarFinding(apps: [one, two], ownItems: false)))
        #expect(watch.look(stuck, at: at(50)) == .nothing)

        var whole = changed()
        whole.recoveryBegan(at: at(16))
        whole.recoveryEnded(at: at(20), suspects: suspects)
        whole.changeHappened(at: at(22))
        #expect(whole.look(.whole, at: at(32)) == .nothing)
        #expect(!whole.didntHelp && !whole.holdsFlags)
    }
}
