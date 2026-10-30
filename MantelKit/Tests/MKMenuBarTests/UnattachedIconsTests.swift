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
private let three = "com.example.three"

/// What the tests of the evidence and the tracker read: apps with or without a place on one bar, Mantel's dot, and the slots nobody
/// claimed. Every bundle ID is a synthetic one.
private enum Bar {
    static let geometry = MenuBarGeometry(displayUUID: display, rect: CGRect(x: 0, y: 0, width: 3000, height: 30), notch: nil)
    static let onTheBar = CGRect(x: 100, y: 0, width: 38, height: 30)
    /// Where macOS parks an icon it isn't drawing.
    static let parked = CGRect(x: 7, y: 1878, width: 24, height: 24)

    enum Place {
        case slot, none, overflowed, parked
    }

    static func item(_ bundleID: String, _ place: Place = .slot, name: String = "main", width: CGFloat? = 24) -> MenuBarItem {
        let frames: [String: CGRect] = switch place {
        case .slot: [display: onTheBar]
        case .parked: [display: parked]
        case .none, .overflowed: [:]
        }
        return MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier(name)), ownerBundleID: bundleID, appName: nil, label: nil,
                           frames: frames, overflowedOn: place == .overflowed ? [display] : [], isMantel: false, reportedWidth: width)
    }

    static func dot(framed: Bool = true, kind: OwnItemKind = .hiddenDot) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: own, key: .identifier("mantel.dot")), ownerBundleID: own, appName: nil, label: nil,
                    frames: framed ? [display: CGRect(x: 40, y: 0, width: 24, height: 30)] : [:], overflowedOn: [], isMantel: true,
                    ownKind: kind)
    }

    static func read(_ items: [MenuBarItem], at seconds: Double = 0, problems: [InventoryProblem] = [], unanswered: Set<String> = [],
                     untied: [CGRect] = [], contested: Set<String> = []) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds), bars: [geometry], items: items, chevrons: [:], reach: [],
                  problems: problems, unansweredApps: unanswered, untiedSlots: untied.isEmpty ? [:] : [display: untied],
                  contestedApps: contested)
    }

    static func plan(shown: [String]) -> VisibilityPlan {
        VisibilityPlan(visibleBundleIDs: Set(shown).union([own]), concealedBundleIDs: [],
                       visibleSystemItems: Set(VisibilityPlan.allSystemItems), concealedSections: [], source: .sections)
    }
}

private extension UnattachedReadGate {
    /// A read the allowlist was live through, of a bar as the plan makes it.
    static let open = UnattachedReadGate(allowlistInCharge: true, armedBefore: true, armedAfter: true, showsThePlan: true, collapsed: true,
                                         awake: true, beingMadeAgain: false)
    /// A read with no assertion live.
    static let sighting = UnattachedReadGate(allowlistInCharge: false, armedBefore: false, armedAfter: false, showsThePlan: true,
                                             collapsed: true, awake: true, beingMadeAgain: false)
}

@Suite("Unattached icons: the evidence", .timeLimit(.minutes(1)))
struct UnattachedIconEvidenceTests {
    private func evidence(_ read: Inventory, gate: UnattachedReadGate = .open, shown: [String] = [one, two], hidden: [String] = [],
                          running: Set<String>? = nil, notDrawn: Set<String> = [], fits: Bool = true) -> UnattachedIconEvidence? {
        UnattachedIcons.evidence(in: read, gate: gate, plan: Bar.plan(shown: shown), sections: sections(shown: shown, hidden: hidden),
                                 running: running ?? Set(shown + hidden), notDrawn: notDrawn, ownBundleID: own, fits: { _ in fits })
    }

    private func assess(_ read: Inventory, gate: UnattachedReadGate = .open, shown: [String] = [one, two],
                        fits: @escaping (String) -> Bool = { _ in true }) -> UnattachedIcons.Assessment {
        UnattachedIcons.assess(read, gate: gate, plan: Bar.plan(shown: shown), sections: sections(shown: shown), running: Set(shown),
                               notDrawn: [], ownBundleID: own, fits: fits)
    }

    @Test func noEvidenceWithNothingElseDrawn() {
        #expect(evidence(Bar.read([Bar.item(two, .none)]), shown: [two]) == nil)
        // A dot with no frame doesn't show it either (and it is a stuck bar, see below).
        #expect(evidence(Bar.read([Bar.dot(framed: false), Bar.item(two, .none)]), shown: [two]) == nil)
    }

    struct Closing: CustomTestStringConvertible, Sendable {
        let name: String
        let close: @Sendable (inout UnattachedReadGate) -> Void
        var testDescription: String { name }
    }

    static let closings: [Closing] = [
        Closing(name: "allowlistInCharge") { $0.allowlistInCharge = false },
        Closing(name: "armedBefore") { $0.armedBefore = false },
        Closing(name: "armedAfter") { $0.armedAfter = false },
        Closing(name: "showsThePlan") { $0.showsThePlan = false },
        Closing(name: "collapsed") { $0.collapsed = false },
        Closing(name: "awake") { $0.awake = false },
        Closing(name: "beingMadeAgain") { $0.beingMadeAgain = true },
        // A write of macOS's order table is pending or its bar is settling: the bar is about to be, or is being, re-sorted.
        Closing(name: "layoutWriteInProgress") { $0.layoutWriteInProgress = true },
    ]

    @Test(arguments: closings) func noEvidenceWhenTheGateIsClosed(_ closing: Closing) {
        let read = Bar.read([Bar.item(one), Bar.item(two, .none)])
        #expect(evidence(read) != nil)
        var gate = UnattachedReadGate.open
        closing.close(&gate)
        #expect(!gate.isOpen)
        #expect(evidence(read, gate: gate) == nil)
    }

    @Test func noEvidenceWithoutAnAnswerOrAccessibility() {
        let items = [Bar.item(one), Bar.item(two, .none)]
        #expect(evidence(Bar.read(items, problems: [.agentNotRunning])) == nil)
        #expect(evidence(Bar.read(items, problems: [.agentHasNoWindows])) == nil)
        #expect(evidence(Bar.read(items, problems: [.accessibilityNotGranted])) == nil)
        // A read that couldn't tell which copy of the bar is current still has a bar to look at.
        #expect(evidence(Bar.read(items, problems: [.ambiguousSpace])) != nil)
    }

    @Test func anUntiedSlotOfTheCandidatesWidthHoldsIt() {
        let items = [Bar.item(one), Bar.item(two, .none, width: 24)]
        // As wide as the icon's frame, or as wide as the slot an icon of that frame has (a slot has padding): the icon may be drawn there.
        for width in [24, 26, 38, 44] as [CGFloat] {
            let found = evidence(Bar.read(items, untied: [CGRect(x: 300, y: 0, width: width, height: 30)]))
            #expect(found?.noSlot.isEmpty == true, "a slot \(width) wide")
            #expect(found?.inSlot == [one])
        }
        // An item that says no width: any untied slot holds it.
        let unknown = [Bar.item(one), Bar.item(two, .none, width: nil)]
        #expect(evidence(Bar.read(unknown, untied: [CGRect(x: 300, y: 0, width: 90, height: 30)]))?.noSlot.isEmpty == true)
        #expect(evidence(Bar.read(unknown))?.noSlot == [two])
    }

    @Test func aCandidateWithNoRoomIsHeld() {
        let read = Bar.read([Bar.item(one), Bar.item(two, .none)])
        let found = evidence(read, fits: false)
        #expect(found == UnattachedIconEvidence(noSlot: [], inSlot: [one], outOfTheWay: []))
    }

    @Test func applesOwnProcessesAreNeverConsidered() {
        let apple = "com.apple.example"
        let read = Bar.read([Bar.item(one), Bar.item(apple, .none)])
        let found = evidence(read, shown: [one, apple])
        #expect(found == UnattachedIconEvidence(noSlot: [], inSlot: [one], outOfTheWay: []))
    }

    struct NotConsidered: CustomTestStringConvertible, Sendable {
        let name: String
        let read: Inventory
        let hidden: [String]
        let running: Set<String>?
        let notDrawn: Set<String>
        var testDescription: String { name }
    }

    static let notConsidered: [NotConsidered] = {
        let items = [Bar.item(one), Bar.item(two, .none)]
        return [
            NotConsidered(name: "concealed or turned off", read: Bar.read(items), hidden: [], running: nil, notDrawn: [two]),
            NotConsidered(name: "unanswered", read: Bar.read(items, unanswered: [two]), hidden: [], running: nil, notDrawn: []),
            NotConsidered(name: "not running", read: Bar.read(items), hidden: [], running: [one], notDrawn: []),
            NotConsidered(name: "in Hidden", read: Bar.read(items), hidden: [two], running: nil, notDrawn: []),
        ]
    }()

    // MARK: A bar that isn't drawing what it can

    @Test func aStuckBarOfMantelsOwnIsNoEvidence() {
        // Mantel's own icon is listed and has no slot, and isn't out of the way: the bar is stuck (MenuBarAgent kept an older layout), and
        // every app that is missing from it looks the same as one macOS doesn't tie to its app.
        let items = [Bar.item(one), Bar.item(two, .none), Bar.dot(framed: false, kind: .alwaysDot)]
        #expect(evidence(Bar.read(items)) == nil)
        // An own icon that is out of the way (behind the notch) is not stuck.
        let behindTheNotch = MenuBarItem(id: ItemID(bundleID: own, key: .identifier("mantel.dot")), ownerBundleID: own, appName: nil, label: nil,
                                         frames: [:], overflowedOn: [display], isMantel: true, ownKind: .alwaysDot)
        #expect(evidence(Bar.read([Bar.item(one), Bar.item(two, .none), behindTheNotch])) != nil)
        // And an icon of Mantel's that is drawn is no sign of one.
        #expect(evidence(Bar.read([Bar.item(one), Bar.item(two, .none), Bar.dot()])) != nil)
    }

    @Test func twoAppsWithNoSlotAtOnceAreNoEvidence() {
        // Allowed Shown apps that are missing in the same read say the bar isn't drawing them: not one icon's doing. An app that is held
        // back for any other reason still counts as missing: with no known width, with an untied slot near its width, or contested.
        let read = Bar.read([Bar.item(one), Bar.item(two, .none), Bar.item(three, .none)])
        let all = [one, two, three]
        #expect(evidence(read, shown: all) == nil)
        #expect(assess(read, shown: all) == .stuck)
        // A width that isn't known, or that has no room, holds one of them back: the other is not a candidate by itself.
        #expect(assess(read, shown: all, fits: { $0 == two }) == .stuck, "the other's width is unknown")
        #expect(assess(read, shown: all, fits: { _ in false }) == .stuck)
        // An untied slot of its width holds one of them.
        let held = Bar.read([Bar.item(one), Bar.item(two, .none, width: 24), Bar.item(three, .none, width: 50)],
                            untied: [CGRect(x: 300, y: 0, width: 50, height: 30)])
        #expect(assess(held, shown: all) == .stuck)
        #expect(evidence(held, shown: all) == nil)
        // One of them contests a slot.
        let contested = Bar.read([Bar.item(one), Bar.item(two, .none), Bar.item(three, .none)], contested: [three])
        #expect(assess(contested, shown: all) == .stuck)
        // Each of the two, with the other present, is a candidate by itself.
        #expect(evidence(Bar.read([Bar.item(one), Bar.item(two, .none), Bar.item(three)]), shown: all)?.noSlot == [two])
        // An app that is flagged already is missing too (the read doesn't know the flags): a second one that goes missing is the stuck bar.
        #expect(assess(read, shown: all) == .stuck)
    }
}

@Suite("Unattached icons: the tracker", .timeLimit(.minutes(1)))
struct UnattachedIconTrackerTests {
    private func tracker(_ sighting: UnattachedIconTracker.Sighting = .whileTurnedOffIsUnknown, listKnown: Bool = true) -> UnattachedIconTracker {
        var tracker = UnattachedIconTracker(sighting: sighting)
        if listKnown { _ = tracker.turnedOffListRead([]) }
        return tracker
    }

    private func noSlot(_ apps: String...) -> UnattachedIconEvidence {
        UnattachedIconEvidence(noSlot: Set(apps), inSlot: [], outOfTheWay: [])
    }

    private func processes(_ pid: pid_t = 100, apps: [String] = [two]) -> [String: Set<pid_t>] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0, [pid]) })
    }

    /// A read at `seconds` in which the app has no slot.
    private func take(_ tracker: inout UnattachedIconTracker, at seconds: Double, evidence: UnattachedIconEvidence? = nil,
                      gate: UnattachedReadGate = .open, items: [MenuBarItem]? = nil, problems: [InventoryProblem] = [],
                      unanswered: Set<String> = [], processes: [String: Set<pid_t>]? = nil) -> [UnattachedIconTracker.Change] {
        let read = Bar.read(items ?? [Bar.item(one), Bar.item(two, .none)], at: seconds, problems: problems, unanswered: unanswered)
        return tracker.readTaken(read, gate: gate, evidence: evidence, processes: processes ?? self.processes())
    }

    private func flagged(_ tracker: UnattachedIconTracker) -> Set<String> { tracker.flagged }

    @Test func flaggedAtTheSecondReadTenSecondsAfterTheFirst() {
        var tracker = tracker()
        #expect(take(&tracker, at: 0, evidence: noSlot(two)).isEmpty)
        #expect(take(&tracker, at: 10, evidence: noSlot(two)) == [.flagged(two)], "the second read, 10 s after the first")
        #expect(tracker.flagged == [two])

        // 9.9 s isn't enough, and the third read at 10 s is.
        var other = self.tracker()
        #expect(take(&other, at: 0, evidence: noSlot(two)).isEmpty)
        #expect(take(&other, at: 9.9, evidence: noSlot(two)).isEmpty)
        #expect(other.flagged.isEmpty)
        #expect(take(&other, at: 10, evidence: noSlot(two)) == [.flagged(two)])
    }

    @Test func aSlotOrOutOfTheWayEndsTheRun() {
        for ending in [UnattachedIconEvidence(noSlot: [], inSlot: [two], outOfTheWay: []),
                       UnattachedIconEvidence(noSlot: [], inSlot: [], outOfTheWay: [two])] {
            var tracker = tracker()
            #expect(take(&tracker, at: 0, evidence: noSlot(two)).isEmpty)
            #expect(take(&tracker, at: 5, evidence: ending).isEmpty)
            // The run starts again at 10: 10 s later it is flagged, and not before.
            #expect(take(&tracker, at: 10, evidence: noSlot(two)).isEmpty)
            #expect(take(&tracker, at: 15, evidence: noSlot(two)).isEmpty)
            #expect(tracker.flagged.isEmpty)
            #expect(take(&tracker, at: 20, evidence: noSlot(two)) == [.flagged(two)])
        }
    }

    @Test func displayChangeEndsEveryRun() {
        var tracker = tracker()
        #expect(take(&tracker, at: 0, evidence: noSlot(two)).isEmpty)
        tracker.displaysAreChanging()
        #expect(take(&tracker, at: 10, evidence: noSlot(two)).isEmpty, "the run began again")
        #expect(take(&tracker, at: 20, evidence: noSlot(two)) == [.flagged(two)])
        // A flag stays through a change of displays.
        tracker.displaysAreChanging()
        #expect(tracker.flagged == [two])
    }

    private func stuckRead(_ tracker: inout UnattachedIconTracker, at seconds: Double) -> [UnattachedIconTracker.Change] {
        // A second app missing: the bar isn't drawing what it can.
        let read = Bar.read([Bar.item(one), Bar.item(two, .none), Bar.item(three, .none)], at: seconds)
        return tracker.readTaken(read, gate: .open, evidence: nil, barLooksStuck: true, processes: processes(apps: [two, three]))
    }

    @Test func aStuckReadEndsEveryRunAndHoldsEveryNewFlagUntilAReset() {
        var tracker = tracker()
        #expect(take(&tracker, at: 0, evidence: noSlot(two)).isEmpty)
        // A read of a stuck bar says nothing of the app, and the run that began before it is no more.
        #expect(stuckRead(&tracker, at: 5).isEmpty)
        // The bar stays as it is until a Reset: an app that is missing alone from it isn't flagged, however many reads say so.
        for seconds in stride(from: 10.0, through: 100.0, by: 10.0) {
            #expect(take(&tracker, at: seconds, evidence: noSlot(two)).isEmpty)
        }
        #expect(tracker.flagged.isEmpty)

        // A Refresh doesn't restart MenuBarAgent: it forgets the flags, and the bar is as stuck as it was.
        tracker.forgetFlags()
        #expect(take(&tracker, at: 110, evidence: noSlot(two)).isEmpty)
        #expect(take(&tracker, at: 120, evidence: noSlot(two)).isEmpty)
        #expect(tracker.flagged.isEmpty)

        // A Reset does. An app that has no slot is flagged again, by a run of its own.
        tracker.forgetAll()
        #expect(take(&tracker, at: 130, evidence: noSlot(two)).isEmpty)
        #expect(take(&tracker, at: 140, evidence: noSlot(two)) == [.flagged(two)])
    }

    @Test func aRefreshKeepsWhatHadASlotAndAResetForgetsIt() {
        let drawn = UnattachedIconEvidence(noSlot: [], inSlot: [two], outOfTheWay: [])
        var tracker = tracker()
        _ = take(&tracker, at: 0, evidence: drawn)
        tracker.displaysAreChanging()
        // The stuck bar leaves the app missing, and the person presses Refresh, which doesn't unstick it: the app isn't flagged.
        _ = take(&tracker, at: 10, evidence: noSlot(two))
        tracker.forgetFlags()
        for seconds in stride(from: 20.0, through: 80.0, by: 10.0) {
            #expect(take(&tracker, at: seconds, evidence: noSlot(two)).isEmpty)
        }
        #expect(tracker.flagged.isEmpty)
        // After a Reset what was known is gone, and an app with no slot is flagged.
        tracker.forgetAll()
        #expect(take(&tracker, at: 90, evidence: noSlot(two)).isEmpty)
        #expect(take(&tracker, at: 100, evidence: noSlot(two)) == [.flagged(two)])
    }

    // MARK: Who a stuck bar may be blamed on

    @Test func theSuspectsAreTheAppsPlacedInTheLastReadBeforeTheChange() {
        var tracker = tracker()
        tracker.readPlaced([one, two], processes: processes(apps: [one, two]))
        #expect(tracker.stuckBarSuspects.isEmpty, "a change is what makes it one")
        tracker.displaysAreChanging()
        #expect(tracker.stuckBarSuspects == [one: [100], two: [100]])
        tracker.readPlaced([two], processes: processes(apps: [one, two]))
        #expect(tracker.stuckBarSuspects == [one: [100]], "in a slot again, or out of the way: not the change's loss")
    }

    @Test func allowlistNotInChargeEndsEveryRun() {
        var tracker = tracker()
        #expect(take(&tracker, at: 0, evidence: noSlot(two)).isEmpty)
        var notInCharge = UnattachedReadGate.open
        notInCharge.allowlistInCharge = false
        #expect(take(&tracker, at: 5, evidence: nil, gate: notInCharge).isEmpty)
        #expect(take(&tracker, at: 10, evidence: noSlot(two)).isEmpty, "a new run")
        #expect(take(&tracker, at: 20, evidence: noSlot(two)) == [.flagged(two)])
    }

    @Test func clearsWhenItsItemGetsASlot() {
        var tracker = tracker()
        _ = take(&tracker, at: 0, evidence: noSlot(two))
        _ = take(&tracker, at: 10, evidence: noSlot(two))
        #expect(tracker.flagged == [two])
        let changes = take(&tracker, at: 20, evidence: UnattachedIconEvidence(noSlot: [], inSlot: [two], outOfTheWay: []))
        #expect(changes == [.clearedBySlot(two)])
        #expect(tracker.flagged.isEmpty)
    }

    private func flaggedTracker(_ sighting: UnattachedIconTracker.Sighting = .whileTurnedOffIsUnknown) -> UnattachedIconTracker {
        var tracker = tracker(sighting)
        _ = take(&tracker, at: 0, evidence: noSlot(two))
        _ = take(&tracker, at: 10, evidence: noSlot(two))
        return tracker
    }

    @Test func aQuickRelaunchKeepsTheFlag() {
        var tracker = flaggedTracker()
        #expect(tracker.flagged == [two])
        // One read with the app gone, and the next with it back as another process.
        #expect(take(&tracker, at: 20, processes: [:]).isEmpty)
        #expect(take(&tracker, at: 30, processes: processes(300)).isEmpty)
        #expect(tracker.flagged == [two])
        // A read of the app gone, then back, then gone: the count is of reads in a row.
        #expect(take(&tracker, at: 40, processes: [:]).isEmpty)
        #expect(take(&tracker, at: 50, processes: processes(300)).isEmpty)
        #expect(take(&tracker, at: 60, processes: [:]).isEmpty)
        #expect(tracker.flagged == [two])
    }

    @Test func turnedOffAppIsNeverFlaggedAndLosesItsFlag() {
        var tracker = tracker()
        #expect(take(&tracker, at: 0, evidence: noSlot(two)).isEmpty)
        #expect(tracker.turnedOffListRead([two]).isEmpty, "a run that is ended is not a change")
        #expect(take(&tracker, at: 10, evidence: noSlot(two)).isEmpty, "a run of its own: the first read of it")
        #expect(tracker.flagged.isEmpty)

        var flagged = flaggedTracker()
        #expect(flagged.turnedOffListRead([two]) == [.clearedTurnedOff(two)])
        #expect(flagged.flagged.isEmpty)
        #expect(flagged.turnedOffListRead([two]).isEmpty)
    }

    // MARK: The sighting

    private func sightingRead(_ tracker: inout UnattachedIconTracker, at seconds: Double, pid: pid_t = 100) {
        _ = tracker.readTaken(Bar.read([Bar.item(one), Bar.item(two)], at: seconds), gate: .sighting, evidence: nil, processes: processes(pid))
    }

    @Test func aSightingIsNeededOnlyWhileTheTurnedOffListIsUnknown() {
        // The list can't be read: a candidate needs to have been drawn with no assertion live.
        var unknown = tracker(.whileTurnedOffIsUnknown, listKnown: false)
        #expect(unknown.turnedOffListRead(nil).isEmpty)
        _ = take(&unknown, at: 0, evidence: noSlot(two))
        #expect(take(&unknown, at: 10, evidence: noSlot(two)).isEmpty, "never sighted")
        sightingRead(&unknown, at: 15)
        _ = take(&unknown, at: 20, evidence: noSlot(two))
        #expect(take(&unknown, at: 30, evidence: noSlot(two)) == [.flagged(two)], "sighted")

        // The list is readable: no sighting is asked for.
        var known = tracker(.whileTurnedOffIsUnknown, listKnown: true)
        _ = take(&known, at: 0, evidence: noSlot(two))
        #expect(take(&known, at: 10, evidence: noSlot(two)) == [.flagged(two)])

        // And it is asked for again when the list can't be read any more.
        var lost = tracker(.whileTurnedOffIsUnknown, listKnown: true)
        _ = lost.turnedOffListRead(nil)
        _ = take(&lost, at: 0, evidence: noSlot(two))
        #expect(take(&lost, at: 10, evidence: noSlot(two)).isEmpty)
    }
}
