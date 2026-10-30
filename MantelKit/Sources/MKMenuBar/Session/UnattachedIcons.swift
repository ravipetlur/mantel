import CoreGraphics
import Foundation
import MKCore
import MKLayout

/// Whether a read of the menu bar can say something about an icon that macOS doesn't tie to its app: what was true about the bar when
/// it was taken.
///
/// An icon that macOS doesn't tie to its app is drawn by no assertion of the allowlist: while the allowlist is live and the rest of the
/// bar is drawn, it gets no slot. That only means something when an assertion really was live through the whole read, and the bar
/// was as the plan makes it.
public struct UnattachedReadGate: Sendable, Equatable {
    /// The engine in charge is the allowlist, with no `lastError`.
    public var allowlistInCharge: Bool
    /// `hiding.allowlist?.isArmed ?? false`, just before the scan started.
    public var armedBefore: Bool
    /// The same, just after it ended.
    public var armedAfter: Bool
    /// The session's `readShowsThePlan`.
    public var showsThePlan: Bool
    /// Nothing is revealed (`revealState == .collapsed`) and the plan is the sections' (sections or rules). A reveal that is shown in the
    /// second bar isn't nothing: a read then is not of a bar left alone.
    public var collapsed: Bool
    /// `sessionNow.isAwake`: the displays are on, the screen isn't locked and this user's session is on screen.
    public var awake: Bool
    /// A launch read, or the read taken for a change of displays, or one begun before the change: a bar being made.
    public var beingMadeAgain: Bool
    /// A write of macOS's order table is pending or its bar is settling: the bar is about to be, or is being, re-sorted.
    public var layoutWriteInProgress: Bool

    public init(allowlistInCharge: Bool, armedBefore: Bool, armedAfter: Bool, showsThePlan: Bool, collapsed: Bool, awake: Bool,
                beingMadeAgain: Bool, layoutWriteInProgress: Bool = false) {
        self.layoutWriteInProgress = layoutWriteInProgress
        self.allowlistInCharge = allowlistInCharge
        self.armedBefore = armedBefore
        self.armedAfter = armedAfter
        self.showsThePlan = showsThePlan
        self.collapsed = collapsed
        self.awake = awake
        self.beingMadeAgain = beingMadeAgain
    }

    /// The read can be evidence: all of the first six hold, the bar isn't being made again, and no layout write is pending or settling.
    public var isOpen: Bool {
        allowlistInCharge && armedBefore && armedAfter && showsThePlan && collapsed && awake && !beingMadeAgain && !layoutWriteInProgress
    }

    /// The read shows what is drawn with no assertion live (Show all icons, or the switches): an icon drawn then is tied to its app, or
    /// at least drawn. Only while the bar is seen.
    public var isSighting: Bool {
        awake && !armedBefore && !armedAfter
    }
}

/// What one read says of the Shown apps whose icons might not be tied to them.
public struct UnattachedIconEvidence: Sendable, Equatable {
    /// The candidates: considered apps with no slot on any bar, none out of the way, room for them, and no untied slot they could be.
    public let noSlot: Set<String>
    /// Considered apps with an item framed on a bar.
    public let inSlot: Set<String>
    /// Considered apps with none framed and one overflowed (behind the notch, say).
    public let outOfTheWay: Set<String>

    public init(noSlot: Set<String>, inSlot: Set<String>, outOfTheWay: Set<String>) {
        self.noSlot = noSlot
        self.inSlot = inSlot
        self.outOfTheWay = outOfTheWay
    }
}

public enum UnattachedIcons {
    /// How far an untied slot's width may be from the width of an icon's frame and still be taken for the slot that icon is drawn in,
    /// in points.
    static let untiedWidthTolerance: CGFloat = 6
    /// How much wider an icon's slot is than the frame its app reports for it (a slot has about 7 points of padding either side).
    static let slotPadding: CGFloat = 14

    /// What one read says, as far as it is a verdict on the apps that might have an icon macOS doesn't tie to them.
    public enum Assessment: Sendable, Equatable {
        /// Not evidence: the gate isn't open, or the agent didn't answer, or Accessibility isn't granted.
        case none
        /// The bar isn't drawing what it can, so what is missing from it is not one icon's doing (see `assess`). Every run of reads ends.
        case stuck
        case evidence(UnattachedIconEvidence)
    }

    /// What the read says of the apps that might have an icon macOS doesn't tie to them. Nil when the read isn't evidence (`assess`).
    public static func evidence(in read: Inventory, gate: UnattachedReadGate, plan: VisibilityPlan, sections: SectionModel,
                                running: Set<String>, notDrawn: Set<String>, ownBundleID: String,
                                fits: (String) -> Bool) -> UnattachedIconEvidence? {
        if case .evidence(let found) = assess(read, gate: gate, plan: plan, sections: sections, running: running, notDrawn: notDrawn,
                                              ownBundleID: ownBundleID, fits: fits) {
            return found
        }
        return nil
    }

    /// What the read says of the apps that might have an icon macOS doesn't tie to them. It is not evidence when:
    /// - the gate isn't open;
    /// - the agent didn't answer, or Accessibility isn't granted;
    /// - it is of a stuck bar, which is also when every run of reads ends: a bar that isn't drawing what it can (a lid that was opened
    ///   and closed leaves MenuBarAgent in that state) makes every app that is missing from it look like one macOS doesn't tie. The bar
    ///   is stuck when
    ///   - one of Mantel's own items, which the read lists, has no slot and isn't out of the way;
    ///   - two or more considered apps have no slot and aren't out of the way, whatever else holds them back, an app that is flagged
    ///     already, one whose width isn't known and one that is contested among them (nothing says there is no room: a stuck bar is not
    ///     one icon's doing);
    ///   - nothing else shows the bar is drawn: no considered app has a slot, and no dot of Mantel's is framed.
    ///
    /// An app is considered only when it is running; is not Mantel, a system item or one of Apple's (`com.apple.*` is always tied, and an
    /// assertion that hides it is the allowlist's known side effect); is in Shown and drawn by the plan; isn't concealed or turned off
    /// (`notDrawn`) or unanswered (this includes an app that refuses Accessibility); and lists an item. A candidate (`noSlot`) is also
    /// one that isn't contested (`Inventory.contestedApps`), is held by no untied slot and is predicted to fit.
    ///
    /// - Parameters:
    ///   - notDrawn: the apps the plan conceals and the apps whose switch is off in System Settings.
    ///   - fits: whether the app is predicted to have room on the bar (the session's `trialFits`).
    public static func assess(_ read: Inventory, gate: UnattachedReadGate, plan: VisibilityPlan, sections: SectionModel,
                              running: Set<String>, notDrawn: Set<String>, ownBundleID: String,
                              fits: (String) -> Bool) -> Assessment {
        guard gate.isOpen, read.agentAnswered, !read.problems.contains(.accessibilityNotGranted) else { return .none }
        // The bar is stuck when an item of Mantel's that is listed has no place on any bar and isn't out of the way.
        let ownItems = read.items.filter { $0.isMantel && $0.ownKind != nil }
        guard !ownItems.contains(where: { BarExpectation.framesOnABar(of: $0, in: read).isEmpty && $0.overflowedOn.isEmpty }) else { return .stuck }

        var inSlot: Set<String> = []
        var outOfTheWay: Set<String> = []
        var noSlot: Set<String> = []
        var missing = 0
        for app in consideredApps(in: read, plan: plan, sections: sections, running: running, notDrawn: notDrawn, ownBundleID: ownBundleID) {
            let items = read.items(ofApp: app)
            if items.contains(where: { !BarExpectation.framesOnABar(of: $0, in: read).isEmpty }) {
                // A contested app's frame may be a neighbour's slot: it says nothing of the app.
                if !read.contestedApps.contains(app) { inSlot.insert(app) }
            } else if items.contains(where: { $0.isOverflowed }) {
                if !read.contestedApps.contains(app) { outOfTheWay.insert(app) }
            } else {
                missing += 1
                if !read.contestedApps.contains(app), !isHeldByAnUntiedSlot(items, in: read), fits(app) { noSlot.insert(app) }
            }
        }
        guard missing < 2 else { return .stuck }
        let dotDrawn = read.items.contains { $0.isMantel && $0.isDot && !BarExpectation.framesOnABar(of: $0, in: read).isEmpty }
        guard !inSlot.isEmpty || dotDrawn else { return .stuck }
        return .evidence(UnattachedIconEvidence(noSlot: noSlot, inSlot: inSlot, outOfTheWay: outOfTheWay))
    }

    /// The apps a read can say something of (`assess`): running; not Mantel, a system item or one of Apple's; in Shown and drawn by the
    /// plan; not concealed or turned off (`notDrawn`); answered; and listing an item.
    static func consideredApps(in read: Inventory, plan: VisibilityPlan, sections: SectionModel, running: Set<String>, notDrawn: Set<String>,
                               ownBundleID: String) -> [String] {
        read.appsWithItems.filter { app in
            running.contains(app) && app != ownBundleID && !app.hasPrefix("com.apple.") && sections.section(ofApp: app) == .shown
                && plan.visibleBundleIDs.contains(app) && !notDrawn.contains(app) && !read.unansweredApps.contains(app)
        }
    }

    /// Whether a slot that nothing claimed could be the app's own icon, drawn but not matched: one whose width is the width of an item's
    /// frame (or that plus a slot's padding), or, when none of the items says a width, any untied slot at all. An app whose icon
    /// is drawn must not be taken for one that isn't, and a false flag switches engines.
    static func isHeldByAnUntiedSlot(_ items: [MenuBarItem], in read: Inventory) -> Bool {
        let slots = read.untiedSlots.values.flatMap { $0 }
        guard !slots.isEmpty else { return false }
        let widths = items.compactMap(\.reportedWidth).filter { $0 > 0 }
        guard !widths.isEmpty else { return true }
        return slots.contains { slot in
            widths.contains { slot.width >= $0 - untiedWidthTolerance && slot.width <= $0 + slotPadding + untiedWidthTolerance }
        }
    }

    /// The apps with an item framed on a bar: not Mantel's, and not the system's. An app that is contested isn't one: the frame that
    /// won a near tie may be another app's.
    public static func drawn(in read: Inventory) -> Set<String> {
        var apps: Set<String> = []
        for item in read.items where !item.isMantel && !item.id.isSystem && !BarExpectation.framesOnABar(of: item, in: read).isEmpty {
            apps.insert(item.ownerBundleID)
        }
        return apps.subtracting(read.contestedApps)
    }
}

/// Which running Shown apps have an icon that macOS doesn't tie to the app, as the reads of the menu bar say so: an app is flagged when
/// the same finding comes from reads 10 seconds apart, and the flag goes when it stops being true, or can no longer be.
public struct UnattachedIconTracker: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case flagged(String), clearedBySlot(String), clearedByQuit(String), clearedByNoItems(String), clearedTurnedOff(String)
    }

    /// When a candidate needs to have been seen drawn, with no assertion live, to be believed.
    public enum Sighting: Sendable, Equatable {
        /// Always: an icon that its app hides itself is listed, and never drawn, and must not be taken for an unattached one.
        case always
        /// While macOS's list of the apps it has turned off can't be read: an app that hides its own icon lists none (so isn't
        /// considered), and an app that is turned off is never drawn, and its list is what says so.
        case whileTurnedOffIsUnknown
    }

    /// One app's run of reads that find it with no slot.
    private struct Run: Sendable, Equatable {
        var pids: Set<pid_t>
        var reads: Int
        var firstReadAt: Date
    }

    public private(set) var flagged: Set<String> = []
    private let sighting: Sighting
    private var turnedOffIsKnown = false
    /// The processes of each app as they were when it was last seen drawn with no assertion live.
    private var sightings: [String: Set<pid_t>] = [:]
    private var runs: [String: Run] = [:]
    /// The processes of each app that had a slot, as an evidence read (the allowlist live) showed it.
    private var tied: [String: Set<pid_t>] = [:]
    /// The same, for the apps that had a slot before the last change of displays (or a wake) and haven't had one since. An icon macOS
    /// doesn't tie to its app never has a slot: this one lost it with the bar that was made again, so its missing slot is no evidence.
    /// It leaves when the app is in a slot again, when its process is another, and when `forgetAll` is called.
    private(set) var tiedBeforeAChange: [String: Set<pid_t>] = [:]
    /// The processes of the apps that were placed in the last accepted read (`StuckBar.appsPlaced`): in a slot or out of the way, as that
    /// read showed it. Replaced by each accepted read.
    private var placedInTheLastRead: [String: Set<pid_t>] = [:]
    /// A read was accepted since the last change of displays (or wake).
    private var readSinceTheChange = false
    /// The apps a stuck bar may have taken the slot from: the ones placed in the last accepted read before the last change of displays (or
    /// wake), in the same process, and not placed in any read since. Another set than `tiedBeforeAChange`, which is B1's and is as broad
    /// as "had a slot at some time": this one decides a restart, and an app that had no slot when the change came is never in it.
    private var suspectsOfAChange: [String: Set<pid_t>] = [:]
    /// A read was of a stuck bar since the last Reset: what the bar leaves out is no evidence from then on, for an app that has never had a
    /// slot with this Mantel as much as for any other. Only a Reset, which restarts MenuBarAgent, unsticks the bar.
    private var barWasStuck = false
    /// By flagged app: the reads in a row it was missing from the running apps, and the answered reads in a row that listed no item.
    private var goneReads: [String: Int] = [:]
    private var noItemReads: [String: Int] = [:]

    public init(sighting: Sighting) {
        self.sighting = sighting
    }

    /// The apps that had a slot in the last accepted read before the last change of displays (or a wake), and aren't placed since: the
    /// ones the change may have taken the slot from. Not one that is flagged: macOS doesn't tie that icon, and restarting MenuBarAgent
    /// doesn't change it. Each with its processes.
    var stuckBarSuspects: [String: Set<pid_t>] {
        suspectsOfAChange.filter { app, _ in !flagged.contains(app) }
    }

    /// What a read of the menu bar says: every read, evidence or not.
    ///
    /// - Parameters:
    ///   - evidence: what `UnattachedIcons.assess` made of it; nil when it isn't evidence.
    ///   - barLooksStuck: `assess` said the bar is stuck: every run of reads ends, as with a change of displays, and no app is flagged
    ///     after it until a Reset (flags already set keep their own rules).
    ///   - holdingFlags: no app is flagged, as after a read of a stuck bar: MenuBarAgent was restarted for a stuck bar and hasn't been
    ///     seen whole since (`StuckBarWatch.holdsFlags`).
    ///   - processes: the running apps' process IDs by bundle ID.
    public mutating func readTaken(_ read: Inventory, gate: UnattachedReadGate, evidence: UnattachedIconEvidence?,
                                   barLooksStuck: Bool = false, holdingFlags: Bool = false,
                                   processes: [String: Set<pid_t>]) -> [Change] {
        var changes: [Change] = []
        if gate.isSighting {
            for app in UnattachedIcons.drawn(in: read) {
                if let pids = processes[app], !pids.isEmpty { sightings[app] = pids }
            }
        }
        // A run is of one process: another one (or none) isn't continuing it. Nor does a read with the allowlist not in charge.
        for (app, run) in runs where processes[app] != run.pids { runs[app] = nil }
        if barLooksStuck { barWasStuck = true }
        if !gate.allowlistInCharge || barLooksStuck { runs.removeAll() }
        for (app, pids) in tiedBeforeAChange where processes[app] != pids { tiedBeforeAChange[app] = nil }
        for (app, pids) in suspectsOfAChange where processes[app] != pids { suspectsOfAChange[app] = nil }

        let answered = read.agentAnswered && !read.problems.contains(.accessibilityNotGranted)
        for app in flagged.sorted() {
            guard let pids = processes[app], !pids.isEmpty else {
                noItemReads[app] = nil
                goneReads[app, default: 0] += 1
                if goneReads[app, default: 0] >= AutoOverflowTracker.confirmingReads { changes.append(clear(app, as: .clearedByQuit(app))) }
                continue
            }
            goneReads[app] = nil
            guard answered, !read.unansweredApps.contains(app) else { continue }
            if read.items(ofApp: app).isEmpty {
                noItemReads[app, default: 0] += 1
                if noItemReads[app, default: 0] >= AutoOverflowTracker.confirmingReads { changes.append(clear(app, as: .clearedByNoItems(app))) }
            } else {
                noItemReads[app] = nil
            }
        }

        guard let evidence else { return changes }
        for app in evidence.inSlot.sorted() where flagged.contains(app) { changes.append(clear(app, as: .clearedBySlot(app))) }
        for app in evidence.inSlot.union(evidence.outOfTheWay) { runs[app] = nil }
        for app in evidence.inSlot {
            tiedBeforeAChange[app] = nil
            if let pids = processes[app], !pids.isEmpty { tied[app] = pids }
        }
        guard !barWasStuck, !holdingFlags else { return changes }
        let needsASighting = sighting == .always || !turnedOffIsKnown
        for app in evidence.noSlot.sorted() where !flagged.contains(app) {
            guard let pids = processes[app], !pids.isEmpty, !needsASighting || sightings[app] == pids else { continue }
            if tiedBeforeAChange[app] == pids {
                runs[app] = nil
                continue
            }
            var run = runs[app] ?? Run(pids: pids, reads: 0, firstReadAt: read.capturedAt)
            run.reads += 1
            if run.reads >= AutoOverflowTracker.confirmingReads,
               read.capturedAt.timeIntervalSince(run.firstReadAt) >= Self.confirmingTime {
                runs[app] = nil
                flagged.insert(app)
                changes.append(.flagged(app))
            } else {
                runs[app] = run
            }
        }
        return changes
    }

    /// The list of the apps macOS has turned off was read: an app on it loses its run and its flag. Nil while the list can't be read.
    public mutating func turnedOffListRead(_ apps: Set<String>?) -> [Change] {
        turnedOffIsKnown = apps != nil
        guard let apps else { return [] }
        var changes: [Change] = []
        for app in apps.sorted() {
            runs[app] = nil
            if flagged.contains(app) { changes.append(clear(app, as: .clearedTurnedOff(app))) }
        }
        return changes
    }

    /// The displays are changing, or the Mac woke: what was counted was of the bar as it was, so every run starts again, and an app
    /// that had a slot until now isn't taken for one that never has (the bar may be stuck, and a stuck bar lasts until a Reset). The flags
    /// stay.
    public mutating func displaysAreChanging() {
        runs.removeAll()
        tiedBeforeAChange.merge(tied) { _, new in new }
        // The suspects are the apps of the last accepted read, whatever came before it. With no read since the last change (two changes
        // close together, a sleep right after one) there is nothing newer to go by, and the suspects stay.
        if readSinceTheChange { suspectsOfAChange = placedInTheLastRead }
        readSinceTheChange = false
    }

    /// An accepted read (`StuckBar.appsPlaced`) placed these apps: in a slot or out of the way. They are the suspects of the next change
    /// if no accepted read comes before it, and no longer suspects of the last one: an app placed is in a slot again, or out of the way,
    /// and what it does after that is nothing of that change's.
    mutating func readPlaced(_ apps: Set<String>, processes: [String: Set<pid_t>]) {
        placedInTheLastRead = [:]
        for app in apps {
            guard let pids = processes[app], !pids.isEmpty else { continue }
            placedInTheLastRead[app] = pids
            suspectsOfAChange[app] = nil
        }
        readSinceTheChange = true
    }

    /// A manual Refresh: every flag and every run goes, and the apps are found again. What was known of the apps that had a slot, and
    /// that a read was of a stuck bar, stays: a Refresh doesn't restart MenuBarAgent, so it doesn't unstick the bar, and the memory is
    /// what tells a stuck bar from an icon that is never tied. What was seen drawn stays too: it is a fact about the processes.
    public mutating func forgetFlags() {
        flagged.removeAll()
        runs.removeAll()
        goneReads.removeAll()
        noItemReads.removeAll()
    }

    /// A Reset: what `forgetFlags` forgets, and also what was known of the apps that had a slot and that a read was of a stuck bar. A
    /// Reset restarts MenuBarAgent, which ties the apps afresh.
    public mutating func forgetAll() {
        forgetFlags()
        tied.removeAll()
        tiedBeforeAChange.removeAll()
        placedInTheLastRead.removeAll()
        suspectsOfAChange.removeAll()
        readSinceTheChange = false
        barWasStuck = false
    }

    /// The flagged apps Automatic is told of: those in Shown, and those automatic overflow moved to Hidden for room (their trials are
    /// judged under the switches, where they are drawn). The person's own move to Hidden isn't one. Whether they run isn't asked, so a
    /// quick relaunch changes nothing.
    public func forAutomatic(sections: SectionModel) -> Set<String> {
        flagged.filter { app in
            switch sections.section(ofApp: app) {
            case .shown: true
            case .hidden: sections.apps[app]?.isAuto ?? false
            case .alwaysHidden: false
            }
        }
    }

    // MARK: Inside

    /// The least time between the first read of a run and the one that flags the app, in seconds.
    private static var confirmingTime: TimeInterval {
        let interval = ScanScheduler.idleInterval.components
        return Double(interval.seconds) + Double(interval.attoseconds) / 1e18
    }

    private mutating func clear(_ app: String, as change: Change) -> Change {
        flagged.remove(app)
        runs[app] = nil
        goneReads[app] = nil
        noItemReads[app] = nil
        return change
    }
}
