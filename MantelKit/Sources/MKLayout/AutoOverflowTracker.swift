import CoreGraphics
import Foundation

/// Moves apps whose icons don't fit on the bar into Hidden, and tries them on the bar again when there may be room.
///
/// - **Moving out.** When a read of the menu bar shows a Shown app in the « overflow or behind the notch (on any display), the app
///   goes to Hidden as an automatic move (`AppPlacement.isAuto`).
/// - **Trying again.** When room may have come back (the displays changed, the front app's menus got shorter, a minute went by), the
///   automatic apps that aren't cooling go back to Shown for a **trial**: as many of them as the widths last seen say will fit
///   together. The next read of the menu bar ends the trial: an app that fits stays Shown, as if the person had put it there; one
///   that overflowed again goes back to Hidden and isn't tried for a minute, unless the displays change. That is one flap, and no
///   more, for each trigger. An app that passed a trial and overflows within the minute after it is treated the same way: it goes
///   back to Hidden, and cools.
/// - **The person has the last word.** A move by the person (`SectionModel.move`) clears `isAuto`, so the tracker never moves that
///   app again, and a trial the person moves an app out of is let go.
/// - **Room for Mantel's dots.** macOS puts the left-most icons in the « first, and Mantel's dots sit left of every Shown app, so on a bar
///   that is a little too narrow it is the dots that go (a Shown app is never the one to overflow). When a read says a dot is in the « of
///   a bar that is shown, the left-most Shown apps on that bar go to Hidden as automatic moves, as many as the dots are wide, and the
///   next read says whether that was enough. They come back by the same trials as the others, which count the dots' width as room that is
///   needed; a trial that pushes the dots out again goes back to Hidden and isn't tried again until the displays change or `pinExpiry`
///   (half an hour) has gone by, and neither is an app that returned once and had to go again. Moves for the dots are paced with the
///   trials: one in ten seconds at most. What is
///   held in Hidden for the dots of a bar is capped (what they needed, and the app that went last), and moves stop on a bar where the
///   dots still say the same place after one; either stop lasts until a read has the dots right on that bar, or the displays change. An
///   app that passed its trial gives its room back to the cap.
///
/// The tracker never reads the clock: the session passes the time of each call, so a test can drive it with dates.
public struct AutoOverflowTracker: Sendable, Equatable {
    /// What may have brought room back.
    public enum Trigger: Sendable, Equatable {
        /// A display was added, removed or rearranged. Whatever was learned about the room is stale, so cooling is cleared.
        case displaysChanged
        /// A different app came to the front, which changes how much of the bar its menus take.
        case frontAppChanged
        /// `periodicInterval` has gone by.
        case periodic
    }

    /// The least time between two trials, except after a change of displays.
    public static let cooldown: Duration = .seconds(10)
    /// How long an app that overflowed again in a trial is left in Hidden before it is tried again.
    public static let retryAfterReoverflow: Duration = .seconds(60)
    /// How many reads in a row must have the dots out of the way on a bar before an app is moved for them. What a read shows of where the
    /// dots are can be out of date for a moment (the icons move when the displays change, and say where they were), and moving an app for
    /// that would be for nothing.
    public static let confirmingReads = 2
    /// How long an app is pinned in Hidden at most (`pinnedHidden`): then it may be tried once more, so that a Mac whose displays never
    /// change doesn't keep an app hidden all day for a trial that failed in the morning.
    public static let pinExpiry: Duration = .seconds(30 * 60)
    /// How often the session asks whether room has come back, when nothing else has told it.
    public static let periodicInterval: Duration = .seconds(60)

    /// The apps in the trial that is open, which are Shown for it. Empty when no trial is open.
    public private(set) var trialApps: Set<String> = []
    /// By bundle ID: the time before which an app that overflowed again isn't tried.
    private var coolingUntil: [String: Date] = [:]
    /// By bundle ID: when an app passed a trial, for as long as `retryAfterReoverflow` hasn't gone by since.
    private var passedTrialAt: [String: Date] = [:]
    private var lastTrialStart: Date?
    /// By bundle ID: the display an app was moved to Hidden on, to make room for the dots there, and the room its icons take. (The app is
    /// in Hidden as an automatic move for as long as it is here, except while it is on trial: it is Shown then, and its width is not held.)
    private var concealedForDots: [String: HeldForDots] = [:]
    /// The apps that were moved for the dots, came back (a trial passed, or was let go without a verdict) and are Shown again: the next move
    /// for the dots of one of them is its second, and it stays in Hidden then.
    private var returnedForDots: Set<String> = []
    /// The apps on the trial that is open for which a read to confirm what they showed was asked for: a trial is let go for want of a
    /// confirmation only after that.
    private var askedToConfirm: Set<String> = []
    /// By bundle ID, with the time it was pinned: the apps that stay in Hidden until the displays change or `pinExpiry` has gone by, whichever
    /// is first. They were put on trial and pushed the dots out again, or they went back to Hidden for the dots a second time.
    private var pinnedHidden: [String: Date] = [:]
    /// Whether the displays have changed since the last move for the dots, which lets the next one come at once.
    private var displaysChangedSinceDotsMove = false
    /// By display: in how many reads in a row the dots were in the « or behind the notch. A move waits for two (`confirmingReads`).
    private var trappedStreak: [String: Int] = [:]
    /// By display: the places the dots said they were at when apps were last moved for them. Where the next move would be made for the
    /// same places, the apps that were moved changed nothing: what the dots say is out of date, and no more is moved.
    private var placesAtLastMove: [String: [CGRect]] = [:]
    /// By display: what the dots needed when the apps that are now held in Hidden for them were first moved. What is held on a display
    /// (`concealedForDots`) and this are what caps the moves there: when nothing is held (every app came back from a trial), what the dots
    /// need is asked of the bar again.
    private var neededWhileHeld: [String: CGFloat] = [:]
    /// The displays where no more apps are moved for the dots, until the dots are seen on the bar again or the displays change.
    private var stoppedDots: Set<String> = []
    /// How many times the displays have changed: what was moved for the dots before a change is not counted by the cap after it.
    private var displayChanges = 0
    /// By app: in how many reads in a row it was out of the way only by where it says it is.
    private var inferredStreak: [String: Int] = [:]

    public init() {}

    // MARK: A new read of the menu bar

    /// What a read of the menu bar holds that the tracker judges.
    public struct Read: Sendable, Equatable {
        /// The apps (not system items) with an icon in the overflow or behind the notch, on any display
        /// (`OverflowInputs.overflowedApps(in:)`).
        public var overflowedApps: Set<String>
        /// The apps that didn't answer when asked for their items (`Inventory.unansweredApps`). An app that doesn't answer is neither
        /// fitting nor overflowing: one of them in a trial stays in it, where it is, until a read in which it does answer; and none is
        /// moved as newly overflowed. An app that still hasn't answered `retryAfterReoverflow` after its trial began is let go from the
        /// trial, left as it is (Shown, and automatic), so that a trial can't stay open for as long as an app hangs.
        public var unansweredApps: Set<String>
        /// The bars that are shown and have one of Mantel's dots in their « (`DotsRoom.trappedBars`), empty when none has.
        public var trappedBars: [TrappedBar]
        /// The apps in `overflowedApps` that are there only by where they say they are (`OverflowInputs.inferredOnlyApps(in:)`). What a place
        /// says can be out of date, so such an app is moved on two reads in a row (`confirmingReads`), as the dots are.
        public var inferredApps: Set<String>

        public init(overflowedApps: Set<String>, unansweredApps: Set<String> = [], trappedBars: [TrappedBar] = [],
                    inferredApps: Set<String> = []) {
            self.overflowedApps = overflowedApps
            self.unansweredApps = unansweredApps
            self.trappedBars = trappedBars
            self.inferredApps = inferredApps
        }
    }

    /// A shown bar that has a dot in its «, and the Shown apps whose icons take room on it.
    public struct TrappedBar: Sendable, Equatable {
        public var displayUUID: String
        /// The room the dots that are in the « need, in points.
        public var neededWidth: CGFloat
        /// The Shown apps on this bar from the left, the left-most first, each with the room its icons take (nil when never seen).
        public var apps: [ConcealableApp]
        /// Whether the dots being out of the way was told by where they say they are (behind the notch, under the menus), and not by a slot
        /// or a « (`DotsRoom.Verdict.inferred`).
        public var isInferred: Bool
        /// The places the dots on this bar say they are at (their stray frames), left to right; empty when it was a slot or a « that put
        /// them out of the way.
        public var dotPlaces: [CGRect]

        public init(displayUUID: String, neededWidth: CGFloat, apps: [ConcealableApp], isInferred: Bool = false, dotPlaces: [CGRect] = []) {
            self.displayUUID = displayUUID
            self.neededWidth = neededWidth
            self.apps = apps
            self.isInferred = isInferred
            self.dotPlaces = dotPlaces
        }
    }

    public struct ConcealableApp: Sendable, Equatable {
        public var bundleID: String
        public var width: CGFloat?

        public init(bundleID: String, width: CGFloat?) {
            self.bundleID = bundleID
            self.width = width
        }
    }

    /// An app that moved for the dots, and the display they were in the « of.
    public struct DotsMove: Sendable, Equatable {
        public var bundleID: String
        public var displayUUID: String
        /// Whether the dots were found to be out of the way by where they say they are (`TrappedBar.isInferred`).
        public var isInferred: Bool
        /// For a move: the app stays in Hidden until the displays change or `pinExpiry` has gone by (it came back once and has to go again).
        public var isPinned: Bool
        /// For an app on trial that pushed the dots out: it had been moved for the dots before. When it hadn't (it was moved for
        /// overflowing itself), the dots going out is a new thing the trial brought.
        public var wasMovedForTheDots: Bool

        public init(bundleID: String, displayUUID: String, isInferred: Bool = false, isPinned: Bool = false,
                    wasMovedForTheDots: Bool = true) {
            self.bundleID = bundleID
            self.displayUUID = displayUUID
            self.isInferred = isInferred
            self.isPinned = isPinned
            self.wasMovedForTheDots = wasMovedForTheDots
        }
    }

    /// An app that was moved to Hidden for the dots of a display, and the room it took there.
    private struct HeldForDots: Sendable, Equatable {
        var displayUUID: String
        var width: CGFloat
        /// `displayChanges` when it was moved.
        var epoch: Int
    }

    /// Why no more apps are moved for the dots on a display.
    public struct DotsStop: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// The apps that were moved changed nothing: the dots still report the same places.
            case samePlace
            /// As much is held in Hidden for the dots as they needed and one app more, and they are still out of the way.
            case enoughMoved
        }

        public var displayUUID: String
        public var reason: Reason
        public var isInferred: Bool
        /// The room held in Hidden for the dots of that display when the stop began, in points. The log says a stop again only when this
        /// has changed, or after a while (`DotsRoomLog`).
        public var held: CGFloat

        public init(displayUUID: String, reason: Reason, isInferred: Bool = false, held: CGFloat = 0) {
            self.displayUUID = displayUUID
            self.reason = reason
            self.isInferred = isInferred
            self.held = held
        }
    }

    /// What a read changed, for the sections and for the log.
    public struct Outcome: Sendable, Equatable {
        /// Whether `sections` changed.
        public var changed = false
        /// Apps moved to Hidden to make room for the dots.
        public var movedForDots: [DotsMove] = []
        /// Apps that were moved for the dots and passed their trial: Shown again.
        public var returnedForDots: [DotsMove] = []
        /// Apps on trial that pushed the dots out again, and went back to Hidden to stay there until the displays change or `pinExpiry` has gone by.
        public var failedForDots: [DotsMove] = []
        /// The displays whose dots are in the « and no Shown app could be moved to make room.
        public var noRoomToMakeFor: [String] = []
        /// The displays whose dots were found out of the way for the first time (or again after a read that had them right): the next
        /// read confirms it, and until it does, nothing is moved for them. The session asks for that read.
        public var awaitingConfirmation: [String] = []
        /// The displays where moving apps for the dots was stopped, and why: nothing more is moved there until a read has the dots right on
        /// that bar or the displays change.
        public var stoppedForDots: [DotsStop] = []
        /// The apps that are out of the way only by where they say they are, for the first time: the next read confirms it, and until it
        /// does, nothing is done about them. The session asks for that read.
        public var awaitingApps: [String] = []

        public init() {}
    }

    /// Handles a read of the menu bar: closes the open trial, then moves newly overflowed Shown apps to Hidden. The session calls
    /// this only while the bar is collapsed, since a reveal moves icons for a reason of its own. Returns whether `sections` changed.
    ///
    /// `OverflowInputs.overflowedApps(in:)` makes `overflowedApps` from an inventory. This is `arrived(_:sections:now:)` for a read that
    /// has nothing to say of the dots.
    @discardableResult
    public mutating func inventoryArrived(overflowedApps: Set<String>, unansweredApps: Set<String>, sections: inout SectionModel,
                                          now: Date) -> Bool {
        arrived(Read(overflowedApps: overflowedApps, unansweredApps: unansweredApps), sections: &sections, now: now).changed
    }

    /// Handles a read of the menu bar (see `inventoryArrived(overflowedApps:unansweredApps:sections:now:)`), and the dots in it.
    ///
    /// - **A trial** ends with the read. An app that overflowed again goes back to Hidden and cools. When a dot is in a « though no app
    ///   overflowed, it was the apps on trial that pushed the dots out (macOS puts the left-most icons in the « first, and the dots are
    ///   left of every app): they all go back to Hidden, and stay there until the displays change or `pinExpiry` has gone by.
    /// - **The dots** get room only from a read that moved nothing else: what was moved may have made it. Then the left-most Shown apps on
    ///   each bar the dots are trapped on go to Hidden until the room they take is the room the dots need, but not within
    ///   `cooldown` of the last trial or move (unless the displays have changed since), and never an app that is overflowed itself, on
    ///   trial, or not Shown. The dots must be out of the way on a bar in two reads in a row (`confirmingReads`) before the first move, and
    ///   a change of displays starts that count again: what a read shows of them just after one can be what it was before.
    public mutating func arrived(_ read: Read, sections: inout SectionModel, now: Date) -> Outcome {
        var outcome = Outcome()
        let dotsTrapped = read.trappedBars.first?.displayUUID
        // An app that is out of the way only by where it says it is waits for a second read, as the dots do.
        inferredStreak = inferredStreak.filter { read.inferredApps.contains($0.key) && read.overflowedApps.contains($0.key) }
        for app in read.overflowedApps.intersection(read.inferredApps) { inferredStreak[app, default: 0] += 1 }
        let unconfirmed = read.overflowedApps.filter { read.inferredApps.contains($0) && inferredStreak[$0, default: 0] < Self.confirmingReads }
        let overflowedApps = read.overflowedApps.subtracting(unconfirmed)
        outcome.awaitingApps = unconfirmed.sorted()
        // How many reads in a row have the dots out of the way, for each display: one that has them right starts it again.
        let trappedNow = Set(read.trappedBars.map(\.displayUUID))
        trappedStreak = trappedStreak.filter { trappedNow.contains($0.key) }
        for display in trappedNow { trappedStreak[display, default: 0] += 1 }
        // A read that has the dots right on a display ends what was learned of them there: the places they said when apps were last moved,
        // and the stop that came of them or of the cap, were of the cycle that has ended, and a trap that comes later is a new one.
        placesAtLastMove = placesAtLastMove.filter { trappedNow.contains($0.key) }
        stoppedDots.formIntersection(trappedNow)
        passedTrialAt = passedTrialAt.filter { now.timeIntervalSince($0.value) < Self.retryAfterReoverflow.timeInterval }
        let trialIsOld = lastTrialStart.map { now.timeIntervalSince($0) >= Self.retryAfterReoverflow.timeInterval } ?? false

        for app in trialApps.sorted() {
            // The person moved it, or it was forgotten: it isn't the tracker's to decide any more.
            guard let placement = sections.apps[app], placement.section == .shown, placement.isAuto else {
                trialApps.remove(app)
                concealedForDots[app] = nil
                continue
            }
            if read.unansweredApps.contains(app) {
                // Not answering says nothing, for a while; then the app is let go where it is.
                if trialIsOld { letGo(app) }
                continue
            }
            // The dots out of the way in this read, and in none before it, say little: the app stays on trial, as one that doesn't answer
            // does, and the read that confirms it (the session asks for it) decides. Failing the trial, and with it pinning the app until
            // the displays change, is for a sighting that was confirmed. A trial doesn't wait for one for ever: after as long as an app that
            // doesn't answer is waited for, the app is let go as it is.
            if unconfirmed.contains(app) {
                // (`awaitingApps` asks for the read that confirms it.)
                if trialIsOld, askedToConfirm.contains(app) { letGo(app) } else { askedToConfirm.insert(app) }
                continue
            }
            if !overflowedApps.contains(app), let display = dotsTrapped, trappedStreak[display, default: 0] < Self.confirmingReads {
                if trialIsOld, askedToConfirm.contains(app) {
                    letGo(app)
                } else {
                    askedToConfirm.insert(app)
                    if !outcome.awaitingConfirmation.contains(display) { outcome.awaitingConfirmation.append(display) }
                }
                continue
            }
            trialApps.remove(app)
            if overflowedApps.contains(app) {
                sections.place(app: app, in: .hidden, isAuto: true)
                coolingUntil[app] = now.addingTimeInterval(Self.retryAfterReoverflow.timeInterval)
            } else if let display = dotsTrapped {
                // The app is on the bar and the dots are not: it is what they were pushed out by.
                sections.place(app: app, in: .hidden, isAuto: true)
                pinnedHidden[app] = now
                outcome.failedForDots.append(DotsMove(bundleID: app, displayUUID: display, isInferred: read.trappedBars.first?.isInferred ?? false,
                                                      isPinned: true, wasMovedForTheDots: concealedForDots[app] != nil))
            } else {
                // It fits: from now on it is an ordinary Shown app.
                sections.apps[app] = AppPlacement(section: .shown, isAuto: false)
                passedTrialAt[app] = now
                // It is out of Hidden: the room it took is given back (what is held for the dots is what caps the moves).
                if let held = concealedForDots.removeValue(forKey: app) {
                    returnedForDots.insert(app)
                    outcome.returnedForDots.append(DotsMove(bundleID: app, displayUUID: held.displayUUID))
                }
            }
            outcome.changed = true
        }

        for app in overflowedApps.sorted() where !read.unansweredApps.contains(app) && !trialApps.contains(app) {
            guard sections.section(ofApp: app) == .shown else { continue }
            sections.place(app: app, in: .hidden, isAuto: true)
            // It passed a trial a moment ago and is out of room again: that is the flap the cooling is for.
            if passedTrialAt.removeValue(forKey: app) != nil {
                coolingUntil[app] = now.addingTimeInterval(Self.retryAfterReoverflow.timeInterval)
            }
            outcome.changed = true
        }

        if !outcome.changed, !read.trappedBars.isEmpty {
            makeRoomForDots(on: read.trappedBars, sections: &sections, now: now, outcome: &outcome)
        }
        return outcome
    }

    private mutating func makeRoomForDots(on bars: [TrappedBar], sections: inout SectionModel, now: Date, outcome: inout Outcome) {
        // Out of the way in this read and the one before it, on a bar, and only then.
        let confirmed = bars.filter { trappedStreak[$0.displayUUID, default: 0] >= Self.confirmingReads }
        for bar in bars where trappedStreak[bar.displayUUID, default: 0] < Self.confirmingReads && !outcome.awaitingConfirmation.contains(bar.displayUUID) {
            outcome.awaitingConfirmation.append(bar.displayUUID)
        }
        guard !confirmed.isEmpty else { return }
        if !displaysChangedSinceDotsMove, let last = lastTrialStart, now.timeIntervalSince(last) < Self.cooldown.timeInterval { return }

        var moved: [String: String] = [:]  // bundle ID → the display it was moved for
        for bar in confirmed where !stoppedDots.contains(bar.displayUUID) {
            // Apps were moved for these dots, and they say they are where they said they were: moving them changed nothing, and moving
            // more won't. (A place that is a stale one stays as it is whatever is done.)
            if let before = placesAtLastMove[bar.displayUUID], !before.isEmpty, Self.samePlaces(before, bar.dotPlaces) {
                stoppedDots.insert(bar.displayUUID)
                outcome.stoppedForDots.append(DotsStop(displayUUID: bar.displayUUID, reason: .samePlace, isInferred: bar.isInferred,
                                                       held: heldWidth(on: bar.displayUUID, sections: sections)))
                continue
            }
            // What an app moved for another bar frees here too, if its icons are on this one.
            var freed = bar.apps.filter { moved[$0.bundleID] != nil }.reduce(CGFloat.zero) { $0 + ($1.width ?? bar.neededWidth) }
            var movedOnThisBar = false
            var stoppedOnThisBar = false
            // What is held in Hidden for the dots here is capped by what they needed when it was first moved, and one app more: another app
            // is moved only while no more is held than they needed, so that what is held is at most what they needed and the app that
            // went last. An app that passed its trial is out of Hidden, and what it took is no longer held: a cap that came of apps that
            // were given their room back is no cap on a trap that comes later.
            var held = heldWidth(on: bar.displayUUID, sections: sections)
            let needed = held > 0 ? neededWhileHeld[bar.displayUUID] ?? bar.neededWidth : bar.neededWidth
            for app in bar.apps where freed < bar.neededWidth {
                guard moved[app.bundleID] == nil, !trialApps.contains(app.bundleID), sections.section(ofApp: app.bundleID) == .shown else {
                    continue
                }
                if held > needed {
                    stoppedDots.insert(bar.displayUUID)
                    stoppedOnThisBar = true
                    outcome.stoppedForDots.append(DotsStop(displayUUID: bar.displayUUID, reason: .enoughMoved, isInferred: bar.isInferred,
                                                           held: held))
                    break
                }
                let width = app.width ?? bar.neededWidth
                if held == 0 { neededWhileHeld[bar.displayUUID] = needed }
                held += width
                placesAtLastMove[bar.displayUUID] = bar.dotPlaces
                sections.place(app: app.bundleID, in: .hidden, isAuto: true)
                concealedForDots[app.bundleID] = HeldForDots(displayUUID: bar.displayUUID, width: width, epoch: displayChanges)
                // It came back once and has to go again: it stays out until the displays change or `pinExpiry` has gone by.
                let pinned = returnedForDots.remove(app.bundleID) != nil
                if pinned { pinnedHidden[app.bundleID] = now }
                moved[app.bundleID] = bar.displayUUID
                movedOnThisBar = true
                freed += width
                outcome.movedForDots.append(DotsMove(bundleID: app.bundleID, displayUUID: bar.displayUUID, isInferred: bar.isInferred,
                                                     isPinned: pinned))
            }
            // "No Shown app is left" is for a bar where none was there to move: not one the cap or the stop refused.
            if !movedOnThisBar, !stoppedOnThisBar, freed < bar.neededWidth { outcome.noRoomToMakeFor.append(bar.displayUUID) }
        }
        guard !moved.isEmpty else { return }
        outcome.changed = true
        lastTrialStart = now
        displaysChangedSinceDotsMove = false
    }

    /// Whether two lists of places are the same (`OverflowInputs.isSamePlace`).
    private static func samePlaces(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { OverflowInputs.isSamePlace($0, $1) }
    }

    /// The room that is held in Hidden for the dots of a display since the displays last changed: what the apps moved for them there
    /// take, for those that are still in Hidden as an automatic move, and for those that are on trial for the moment (they are Shown, and
    /// go back to Hidden if the trial fails: what is held may not be more than the cap with them out of it). One that the person moved is
    /// theirs, and not held.
    private func heldWidth(on display: String, sections: SectionModel) -> CGFloat {
        concealedForDots.reduce(CGFloat.zero) { total, entry in
            guard entry.value.displayUUID == display, entry.value.epoch == displayChanges else { return total }
            let inHidden = sections.apps[entry.key].map { $0.section == .hidden && $0.isAuto } ?? false
            return trialApps.contains(entry.key) || inHidden ? total + entry.value.width : total
        }
    }

    /// An app on trial that isn't judged for want of an answer or a confirming read, for as long as is waited: it is left as it is
    /// (Shown, and automatic) and is the tracker's no more. One that was moved for the dots has come back, as far as the next move
    /// goes: that is its second, and it stays in Hidden.
    private mutating func letGo(_ app: String) {
        trialApps.remove(app)
        if concealedForDots.removeValue(forKey: app) != nil { returnedForDots.insert(app) }
    }

    /// The displays are changing, and the read about to be taken is of a bar that is being made again: what was seen before it, of the
    /// dots and of apps that were out of the way by their places, doesn't count towards the reads in a row. (The same is done when the
    /// trigger of a trial is `.displaysChanged`, after the read.)
    public mutating func displaysAreChanging() {
        trappedStreak.removeAll()
        inferredStreak.removeAll()
    }

    /// Nothing is made of reads now (automatic overflow is off): the reads in a row that were counted don't carry over to when it is on.
    public mutating func forgetSightings() {
        trappedStreak.removeAll()
        inferredStreak.removeAll()
        placesAtLastMove.removeAll()
        stoppedDots.removeAll()
    }

    // MARK: Room may have come back

    /// Called when room may have come back. Returns the apps put on trial (moved to Shown, still automatic), or an empty set when no
    /// trial was started. Nothing is started when
    ///
    /// - a trial is open already;
    /// - the trigger isn't `.displaysChanged` and the last trial began less than `cooldown` ago;
    /// - no automatic app in Hidden is free of cooling, and not pinned there by the dots (`arrived`); or
    /// - none of those apps is predicted to fit.
    ///
    /// The apps to try are chosen one at a time, in order of bundle ID: an app joins the trial if `predictedFits` says that it would
    /// fit together with the apps already in it. So an app that is too wide doesn't hold back the narrower ones after it.
    ///
    /// `predictedFits` answers from the widths last seen (`ItemWidthCache`) and the room there is, and **must answer false whenever any
    /// app in the set it is given has a width that isn't known** (an app that has quit, say). That app is then left in Hidden.
    public mutating func roomMayHaveReturned(_ trigger: Trigger, sections: inout SectionModel,
                                             predictedFits: (Set<String>) -> Bool, now: Date) -> Set<String> {
        if trigger == .displaysChanged {
            coolingUntil.removeAll()
            passedTrialAt.removeAll()
            pinnedHidden.removeAll()
            returnedForDots.removeAll()
            displaysChangedSinceDotsMove = true
            // What was seen of the dots before the change, and in the read that came with it, is of the displays as they were.
            trappedStreak.removeAll()
            inferredStreak.removeAll()
            placesAtLastMove.removeAll()
            neededWhileHeld.removeAll()
            displayChanges += 1
            stoppedDots.removeAll()
        }
        // A pin that has lasted `pinExpiry` is over: the app may be tried once more (and is pinned again if it fails, or goes again).
        pinnedHidden = pinnedHidden.filter { now.timeIntervalSince($0.value) < Self.pinExpiry.timeInterval }
        guard trialApps.isEmpty else { return [] }
        if trigger != .displaysChanged, let last = lastTrialStart, now.timeIntervalSince(last) < Self.cooldown.timeInterval {
            return []
        }
        let candidates = Set(sections.apps.filter { app, placement in
            placement.section == .hidden && placement.isAuto && !isCooling(app, at: now) && pinnedHidden[app] == nil
        }.keys)
        var trial: Set<String> = []
        for app in candidates.sorted() where predictedFits(trial.union([app])) {
            trial.insert(app)
        }
        guard !trial.isEmpty else { return [] }

        for app in trial.sorted() {
            sections.place(app: app, in: .shown, isAuto: true)
        }
        trialApps = trial
        askedToConfirm.removeAll()
        lastTrialStart = now
        // The read that judges the trial counts the dots afresh: what was counted of them before it was of the bar without these apps,
        // and dots that were already out of the way before the trial must not fail it on the first read after.
        trappedStreak.removeAll()
        inferredStreak.removeAll()
        // The trial is what the change of displays brought: the next move for the dots is paced from it, as it is from any trial.
        displaysChangedSinceDotsMove = false
        return trial
    }

    private func isCooling(_ app: String, at now: Date) -> Bool {
        guard let until = coolingUntil[app] else { return false }
        return now < until
    }
}

extension Duration {
    /// The duration in seconds, for working with `Date`s.
    fileprivate var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
