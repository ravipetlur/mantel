import Foundation

/// What the look at the bar after a strip said of the slots, compared with the read.
enum SlotsLook: Sendable, Equatable {
    /// They are the whole list the read had.
    case same
    /// They answered, and they are not: a slot came, went or moved.
    case differs
    /// The look didn't come: MenuBarAgent or its window didn't answer in time.
    case unanswered
}

/// Judges, round by round, whether the bar is still the one a read was of and which apps' pictures may be kept: what `isStillCurrent` asks
/// once a strip is back.
///
/// A look or an app that doesn't answer isn't a bar that changed. On a busy Mac the answer comes late, and the check says "not known to be
/// the same" for what is only slow. So only a real difference throws pictures away, and what didn't answer is asked again after the bar has
/// had a moment to settle:
/// - **A round** asks the apps that aren't judged yet for their frames, and then looks at the slots.
/// - **Slots that differ** from the read are a change for the apps whose icons' slots moved (`moved`), and for them only: the others,
///   whose slots are where they were, are judged by their own frames like any app. Which are which is told only where a slide can't
///   fool it (`BarSlotCheck.difference`: the slots left of the walk's stop that aren't Mantel's own are the same ones); anywhere else
///   `moved` is every app still waiting, and nothing is kept from that look. Slots that didn't answer confirm nothing in that round.
/// - **An app that answered with frames that are not in the slots the read gave it is rejected** (`ItemFrameCheck`), in every round, the
///   slots' look answered or not: that is a real difference, for that app.
/// - **Slots that are the same** confirm the apps whose frames are in the slots the read gave them. An app that didn't answer stays to be
///   asked again, and doesn't hold back another app that answered: its pictures are kept when the others' frames were confirmed.
/// - **Once a look didn't answer, the bar is settling:** a confirmation then counts only when two rounds in a row agree on it, so that a
///   bar that is still moving after a late answer isn't taken for one that has stopped.
/// - It ends when every app is judged, or after `maxRounds` rounds, with the apps that were confirmed.
struct StillCurrentWatch: Sendable, Equatable {
    /// How many rounds are made at most, and how long the first waits for the second after a round that didn't answer in full.
    static let maxRounds = 4
    static let settleWait: Duration = .milliseconds(250)
    /// The most the whole check takes, from its start.
    static let bound: Duration = .seconds(3)

    private(set) var pending: Set<String>
    private(set) var confirmed: Set<String> = []
    private(set) var rejected: Set<String> = []
    /// In how many rounds the look at the slots answered whole.
    private(set) var looksAnswered = 0
    private var settling = false
    private var candidates: Set<String>?
    private(set) var rounds = 0

    init(apps: Set<String>) {
        pending = apps
    }

    enum Verdict: Equatable {
        /// The apps whose pictures may be kept.
        case done(kept: Set<String>)
        /// Another round is wanted.
        case again
    }

    /// Takes in one round: the look at the slots, the apps whose frames are in the slots the read gave them (`tied`) and the apps that
    /// answered at all (`answered`).
    /// `moved`: when the slots differ, the apps whose icons' slots are not where the read had them.
    mutating func note(slots: SlotsLook, tied: Set<String>, answered: Set<String>, moved: Set<String> = []) -> Verdict {
        rounds += 1
        // An app that answered with frames that are not in the slots the read gave it is a real difference for that app, whatever the look
        // at the slots made of this round: a look that didn't answer says nothing of the bar, and the app's own frames are evidence of a
        // change that the next rounds, with the bar back, would hide.
        rejected.formUnion(answered.subtracting(tied).intersection(pending))
        pending.subtract(rejected)
        switch slots {
        case .differs:
            looksAnswered += 1
            rejected.formUnion(moved.intersection(pending))
            pending.subtract(rejected)
            // The look answered whole: what is left is judged by the apps' own frames, as a look that is the same is (the slots right of the
            // difference are where they were, whether or not the bar is still on the move left of it, where `moved` says they are).
            let tiedNow = tied.intersection(pending)
            if settling { confirmWhenSettled(tiedNow) } else { confirm(tiedNow) }
        case .unanswered:
            settling = true
            candidates = nil
        case .same:
            looksAnswered += 1
            let tiedNow = tied.intersection(pending)
            if settling {
                confirmWhenSettled(tiedNow)
            } else {
                confirm(tiedNow)
            }
        }
        return pending.isEmpty || rounds >= Self.maxRounds ? .done(kept: confirmed) : .again
    }

    /// The check ran out of time: the apps that were confirmed are kept.
    var keptWhenOutOfTime: Set<String> { confirmed }

    /// Whether the apps that aren't kept are so for want of time: none of them was seen to differ (an app whose icons' slots moved, or
    /// whose own frames were found out of its slots, is a change, whatever became of the other apps), and something is left that was
    /// neither confirmed nor rejected. Nothing moved in what was seen, and the rest wasn't judged. A look that differed without moving an
    /// app that is still waiting (an arrival at the left end, say) is no change for it.
    func isOutOfTime(keeping kept: Set<String>, of apps: Set<String>) -> Bool {
        rejected.isEmpty && !apps.subtracting(kept).isEmpty
    }

    private mutating func confirmWhenSettled(_ tiedNow: Set<String>) {
        if let before = candidates { confirm(before.intersection(tiedNow)) }
        candidates = tiedNow
    }

    private mutating func confirm(_ apps: Set<String>) {
        confirmed.formUnion(apps)
        pending.subtract(apps)
    }
}

/// What a still-current check found out of place, for the log: said once, whatever the round it was found in.
struct StillCurrentFindings: Sendable, Equatable {
    /// How the slots the last look found differ from the read's (`BarSlotCheck.Difference.summary`).
    var slots: String?
    /// The apps whose icons' slots moved, and what each other app that was rejected said of its own frames.
    private(set) var moved: Set<String> = []
    private(set) var frames: [String: String] = [:]
    /// The slots' look was of a change that no app is known to have missed (`BarSlotCheck.Difference.isTrusted` is false), and the apps it
    /// rejected are said so in the slots' summary, not listed as the ones whose slots moved.
    var everyAppMoved = false

    /// Takes in the apps a round rejected: those in `movedNow` for their slots, the others for their frames, which `describing` tells of.
    mutating func noteRejected(_ rejected: Set<String>, moved movedNow: Set<String>, describing: (String) -> String) {
        for app in rejected.sorted() {
            if movedNow.contains(app) {
                moved.insert(app)
            } else if frames[app] == nil {
                frames[app] = describing(app)
            }
        }
    }

    private var lines: [String] {
        var lines: [String] = []
        if let slots { lines.append(slots) }
        if !moved.isEmpty, !everyAppMoved { lines.append("icons in slots that moved: \(Self.list(moved))") }
        lines.append(contentsOf: frames.sorted { $0.key < $1.key }.prefix(3).map(\.value))
        if frames.count > 3 { lines.append("and \(frames.count - 3) more apps whose frames are elsewhere") }
        return lines
    }

    /// The check ended with this, for a reason of its own (what Mantel did, MenuBarAgent, the reveal).
    func answer(kept: Set<String>, outOfTime: Bool, adding why: String) -> StillCurrentAnswer {
        StillCurrentAnswer(kept: kept, outOfTime: outOfTime, changes: [why] + lines)
    }

    /// The check ended by its rounds or its bound, or because every app was judged. The apps it didn't judge are always said (an app
    /// that never answered is lost for that, whatever else the check found), and how far it got when that is for want of time.
    func answer(for watch: StillCurrentWatch, kept: Set<String>, of apps: Set<String>) -> StillCurrentAnswer {
        let outOfTime = watch.isOutOfTime(keeping: kept, of: apps)
        var lines = self.lines
        let notJudged = apps.subtracting(kept).subtracting(watch.rejected)
        if !notJudged.isEmpty {
            // The text of the capture's line already says "ran out of time" when it did: this is how far the check got.
            let reach = outOfTime
                ? "after \(watch.rounds) round\(watch.rounds == 1 ? "" : "s"), a whole look in \(watch.looksAnswered) of them; " : ""
            lines.append("\(reach)not judged: \(Self.list(notJudged))")
        }
        return StillCurrentAnswer(kept: kept, outOfTime: outOfTime, changes: lines)
    }

    private static func list(_ apps: Set<String>) -> String {
        let sorted = apps.sorted()
        return sorted.prefix(4).joined(separator: ", ") + (sorted.count > 4 ? " and \(sorted.count - 4) more" : "")
    }
}
