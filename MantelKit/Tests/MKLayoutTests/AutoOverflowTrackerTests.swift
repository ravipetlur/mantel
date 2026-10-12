import Foundation
import Testing

@testable import MKLayout

@Suite("Automatic overflow", .timeLimit(.minutes(1)))
struct AutoOverflowTrackerTests {
    private let a = "com.example.a"
    private let b = "com.example.b"
    private let c = "com.example.c"

    private let fits: (Set<String>) -> Bool = { _ in true }

    private func t(_ seconds: Double) -> Date { Fixtures.date(seconds) }

    /// Sections where the apps given are Shown, as the person left them.
    private func shown(_ apps: String...) -> SectionModel {
        var sections = SectionModel()
        for app in apps { sections.move(app: app, to: .shown) }
        return sections
    }

    /// Sections where the apps given sit in Hidden because Mantel put them there.
    private func autoHidden(_ apps: String...) -> SectionModel {
        var sections = SectionModel()
        for app in apps { sections.apps[app] = AppPlacement(section: .hidden, isAuto: true) }
        return sections
    }

    @Test func overflowedShownAppMovesToHiddenAsAuto() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a, b)
        sections.note([Fixtures.item(Fixtures.itemID(a)), Fixtures.item(Fixtures.itemID(b))])

        let changed = tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(0))
        #expect(changed)
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))
        #expect(sections.apps[b] == AppPlacement(section: .shown, isAuto: false))
        #expect(tracker.trialApps.isEmpty)
        // The icon follows its app in the order lists, as it does when the person moves it.
        #expect(sections.order == [.hidden: [Fixtures.itemID(a)], .shown: [Fixtures.itemID(b)]])

        // The same read again changes nothing.
        #expect(!tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(1)))
        // An app that has no placement is Shown, as new apps are, and moves like one.
        #expect(tracker.inventoryArrived(overflowedApps: [c], unansweredApps: [], sections: &sections, now: t(2)))
        #expect(sections.apps[c] == AppPlacement(section: .hidden, isAuto: true))
    }

    @Test func hiddenAppOverflowIsIgnored() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.move(app: a, to: .hidden)
        sections.move(app: b, to: .alwaysHidden)
        let before = sections

        // They are not on the bar to overflow, and wherever they are, the person put them there.
        #expect(!tracker.inventoryArrived(overflowedApps: [a, b], unansweredApps: [], sections: &sections, now: t(0)))
        #expect(sections == before)
    }

    @Test func displayChangeStartsTrial() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        var asked: [Set<String>] = []

        let started = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { apps in
            asked.append(apps)
            return true
        }, now: t(0))
        #expect(started == [a])
        #expect(asked == [[a]])
        #expect(tracker.trialApps == [a])
        // On trial the app is Shown, and still Mantel's to move.
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: true))
    }

    @Test func trialThatFitsClearsAuto() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(0))

        // The next read: it is on the bar and not in the overflow. From now on it is as if the person had put it there.
        let changed = tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(1))
        #expect(changed)
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: false))
        #expect(tracker.trialApps.isEmpty)

        // Nothing more is done to it, by a later trigger or a later read.
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(100)).isEmpty)
        #expect(!tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(101)))
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: false))
    }

    @Test func mixedTrialResolvesEachAppOnItsOwn() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a, b)
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(0)) == [a, b])

        #expect(tracker.inventoryArrived(overflowedApps: [b], unansweredApps: [], sections: &sections, now: t(1)))
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: false))
        #expect(sections.apps[b] == AppPlacement(section: .hidden, isAuto: true))
        #expect(tracker.trialApps.isEmpty)
    }

    @Test func reoverflowFlapsOncePerTrigger() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        var flaps = 0

        // One trigger: Hidden to Shown for the trial, and back to Hidden when the read says it overflows again.
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(0)) == [a])
        flaps += 1
        #expect(tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(1)))
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))

        // Reads that say the same thing change nothing, and the triggers that follow close behind start no trial.
        #expect(!tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(2)))
        for (trigger, seconds) in [(AutoOverflowTracker.Trigger.frontAppChanged, 3.0), (.frontAppChanged, 4.0), (.periodic, 5.0),
                                   (.frontAppChanged, 11.0), (.periodic, 30.0)] {
            if !tracker.roomMayHaveReturned(trigger, sections: &sections, predictedFits: fits, now: t(seconds)).isEmpty {
                flaps += 1
            }
            #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))
        }
        #expect(flaps == 1)
    }

    @Test func reoverflowedAppIsNotRetriedWithinAMinute() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        _ = tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(0))
        // It overflowed again, a second later: it is left in Hidden until 60 s after that.
        _ = tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(1))

        var asked = false
        let noteAsked: (Set<String>) -> Bool = { _ in asked = true; return true }
        // The 10 s of cooldown are over at 15 s and at 30 s, but the app is cooling.
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: noteAsked, now: t(15)).isEmpty)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: noteAsked, now: t(30)).isEmpty)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: noteAsked, now: t(60.5)).isEmpty)
        #expect(!asked)
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))

        // 60 s after the overflow it is tried again.
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: noteAsked, now: t(61)) == [a])
        #expect(asked)
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: true))
    }

    @Test func frontAppSwitchesInsideCooldownStartNoTrial() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        // A trial that works out: a is Shown for good at 1 s.
        _ = tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(0))
        _ = tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(1))
        // Another app overflows, and is put in Hidden by Mantel.
        sections.apps[b] = AppPlacement(section: .shown, isAuto: false)
        _ = tracker.inventoryArrived(overflowedApps: [b], unansweredApps: [], sections: &sections, now: t(2))
        #expect(sections.apps[b] == AppPlacement(section: .hidden, isAuto: true))

        // The menus change length as the person switches apps: each switch inside the 10 s since the last trial is passed by.
        var asked = 0
        let noteAsked: (Set<String>) -> Bool = { _ in asked += 1; return true }
        for seconds in [3.0, 5.0, 7.0, 9.9] {
            #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: noteAsked, now: t(seconds)).isEmpty)
        }
        #expect(asked == 0)
        #expect(sections.apps[b] == AppPlacement(section: .hidden, isAuto: true))

        // The 10 s are over.
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: noteAsked, now: t(10)) == [b])
        #expect(asked == 1)
    }

    @Test func displayChangeClearsCooling() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        _ = tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(0))
        _ = tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(1))
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(20)).isEmpty)

        // A display was plugged in: what was learned about the room is stale, and the cooldown doesn't apply either.
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(21)) == [a])
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: true))
        // Even within 10 s of the last trial.
        _ = tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(22))
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(23)) == [a])
    }

    @Test func predictionThatDoesntFitSkipsTrial() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        let before = sections

        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in false }, now: t(0)).isEmpty)
        #expect(sections == before)
        #expect(tracker.trialApps.isEmpty)

        // No trial was made, so the cooldown isn't running: a second later the room may be enough.
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(1)) == [a])
    }

    @Test func noAutomaticAppNoTrial() {
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        sections.move(app: a, to: .hidden)
        sections.move(app: b, to: .alwaysHidden)
        sections.move(app: c, to: .shown)
        var asked = false
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in asked = true; return true },
                                            now: t(0)).isEmpty)
        #expect(!asked)
    }

    @Test func personMovedAppIsNeverAuto() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        // The person puts it in Hidden themselves: now it is theirs.
        sections.move(app: a, to: .hidden)
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: false))

        var asked = false
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { _ in asked = true; return true },
                                            now: t(0)).isEmpty)
        #expect(!asked)
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: false))
    }

    @Test func personMoveDuringATrialIsKept() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a, b)
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(0))

        // While they are on trial, the person moves one to Always Hidden and forgets the other.
        sections.move(app: a, to: .alwaysHidden)
        sections.forget(app: b)
        let before = sections
        #expect(!tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(1)))
        #expect(sections == before)
        #expect(tracker.trialApps.isEmpty)
    }

    @Test func unansweredTrialAppStaysOnTrial() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a, b)
        _ = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(0))

        // `a` didn't answer, so its items are missing from the read, which doesn't mean it fits or that it is gone. `b` did, and fits.
        let changed = tracker.inventoryArrived(overflowedApps: [], unansweredApps: [a], sections: &sections, now: t(1))
        #expect(changed)
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: true))
        #expect(sections.apps[b] == AppPlacement(section: .shown, isAuto: false))
        #expect(tracker.trialApps == [a])

        // Still unanswered: nothing changes, not even when the read lists it as overflowing (it can't know).
        #expect(!tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [a], sections: &sections, now: t(2)))
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: true))
        #expect(tracker.trialApps == [a])
        // A trial is open, so no new one starts.
        #expect(tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: fits, now: t(3)).isEmpty)

        // It answers, and fits: the trial is over.
        #expect(tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(4)))
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: false))
        #expect(tracker.trialApps.isEmpty)
    }

    @Test func unansweredAppIsNotMovedAsNewlyOverflowed() {
        var tracker = AutoOverflowTracker()
        var sections = shown(a)
        let before = sections
        #expect(!tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [a], sections: &sections, now: t(0)))
        #expect(sections == before)
    }

    @Test func wideAppDoesntHoldBackNarrowerOnes() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a, b, c)
        // Room for 70 points; a is 100 wide, b and c are 30 each. The apps are tried in order of bundle ID.
        let widths: [String: Double] = [a: 100, b: 30, c: 30]
        var asked: [Set<String>] = []
        let started = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { apps in
            asked.append(apps)
            return apps.reduce(0) { $0 + (widths[$1] ?? .infinity) } <= 70
        }, now: t(0))

        #expect(started == [b, c])
        #expect(asked == [[a], [b], [b, c]])
        #expect(tracker.trialApps == [b, c])
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))
        #expect(sections.apps[b] == AppPlacement(section: .shown, isAuto: true))
        #expect(sections.apps[c] == AppPlacement(section: .shown, isAuto: true))

        // An app that would fit alone but not with the ones before it is left out too.
        var other = AutoOverflowTracker()
        var more = autoHidden(a, b, c)
        let wider: [String: Double] = [a: 20, b: 30, c: 40]
        let some = other.roomMayHaveReturned(.displaysChanged, sections: &more, predictedFits: { apps in
            apps.reduce(0) { $0 + (wider[$1] ?? .infinity) } <= 60
        }, now: t(0))
        #expect(some == [a, b])
        #expect(more.apps[c] == AppPlacement(section: .hidden, isAuto: true))
    }

    @Test func appWithUnknownWidthIsNotTried() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a, b)
        // `a` has quit, so its width is unknown, and a set that holds it is predicted not to fit.
        let started = tracker.roomMayHaveReturned(.displaysChanged, sections: &sections, predictedFits: { !$0.contains(a) }, now: t(0))
        #expect(started == [b])
        #expect(tracker.trialApps == [b])
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))

        // The trial ends, and `a` is not touched: it isn't rewritten as an ordinary Shown app.
        #expect(tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(1)))
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))
        #expect(sections.apps[b] == AppPlacement(section: .shown, isAuto: false))

        // With nothing else to try, nothing starts, and no cooldown runs.
        var alone = AutoOverflowTracker()
        var only = autoHidden(a)
        let before = only
        #expect(alone.roomMayHaveReturned(.displaysChanged, sections: &only, predictedFits: { !$0.contains(a) }, now: t(0)).isEmpty)
        #expect(only == before)
        #expect(alone.trialApps.isEmpty)
        #expect(alone.roomMayHaveReturned(.frontAppChanged, sections: &only, predictedFits: fits, now: t(1)) == [a])
    }

    @Test func unansweredTrialAppIsLetGoAfterAMinute() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        _ = tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(0))

        // It keeps not answering. A second short of a minute after the trial began it is still on it.
        #expect(!tracker.inventoryArrived(overflowedApps: [], unansweredApps: [a], sections: &sections, now: t(59)))
        #expect(tracker.trialApps == [a])

        // A minute after, it is let go, where it is: Shown, and Mantel's to move.
        #expect(!tracker.inventoryArrived(overflowedApps: [], unansweredApps: [a], sections: &sections, now: t(60)))
        #expect(tracker.trialApps.isEmpty)
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: true))

        // The trial is closed, so another can start.
        sections.apps[b] = AppPlacement(section: .hidden, isAuto: true)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: fits, now: t(61)) == [b])

        // If the app that was let go overflows when it answers, it goes to Hidden like any other Shown app.
        #expect(tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(62)))
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))
        #expect(sections.apps[b] == AppPlacement(section: .shown, isAuto: false))
    }

    @Test func appThatOverflowsSoonAfterPassingATrialIsCooled() {
        var tracker = AutoOverflowTracker()
        var sections = autoHidden(a)
        _ = tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: fits, now: t(0))
        // It passes the trial at 1 s, and is out of room again at 20 s: back to Hidden, as automatic, and cooling for a minute.
        _ = tracker.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &sections, now: t(1))
        #expect(sections.apps[a] == AppPlacement(section: .shown, isAuto: false))
        #expect(tracker.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &sections, now: t(20)))
        #expect(sections.apps[a] == AppPlacement(section: .hidden, isAuto: true))

        var asked = false
        let noteAsked: (Set<String>) -> Bool = { _ in asked = true; return true }
        #expect(tracker.roomMayHaveReturned(.frontAppChanged, sections: &sections, predictedFits: noteAsked, now: t(30)).isEmpty)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: noteAsked, now: t(79)).isEmpty)
        #expect(!asked)
        #expect(tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: noteAsked, now: t(80)) == [a])

        // An app that overflows long after it passed a trial isn't cooled: it is the first overflow it has had in a while.
        var later = AutoOverflowTracker()
        var laterSections = autoHidden(a)
        _ = later.roomMayHaveReturned(.frontAppChanged, sections: &laterSections, predictedFits: fits, now: t(0))
        _ = later.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &laterSections, now: t(1))
        #expect(later.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &laterSections, now: t(70)))
        #expect(laterSections.apps[a] == AppPlacement(section: .hidden, isAuto: true))
        #expect(later.roomMayHaveReturned(.frontAppChanged, sections: &laterSections, predictedFits: fits, now: t(71)) == [a])

        // A change of displays forgets that it passed.
        var moved = AutoOverflowTracker()
        var movedSections = autoHidden(a)
        _ = moved.roomMayHaveReturned(.frontAppChanged, sections: &movedSections, predictedFits: fits, now: t(0))
        _ = moved.inventoryArrived(overflowedApps: [], unansweredApps: [], sections: &movedSections, now: t(1))
        #expect(moved.roomMayHaveReturned(.displaysChanged, sections: &movedSections, predictedFits: fits, now: t(5)).isEmpty)
        #expect(moved.inventoryArrived(overflowedApps: [a], unansweredApps: [], sections: &movedSections, now: t(6)))
        #expect(moved.roomMayHaveReturned(.frontAppChanged, sections: &movedSections, predictedFits: fits, now: t(20)) == [a])
    }

    @Test func constantsAreTheOnesTheSessionPlansBy() {
        #expect(AutoOverflowTracker.cooldown == .seconds(10))
        #expect(AutoOverflowTracker.retryAfterReoverflow == .seconds(60))
        #expect(AutoOverflowTracker.periodicInterval == .seconds(60))
    }
}
