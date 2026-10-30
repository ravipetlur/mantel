import CoreGraphics
import Foundation
import MKCore
import MKLayout

/// What a read finds wrong with a menu bar that MenuBarAgent has left stuck after a change of displays: icons that should be drawn and
/// aren't, with room for them. The lid of a laptop that was opened and closed again leaves the main display with the layout of the
/// notched bar, and only a restart of MenuBarAgent puts it right.
public struct StuckBarFinding: Sendable, Equatable {
    /// The apps that had a slot before the change, in the same process, and have none now though the bar has room for them.
    public var apps: Set<String>
    /// One of Mantel's own items that is listed has no slot, with room for it.
    public var ownItems: Bool

    public init(apps: Set<String>, ownItems: Bool) {
        self.apps = apps
        self.ownItems = ownItems
    }

    public var isEmpty: Bool {
        apps.isEmpty && !ownItems
    }

    /// The measured shape, the only one that is restarted: two or more apps with no slot, or one of Mantel's own items. A single app
    /// alone, with Mantel's dots drawn, isn't: the stuck bar that was measured had dropped every item past the notched bar's count,
    /// and a lone app with no slot may be switched off in System Settings, or hidden by its own app, with nothing in the read to say so.
    /// The person's Reset puts such a bar right, as before this was built.
    public var warrantsARestart: Bool {
        apps.count >= 2 || ownItems
    }
}

public enum StuckBar {
    /// What one read says.
    public enum Look: Sendable, Equatable {
        /// The read can't say: the gate isn't open (`UnattachedReadGate`), the agent didn't answer, or Accessibility isn't granted.
        case none
        /// The read can say, and the bar is as it should be.
        case whole
        case stuck(StuckBarFinding)
    }

    /// The considered apps (`UnattachedIcons.consideredApps`) that have no slot on any bar, with room for them: not out of the way (behind
    /// the notch, under the front app's menus), not contested, and not held by an untied slot that could be their own. An app whose width
    /// was never seen is taken not to have room. Nil when the read can't say: the gate isn't open (`UnattachedReadGate`), the agent didn't
    /// answer or Accessibility isn't granted.
    ///
    /// An untied slot is one app's at most: the apps it could be are excused only while they are no more than the untied slots. More
    /// of them than that, and some of them are missing whatever the slots are.
    ///
    /// - Parameter fits: whether the app is predicted to have room on the bar (the session's `trialFits`).
    public static func appsWithNoSlot(in read: Inventory, gate: UnattachedReadGate, plan: VisibilityPlan, sections: SectionModel,
                                      running: Set<String>, notDrawn: Set<String>, ownBundleID: String,
                                      fits: (String) -> Bool) -> Set<String>? {
        guard gate.isOpen, read.agentAnswered, !read.problems.contains(.accessibilityNotGranted) else { return nil }
        var noSlot: Set<String> = []
        var couldBeUntied: Set<String> = []
        for app in UnattachedIcons.consideredApps(in: read, plan: plan, sections: sections, running: running, notDrawn: notDrawn,
                                                  ownBundleID: ownBundleID) {
            let items = read.items(ofApp: app)
            guard !read.contestedApps.contains(app),
                  !items.contains(where: { !BarExpectation.framesOnABar(of: $0, in: read).isEmpty || $0.isOverflowed }), fits(app) else { continue }
            if UnattachedIcons.isHeldByAnUntiedSlot(items, in: read) { couldBeUntied.insert(app) } else { noSlot.insert(app) }
        }
        if couldBeUntied.count > read.untiedSlots.values.reduce(0, { $0 + $1.count }) { noSlot.formUnion(couldBeUntied) }
        return noSlot
    }

    /// The considered apps (`UnattachedIcons.consideredApps`) that are placed in a read: not contested, and with an item framed on a bar or
    /// out of the way (overflowed, behind the notch: the bar that was made for the lid open leaves them there, and it is where they were
    /// when the lid closed). The apps a change may take the slot from are the ones the last such read placed
    /// (`UnattachedIconTracker.readPlaced`); an app that wasn't placed in it (no room, in Hidden, contested, no slot) isn't one. Nil when
    /// the read can't say, as for `appsWithNoSlot`.
    public static func appsPlaced(in read: Inventory, gate: UnattachedReadGate, plan: VisibilityPlan, sections: SectionModel,
                                  running: Set<String>, notDrawn: Set<String>, ownBundleID: String) -> Set<String>? {
        guard gate.isOpen, read.agentAnswered, !read.problems.contains(.accessibilityNotGranted) else { return nil }
        return Set(UnattachedIcons.consideredApps(in: read, plan: plan, sections: sections, running: running, notDrawn: notDrawn,
                                                  ownBundleID: ownBundleID).filter { app in
            !read.contestedApps.contains(app)
                && read.items(ofApp: app).contains { !BarExpectation.framesOnABar(of: $0, in: read).isEmpty || $0.isOverflowed }
        })
    }

    /// What a read says of the bar: stuck when a suspect has no slot though the bar has room for it, or one of Mantel's own items that is
    /// listed has none (and isn't out of the way). An app that never had a slot (an icon macOS doesn't tie to its app), or lost it for
    /// a reason of its own, is no suspect: the caller leaves it out of `hadASlot`.
    ///
    /// - Parameters:
    ///   - hadASlot: the processes of the apps that had a slot in the last accepted read before the change
    ///     (`UnattachedIconTracker.stuckBarSuspects`).
    ///   - processes: the running apps' process IDs by bundle ID.
    ///   - fits: whether the app is predicted to have room on the bar (the session's `trialFits`).
    public static func look(at read: Inventory, gate: UnattachedReadGate, plan: VisibilityPlan, sections: SectionModel,
                            running: Set<String>, notDrawn: Set<String>, ownBundleID: String, hadASlot: [String: Set<pid_t>],
                            processes: [String: Set<pid_t>], fits: (String) -> Bool) -> Look {
        guard let noSlot = appsWithNoSlot(in: read, gate: gate, plan: plan, sections: sections, running: running, notDrawn: notDrawn,
                                          ownBundleID: ownBundleID, fits: fits) else { return .none }
        return look(noSlot: noSlot, in: read, ownBundleID: ownBundleID, notDrawn: notDrawn, hadASlot: hadASlot, processes: processes,
                    fits: fits)
    }

    /// `look(at:...)` for a read whose apps with no slot (`appsWithNoSlot`) are known. Mantel's own items are no finding while Mantel is
    /// turned off (`notDrawn` has it): they are listed and never drawn.
    public static func look(noSlot: Set<String>, in read: Inventory, ownBundleID: String, notDrawn: Set<String>,
                            hadASlot: [String: Set<pid_t>], processes: [String: Set<pid_t>], fits: (String) -> Bool) -> Look {
        let missing = noSlot.filter { app in
            guard let pids = hadASlot[app], !pids.isEmpty else { return false }
            return processes[app] == pids
        }
        let ownItems = read.items.contains { item in
            item.isMantel && item.ownKind != nil && BarExpectation.framesOnABar(of: item, in: read).isEmpty && item.overflowedOn.isEmpty
        } && !notDrawn.contains(ownBundleID) && fits(ownBundleID)
        let finding = StuckBarFinding(apps: missing, ownItems: ownItems)
        return finding.isEmpty ? .whole : .stuck(finding)
    }
}

/// When a stuck bar is restarted, as a pure decision over the looks the session takes: never when the bar isn't stuck (a restart blinks
/// the person's menu bar), and when in doubt, not.
///
/// - **A change comes first.** Nothing is judged until the displays changed or the Mac woke (`changeHappened`), and the bar is looked at
///   only from `settleTime` after the last such change.
/// - **Two looks in a row.** The pattern has to hold on two looks at least `confirmGap` apart, with no look between them that couldn't
///   say or found the bar whole.
/// - **The measured shape only.** The pattern has to be two or more apps, or one of Mantel's own items (`StuckBarFinding.warrantsARestart`).
///   One app alone with no slot, Mantel's dots drawn, is never restarted by itself: nothing in a read tells it from an app switched off in
///   System Settings, and the person's Reset covers it, as it did before this was built.
/// - **Once per change, and `perHour` in any hour.**
/// - **Then it keeps watch.** `judgeAfter` after a recovery, a look that finds the pattern still there says the restart didn't help
///   (`didntHelp`), once. From the restart until a look finds the bar whole (or the person resets) no other recovery is made, whatever
///   changes of displays or wakes come: a restart that didn't help shows the pattern isn't one a restart mends, and restarting again at
///   every unlock would only blink the bar. The note stays until then too.
/// - **B1's hold.** From the restart until the same moment, no app is flagged as one macOS doesn't tie (`holdsFlags`): the bar may still
///   be stuck, and a stuck bar looks like that.
public struct StuckBarWatch: Sendable, Equatable {
    /// How long after a change of displays (or a wake) a look may count, in seconds.
    public static let settleTime: TimeInterval = 10
    /// The least time between the two looks that find the pattern, in seconds.
    public static let confirmGap: TimeInterval = 5
    /// How long after a recovery a look says whether it helped, in seconds.
    public static let judgeAfter: TimeInterval = 10
    /// How many recoveries are made in any hour at most.
    public static let perHour = 3
    static let hour: TimeInterval = 3600

    public enum Verdict: Sendable, Equatable {
        case nothing
        /// Restart MenuBarAgent: the pattern held on two looks, `afterTheChange` seconds after the change (at the second one).
        case recover(StuckBarFinding, afterTheChange: TimeInterval)
        /// The pattern holds, and the hour's recoveries are used up. Said once for each change.
        case limitReached
        /// The pattern is still there after a recovery. Said once.
        case didntHelp(StuckBarFinding)
    }

    /// What was found when the bar was last restarted, and when that was over.
    private struct FollowUp: Sendable, Equatable {
        var at: Date
        /// The apps that were missing, with their processes: the tracker forgets what it knew of them with the restart.
        var suspects: [String: Set<pid_t>]
    }

    private var changeAt: Date?
    private var tried = false
    /// A change came while a recovery was being followed up, or the note stood: when the bar is seen whole, that change has had none.
    private var changedWhileHeld = false
    private var limitSaid = false
    private var runStart: Date?
    private var attempts: [Date] = []
    private var followUp: FollowUp?
    /// The restart didn't help, or couldn't be made: what the Diagnostics row says, until a look finds the bar whole or a reset is done.
    public private(set) var didntHelp = false
    /// MenuBarAgent was restarted for a stuck bar and the bar hasn't been seen whole since: no app is to be flagged as one macOS doesn't
    /// tie to it (`UnattachedIconTracker.readTaken(holdingFlags:)`). Set when the restart is made, so that the tracker's forgetting what
    /// it knew doesn't lift it.
    public private(set) var holdsFlags = false

    public init() {}

    /// The apps to look for: the tracker's (`hadASlot`), and, while a recovery is being followed up, the ones it was made for.
    public func suspects(from hadASlot: [String: Set<pid_t>]) -> [String: Set<pid_t>] {
        guard let followUp else { return hadASlot }
        return hadASlot.merging(followUp.suspects) { _, kept in kept }
    }

    /// The displays changed, or the Mac woke: a recovery may be made once more, and what was counted starts again. Not while a recovery is
    /// being followed up, or its note stands (`holdsFlags`): another is made only once the bar has been seen whole. A recovery that has yet
    /// to be judged is judged `judgeAfter` after this change instead: the bar was made again since.
    public mutating func changeHappened(at now: Date) {
        changeAt = now
        limitSaid = false
        runStart = nil
        guard holdsFlags else {
            tried = false
            return
        }
        changedWhileHeld = true
        if var pending = followUp, !didntHelp {
            pending.at = now
            followUp = pending
        }
    }

    /// What a look at `now` (the time the read was taken) says should be done.
    public mutating func look(_ look: StuckBar.Look, at now: Date) -> Verdict {
        if let followUp, now.timeIntervalSince(followUp.at) >= Self.judgeAfter {
            switch look {
            case .whole:
                self.followUp = nil
                didntHelp = false
                holdsFlags = false
                if changedWhileHeld {
                    tried = false
                    changedWhileHeld = false
                }
            case .stuck(let finding):
                if !didntHelp {
                    didntHelp = true
                    return .didntHelp(finding)
                }
            case .none:
                break
            }
        }
        guard let changeAt, !tried, case .stuck(let finding) = look, finding.warrantsARestart,
              now.timeIntervalSince(changeAt) >= Self.settleTime else {
            runStart = nil
            return .nothing
        }
        let start = runStart ?? now
        runStart = start
        guard now.timeIntervalSince(start) >= Self.confirmGap else { return .nothing }
        attempts.removeAll { now.timeIntervalSince($0) >= Self.hour }
        guard attempts.count < Self.perHour else {
            guard !limitSaid else { return .nothing }
            limitSaid = true
            return .limitReached
        }
        return .recover(finding, afterTheChange: now.timeIntervalSince(changeAt))
    }

    /// A recovery begins at `now`: it counts, for this change and for the hour, and no app is flagged until the bar is seen whole.
    public mutating func recoveryBegan(at now: Date) {
        attempts.append(now)
        tried = true
        holdsFlags = true
        runStart = nil
    }

    /// The recovery that was decided can't begin (something forbids it now): the run of looks ends, so that two new ones are needed.
    public mutating func recoveryNotBegun() {
        runStart = nil
    }

    /// The recovery that was decided is refused for a reason that stays until something changes (what the list of the apps that are off
    /// says, say): nothing is decided again until the next change of displays or wake.
    public mutating func recoveryRefused() {
        tried = true
        runStart = nil
    }

    /// The recovery is over at `now`; whether it helped is for a look `judgeAfter` on.
    public mutating func recoveryEnded(at now: Date, suspects: [String: Set<pid_t>]) {
        followUp = FollowUp(at: now, suspects: suspects)
    }

    /// The restart couldn't be made: the note shows at once, and goes when a look finds the bar whole (`judgeAfter` on).
    public mutating func recoveryFailed(at now: Date, suspects: [String: Set<pid_t>]) {
        followUp = FollowUp(at: now, suspects: suspects)
        didntHelp = true
    }

    /// The person reset the menu bar, which restarts MenuBarAgent: nothing is left to judge.
    public mutating func resetDone() {
        changeAt = nil
        runStart = nil
        followUp = nil
        didntHelp = false
        holdsFlags = false
        changedWhileHeld = false
    }
}
