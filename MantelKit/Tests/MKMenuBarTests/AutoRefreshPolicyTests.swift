import Foundation
import MKCore
import Testing

@testable import MKMenuBar

/// When Mantel refreshes the menu bar by itself, as plain values: the time is a date each scan brings.
@Suite("Auto-refresh policy", .timeLimit(.minutes(1)))
struct AutoRefreshPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let main = "D4A71B63"
    private let portrait = "8C2D5F14"

    private func at(_ seconds: Int) -> Date { start.addingTimeInterval(Double(seconds)) }

    /// A read in which the agent didn't answer.
    private func failed(_ policy: inout AutoRefreshPolicy, at seconds: Int, mayRefresh: Bool = true) -> AutoRefreshPolicy.Verdict {
        policy.scanFinished(agentAnswered: false, displaysWithSlots: [], displays: [], afterDisplayChange: false, mayRefresh: mayRefresh,
                            now: at(seconds))
    }

    /// A read in which the agent answered and every display has slots.
    private func answered(_ policy: inout AutoRefreshPolicy, at seconds: Int, mayRefresh: Bool = true) -> AutoRefreshPolicy.Verdict {
        policy.scanFinished(agentAnswered: true, displaysWithSlots: [main, portrait], displays: [main, portrait], afterDisplayChange: false,
                            mayRefresh: mayRefresh, now: at(seconds))
    }

    /// A read in which the agent answered and the portrait display has no slots, the first after the displays changed (unless said).
    private func leftEmpty(_ policy: inout AutoRefreshPolicy, at seconds: Int, afterDisplayChange: Bool = true,
                           mayRefresh: Bool = true) -> AutoRefreshPolicy.Verdict {
        policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait],
                            afterDisplayChange: afterDisplayChange, mayRefresh: mayRefresh, now: at(seconds))
    }

    private let firstReason = "MenuBarAgent didn't answer 3 times in a row; refreshing (1 of 4); if it still doesn't answer, the next is in at least 1 minute"
    private let secondReason = "MenuBarAgent didn't answer 3 times in a row; refreshing (2 of 4); if it still doesn't answer, the next is in at least 5 minutes"
    private let thirdReason = "MenuBarAgent didn't answer 3 times in a row; refreshing (3 of 4); if it still doesn't answer, the next is in at least 15 minutes"
    private let fourthReason = "MenuBarAgent didn't answer 3 times in a row; refreshing (4 of 4); no more until it answers"
    private let emptyReason = "a display change left the menu bar empty; refreshing once"

    /// Fails every 10 seconds from `from` (10 by default) to `through`, and gives the times at which it refreshed, with the reasons.
    private func failEveryTenSeconds(_ policy: inout AutoRefreshPolicy, from first: Int = 10, through last: Int) -> [(at: Int, reason: String)] {
        var refreshes: [(at: Int, reason: String)] = []
        for second in stride(from: first, through: last, by: 10) {
            if case .refresh(let reason) = failed(&policy, at: second) { refreshes.append((second, reason)) }
        }
        return refreshes
    }

    @Test func theNumbersAreThreeAndAMinute() {
        #expect(AutoRefreshPolicy.failuresBeforeRefresh == 3)
        #expect(AutoRefreshPolicy.cooldown == .seconds(60))
    }

    @Test func backOffConstants() {
        #expect(AutoRefreshPolicy.backOff == [.seconds(60), .seconds(300), .seconds(900)])
        #expect(AutoRefreshPolicy.refreshesPerOutage == 4)
        #expect(AutoRefreshPolicy.backOff.allSatisfy { $0 >= AutoRefreshPolicy.cooldown }, "the cooldown is the floor under every wait")
        #expect(AutoRefreshPolicy.backOff == AutoRefreshPolicy.backOff.sorted(), "each wait is longer than the one before")
    }

    @Test func threeAgentFailuresRefreshOnce() {
        var policy = AutoRefreshPolicy()
        #expect(failed(&policy, at: 0) == .none)
        #expect(failed(&policy, at: 10) == .none)
        #expect(failed(&policy, at: 20) == .refresh(reason: firstReason))
        // Once: the fourth and fifth are the start of another count, and a minute has not gone by.
        #expect(failed(&policy, at: 30) == .none)
        #expect(failed(&policy, at: 40) == .none)
    }

    @Test func twoFailuresDoNothing() {
        var policy = AutoRefreshPolicy()
        #expect(failed(&policy, at: 0) == .none)
        #expect(failed(&policy, at: 10) == .none)
        #expect(answered(&policy, at: 20) == .none)
    }

    @Test func answerResetsStreak() {
        var policy = AutoRefreshPolicy()
        #expect(failed(&policy, at: 0) == .none)
        #expect(failed(&policy, at: 10) == .none)
        #expect(answered(&policy, at: 20) == .none, "a scan the agent answered")
        #expect(failed(&policy, at: 30) == .none)
        #expect(failed(&policy, at: 40) == .none, "two in a row again, not four")
        #expect(failed(&policy, at: 50) == .refresh(reason: firstReason), "and the third after the answer is the one")
    }

    @Test func emptyBarAfterDisplayChangeRefreshesOnce() {
        var policy = AutoRefreshPolicy()
        // The display that was plugged in has no slots yet, on the first read after the change.
        let verdict = leftEmpty(&policy, at: 0)
        #expect(verdict == .refresh(reason: emptyReason))
        // The read the refresh makes still shows the display empty, and that is not a second refresh (it isn't the first after a change).
        let again = leftEmpty(&policy, at: 1, afterDisplayChange: false)
        #expect(again == .none)
    }

    @Test func anEmptyBarWithoutADisplayChangeIsNothing() {
        var policy = AutoRefreshPolicy()
        let verdict = leftEmpty(&policy, at: 0, afterDisplayChange: false)
        #expect(verdict == .none, "a display with no slots is only a reason after the displays changed")
    }

    @Test func aDisplayChangeThatLeftEveryBarWithSlotsIsNothing() {
        var policy = AutoRefreshPolicy()
        let verdict = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main, portrait], displays: [main, portrait],
                                          afterDisplayChange: true, mayRefresh: true, now: at(0))
        #expect(verdict == .none)
        // Slots on a display that has gone are no matter, and no displays at all is nothing to be empty.
        #expect(policy.scanFinished(agentAnswered: true, displaysWithSlots: [main, "gone"], displays: [main], afterDisplayChange: true,
                                    mayRefresh: true, now: at(1)) == .none)
        #expect(policy.scanFinished(agentAnswered: true, displaysWithSlots: [], displays: [], afterDisplayChange: true, mayRefresh: true,
                                    now: at(2)) == .none)
    }

    @Test func aDisplayChangeReadTheAgentDidNotAnswerIsAnAgentFailureNotAnEmptyBar() {
        var policy = AutoRefreshPolicy()
        let verdict = policy.scanFinished(agentAnswered: false, displaysWithSlots: [], displays: [main, portrait], afterDisplayChange: true,
                                          mayRefresh: true, now: at(0))
        #expect(verdict == .none, "nothing was read, so nothing was found empty; it is the first of three")
        #expect(failed(&policy, at: 10) == .none)
        #expect(failed(&policy, at: 20) == .refresh(reason: firstReason))
    }

    @Test func cooldownBlocksSecondRefresh() {
        var policy = AutoRefreshPolicy()
        for second in [0, 10] { #expect(failed(&policy, at: second) == .none) }
        #expect(failed(&policy, at: 20) == .refresh(reason: firstReason))

        // A display change that leaves a bar empty, 30 seconds after: a minute hasn't gone by since the refresh.
        #expect(leftEmpty(&policy, at: 50) == .none)
        // The agent keeps failing: three more are counted, and still not before the minute is up.
        for second in [60, 70, 79] { #expect(failed(&policy, at: second) == .none, "\(second)") }
        // 60 seconds after the refresh, to the second, and the next failure of the streak is the one. (The read the agent answered, at
        // 50, was the first after the refresh and didn't end the outage: this is its second refresh, after the wait of a minute.)
        #expect(failed(&policy, at: 80) == .refresh(reason: secondReason))
    }

    @Test func aMinuteAfterTheRefreshAnotherIsAllowed() {
        var policy = AutoRefreshPolicy()
        #expect(leftEmpty(&policy, at: 0) == .refresh(reason: emptyReason))
        #expect(leftEmpty(&policy, at: 59) == .none)
        #expect(leftEmpty(&policy, at: 60) == .refresh(reason: emptyReason))
    }

    @Test func cooldownStillSeparatesAnyTwo() {
        // The empty bar, then the agent: the third failure comes at 30, and a minute from 0 is 60.
        var policy = AutoRefreshPolicy()
        #expect(leftEmpty(&policy, at: 0) == .refresh(reason: emptyReason))
        for second in [10, 20, 30, 40, 50] { #expect(failed(&policy, at: second) == .none, "\(second)") }
        #expect(failed(&policy, at: 60) == .refresh(reason: firstReason))

        // The agent, then the empty bar: an answered read leaves the time of the last refresh alone, so what the minute is counted from
        // is the refresh at 30, not the read that was answered at 35.
        var other = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&other, through: 30).map(\.at) == [30])
        #expect(answered(&other, at: 35) == .none)
        #expect(leftEmpty(&other, at: 89) == .none, "59 seconds after the refresh")
        #expect(leftEmpty(&other, at: 90) == .refresh(reason: emptyReason), "60 seconds after it, and 55 after the answered read")

        // After two refreshes for the agent, the empty bar still waits its minute from the second.
        var third = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&third, through: 90).map(\.at) == [30, 90])
        #expect(leftEmpty(&third, at: 100) == .none, "10 seconds after the second")
        #expect(leftEmpty(&third, at: 150) == .refresh(reason: emptyReason))
    }

    // MARK: The back-off

    @Test func refreshesAtMostFourTimesPerOutage() {
        var policy = AutoRefreshPolicy()
        // The agent doesn't answer once in ten seconds for two hours: the third failure is at 30.
        let refreshes = failEveryTenSeconds(&policy, through: 2 * 60 * 60)
        let times = refreshes.map(\.at)
        #expect(times == [30, 90, 390, 1290], "at 30 seconds, then after 1, 5 and 15 minutes at the soonest, and none after that")
        for (earlier, later, wait) in zip3(times, AutoRefreshPolicy.backOff) {
            #expect(later - earlier >= Int(wait.components.seconds), "\(earlier) to \(later)")
        }
        #expect(refreshes.count == AutoRefreshPolicy.refreshesPerOutage)
    }

    /// Each time with the one before and the wait that has to be between them (as far as there are waits: a policy that refreshes more
    /// than it should fails the count, and isn't to crash this).
    private func zip3(_ times: [Int], _ waits: [Duration]) -> [(Int, Int, Duration)] {
        (1..<max(1, min(times.count, waits.count + 1))).map { (times[$0 - 1], times[$0], waits[$0 - 1]) }
    }

    @Test func aWaitIsFromTheLastRefreshAndNotFromTheLastFailure() {
        var policy = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&policy, through: 30).map(\.at) == [30])
        // Failures go on, and the count is already past three, but the minute from 30 isn't up until 90.
        #expect(failEveryTenSeconds(&policy, from: 40, through: 80).isEmpty)
        #expect(failed(&policy, at: 89) == .none)
        #expect(failed(&policy, at: 90) == .refresh(reason: secondReason))
        // 300 seconds from 90.
        #expect(failEveryTenSeconds(&policy, from: 100, through: 380).isEmpty)
        #expect(failed(&policy, at: 389) == .none)
        #expect(failed(&policy, at: 390) == .refresh(reason: thirdReason))
        // 900 seconds from 390.
        #expect(failEveryTenSeconds(&policy, from: 400, through: 1280).isEmpty)
        #expect(failed(&policy, at: 1289) == .none)
        #expect(failed(&policy, at: 1290) == .refresh(reason: fourthReason))
    }

    @Test func eachStepSaysItsNumberAndTheNextWait() {
        var policy = AutoRefreshPolicy()
        let reasons = failEveryTenSeconds(&policy, through: 1500).map(\.reason)
        #expect(reasons == [firstReason, secondReason, thirdReason, fourthReason])
        #expect(firstReason.contains("(1 of 4)") && firstReason.hasSuffix("at least 1 minute"))
        #expect(secondReason.contains("(2 of 4)") && secondReason.hasSuffix("at least 5 minutes"))
        #expect(thirdReason.contains("(3 of 4)") && thirdReason.hasSuffix("at least 15 minutes"))
        #expect(fourthReason.contains("(4 of 4)") && fourthReason.hasSuffix("no more until it answers"))
        #expect(!reasons.contains { $0.hasSuffix(".") }, "sentences for the log have no full stop")
    }

    @Test func anAnsweredReadStartsOver() {
        // After two refreshes (30 and 90) an answered read ends the outage: the next one is a first, and waits the minute and not the five.
        var policy = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&policy, through: 90).map(\.at) == [30, 90])
        #expect(answered(&policy, at: 100) == .none)
        #expect(answered(&policy, at: 110) == .none, "answered for ten seconds: that ends it")
        #expect(failEveryTenSeconds(&policy, from: 120, through: 140).isEmpty, "three failures, but 60 seconds from 90 is 150")
        #expect(failed(&policy, at: 150) == .refresh(reason: firstReason), "the first of a new outage, and not the third")

        // After the fourth, the stop: an answered read lifts it.
        var stopped = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&stopped, through: 1290).map(\.at) == [30, 90, 390, 1290])
        #expect(failEveryTenSeconds(&stopped, from: 1300, through: 1400).isEmpty, "nothing more: there are only four")
        #expect(answered(&stopped, at: 1410) == .none)
        #expect(answered(&stopped, at: 1420) == .none)
        #expect(failEveryTenSeconds(&stopped, from: 1430, through: 1440).isEmpty, "two failures are not three")
        #expect(failed(&stopped, at: 1450) == .refresh(reason: firstReason), "the third: the outage is a new one, and its first refresh is due")
    }

    @Test func anAgentThatAnswersEachRefreshsOwnReadAndNothingElseIsRefreshedFourTimes() {
        // It is silent for three reads, answers the read that the refresh makes, and is silent again: the answer is not the end of the
        // outage, so the waits of the back-off go on and the fifth refresh never comes.
        var policy = AutoRefreshPolicy()
        var refreshedAt: [Int] = []
        var second = 0
        while second <= 3 * 3600 {
            second += 10
            if case .refresh = failed(&policy, at: second) {
                refreshedAt.append(second)
                #expect(answered(&policy, at: second + 1) == .none, "the refresh's own read")
            }
        }
        #expect(refreshedAt == [30, 90, 390, 1290])
    }

    @Test func answersForTenSecondsInARowEndAnOutageWhateverComesAfter() {
        var policy = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&policy, through: 90).map(\.at) == [30, 90])
        #expect(answered(&policy, at: 91) == .none)
        #expect(failed(&policy, at: 100) == .none, "silent again after one answer: the outage goes on")
        #expect(answered(&policy, at: 110) == .none, "a read it didn't answer started the span again: this is its first answer")
        #expect(answered(&policy, at: 120) == .none)
        #expect(failEveryTenSeconds(&policy, from: 130, through: 140).isEmpty)
        #expect(failed(&policy, at: 150) == .refresh(reason: firstReason), "a new outage: 60 seconds from the refresh at 90, and not 300")
    }

    /// Two answers with a silence between them aren't answers in a row: the outage goes on, and its third refresh waits out the back-off.
    @Test func answersWithASilenceBetweenThemDontEndAnOutage() {
        var policy = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&policy, through: 90).map(\.at) == [30, 90])
        #expect(answered(&policy, at: 91) == .none)
        #expect(failed(&policy, at: 100) == .none)
        #expect(answered(&policy, at: 110) == .none)
        #expect(failEveryTenSeconds(&policy, from: 120, through: 380).isEmpty, "no new outage at 150: the 3rd waits 5 minutes from 90")
        #expect(failed(&policy, at: 390) == .refresh(reason: AutoRefreshPolicy.agentReason(refreshNumber: 3)))
    }

    /// With Settings open the bar is read every two seconds, and an agent that answers the refresh's own read and the poll after it before
    /// going silent again has answered twice, but not for ten seconds: four refreshes, and no more.
    @Test func anAgentThatAnswersForAMomentAfterEachRefreshWithSettingsOpenIsRefreshedFourTimes() {
        var policy = AutoRefreshPolicy()
        var refreshedAt: [Int] = []
        var lastRefresh = -100
        var second = 0
        while second <= 3 * 3600 {
            second += 2
            if second - lastRefresh <= 4 {
                #expect(answered(&policy, at: second) == .none)
            } else if case .refresh = failed(&policy, at: second) {
                refreshedAt.append(second)
                lastRefresh = second
            }
        }
        #expect(refreshedAt.count == AutoRefreshPolicy.refreshesPerOutage, "\(refreshedAt)")
    }

    @Test func wakingStartsOverAtOnce() {
        // After the fourth, the stop: a wake lifts it and the count is the first again. The minute is the floor between any two
        // refreshes, a wake between them as well, so the first one after it waits out what is left of the minute from the fourth.
        var stopped = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&stopped, through: 1290).map(\.at) == [30, 90, 390, 1290])
        stopped.woke()
        #expect(failEveryTenSeconds(&stopped, from: 1300, through: 1340).isEmpty, "three failures at 1320, and 30 seconds is not a minute")
        #expect(failed(&stopped, at: 1349) == .none)
        #expect(failed(&stopped, at: 1350) == .refresh(reason: firstReason), "60 seconds after the fourth, and the first of four again")

        // A wake after the minute has gone by: the third failure after it is the one, with no wait of the back-off.
        var later = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&later, through: 1290).map(\.at) == [30, 90, 390, 1290])
        later.woke()
        #expect(failed(&later, at: 1400) == .none)
        #expect(failed(&later, at: 1410) == .none)
        #expect(failed(&later, at: 1420) == .refresh(reason: firstReason), "the stop is gone: the third failure counted after the wake")

        // In the middle of the back-off: the count is the first again, and so is the wait, which is the minute from the last refresh.
        var middle = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&middle, through: 90).map(\.at) == [30, 90])
        middle.woke()
        #expect(failEveryTenSeconds(&middle, from: 100, through: 140).isEmpty)
        #expect(failed(&middle, at: 150) == .refresh(reason: firstReason), "not the 300 seconds from 90 that the third needed, and not before 60")

        // Failures that were counted before it aren't counted after it.
        var counted = AutoRefreshPolicy()
        #expect(failed(&counted, at: 0) == .none)
        #expect(failed(&counted, at: 10) == .none)
        counted.woke()
        #expect(failed(&counted, at: 20) == .none, "the first of three, and not the third")
        #expect(failed(&counted, at: 30) == .none)
        #expect(failed(&counted, at: 40) == .refresh(reason: firstReason))
    }

    @Test func aWakeDoesNotLiftTheCooldownForAnyKindOfRefresh() {
        // An empty bar right after a wake can't come within the minute of a refresh before it: the agent's, then a wake.
        var afterTheAgent = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&afterTheAgent, through: 30).map(\.at) == [30])
        afterTheAgent.woke()
        #expect(leftEmpty(&afterTheAgent, at: 40) == .none, "10 seconds after the refresh")
        #expect(leftEmpty(&afterTheAgent, at: 89) == .none, "59 seconds after it")
        #expect(leftEmpty(&afterTheAgent, at: 90) == .refresh(reason: emptyReason), "60 seconds after it")

        // The same when the display change was read while held back, and the wake came after it: it is judged by the first read after
        // the wake, which is inside the minute, and so is passed over, and not remembered.
        var heldChange = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&heldChange, through: 30).map(\.at) == [30])
        #expect(leftEmpty(&heldChange, at: 35, mayRefresh: false) == .none)
        heldChange.woke()
        #expect(leftEmpty(&heldChange, at: 40, afterDisplayChange: false) == .none, "judged, 10 seconds after the refresh")
        #expect(leftEmpty(&heldChange, at: 90, afterDisplayChange: false) == .none, "and not remembered")
        #expect(leftEmpty(&heldChange, at: 91) == .refresh(reason: emptyReason), "the next display change, after the minute")

        // An empty bar's refresh, then a wake: the agent's first refresh waits out the minute from it too.
        var afterTheEmptyBar = AutoRefreshPolicy()
        #expect(leftEmpty(&afterTheEmptyBar, at: 0) == .refresh(reason: emptyReason))
        afterTheEmptyBar.woke()
        #expect(failEveryTenSeconds(&afterTheEmptyBar, from: 10, through: 50).isEmpty, "the third failure is at 30; the minute is at 60")
        #expect(failed(&afterTheEmptyBar, at: 60) == .refresh(reason: firstReason))
    }

    // MARK: While nobody is looking

    @Test func nothingWhileHeldAndFailuresAreNotCounted() {
        var policy = AutoRefreshPolicy()
        #expect(failed(&policy, at: 0) == .none)
        #expect(failed(&policy, at: 10) == .none)
        // Held for a long time: nothing, whatever is read, and not counted.
        for second in stride(from: 20, through: 400, by: 10) {
            #expect(failed(&policy, at: second, mayRefresh: false) == .none, "\(second)")
        }
        #expect(answered(&policy, at: 410, mayRefresh: false) == .none)
        #expect(leftEmpty(&policy, at: 420, mayRefresh: false) == .none)
        // Back: the two failures from before are still two, and the held ones did not make a third.
        #expect(failed(&policy, at: 430) == .refresh(reason: firstReason), "the third failure that counts")

        // From nothing: held failures are not the first three.
        var fresh = AutoRefreshPolicy()
        for second in stride(from: 0, through: 100, by: 10) { #expect(failed(&fresh, at: second, mayRefresh: false) == .none) }
        #expect(failed(&fresh, at: 110) == .none)
        #expect(failed(&fresh, at: 120) == .none)
        #expect(failed(&fresh, at: 130) == .refresh(reason: firstReason))
    }

    @Test func aHeldReadDoesNotEndAnOutageOrCountAsOne() {
        // Neither a read that is answered nor one that isn't changes what has been counted while held.
        var policy = AutoRefreshPolicy()
        #expect(failEveryTenSeconds(&policy, through: 30).map(\.at) == [30])
        #expect(answered(&policy, at: 40, mayRefresh: false) == .none)
        #expect(failed(&policy, at: 50, mayRefresh: false) == .none)
        // Still the second step of the back-off, the minute from 30.
        #expect(failEveryTenSeconds(&policy, from: 60, through: 80).isEmpty)
        #expect(failed(&policy, at: 90) == .refresh(reason: secondReason))
    }

    @Test func displayChangeSeenWhileHeldIsJudgedAfter() {
        var policy = AutoRefreshPolicy()
        // The displays change while the screen is locked: the read for it is held, and says nothing.
        #expect(leftEmpty(&policy, at: 0, mayRefresh: false) == .none)
        // The first read that may refresh is judged as if it followed the change, though it isn't marked as one.
        #expect(leftEmpty(&policy, at: 10, afterDisplayChange: false) == .refresh(reason: emptyReason))
        // Only the first one: the read the refresh makes isn't judged again.
        #expect(leftEmpty(&policy, at: 100, afterDisplayChange: false) == .none, "a minute later, and not judged again")

        // A read that isn't of a display change, held, remembers nothing.
        var other = AutoRefreshPolicy()
        #expect(leftEmpty(&other, at: 0, afterDisplayChange: false, mayRefresh: false) == .none)
        #expect(leftEmpty(&other, at: 10, afterDisplayChange: false) == .none)

        // The first read that may refresh is the one, whether or not the bar is empty in it: a later one isn't.
        var full = AutoRefreshPolicy()
        #expect(leftEmpty(&full, at: 0, mayRefresh: false) == .none)
        #expect(answered(&full, at: 10) == .none, "every display has slots")
        #expect(leftEmpty(&full, at: 20, afterDisplayChange: false) == .none, "the change was judged by the read before")
    }

    @Test func displayChangeSeenWhileHeldSurvivesTheWake() {
        // The displays' notification can come before the one that wakes them: the change is read while held, then the wake starts
        // everything over, and the change is judged all the same.
        var policy = AutoRefreshPolicy()
        #expect(leftEmpty(&policy, at: 0, mayRefresh: false) == .none)
        policy.woke()
        #expect(leftEmpty(&policy, at: 5, afterDisplayChange: false) == .refresh(reason: emptyReason))
    }

    @Test func theReasonsAreSentencesForTheLog() {
        for reason in [firstReason, secondReason, thirdReason, fourthReason, emptyReason] { #expect(!reason.hasSuffix(".")) }
    }

    // MARK: Which displays have slots

    private func item(_ frames: [String: CGRect], overflowedOn: Set<String> = []) -> MenuBarItem {
        MenuBarItem(id: .system("clock"), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil, frames: frames,
                    overflowedOn: overflowedOn, isMantel: false)
    }

    private func inventory(items: [MenuBarItem], untied: [String: [CGRect]] = [:]) -> Inventory {
        Inventory(capturedAt: start, bars: [], items: items, chevrons: [:], reach: [], problems: [], untiedSlots: untied)
    }

    @Test func aDisplayHasSlotsWhenAnItemIsOnItOrInItsOverflowOrASlotIsUnclaimed() {
        let frame = CGRect(x: 0, y: 0, width: 30, height: 24)
        #expect(inventory(items: [item([main: frame])]).displaysWithSlots == [main])
        #expect(inventory(items: [item([:], overflowedOn: [portrait])]).displaysWithSlots == [portrait], "piled at the « is on the bar")
        #expect(inventory(items: [], untied: [portrait: [frame]]).displaysWithSlots == [portrait])
        #expect(inventory(items: [item([main: frame, portrait: frame])]).displaysWithSlots == [main, portrait])
        #expect(inventory(items: [item([:])]).displaysWithSlots.isEmpty, "a concealed item is on no bar")
        #expect(inventory(items: [], untied: [main: []]).displaysWithSlots.isEmpty)
        #expect(Inventory.empty.displaysWithSlots.isEmpty)
    }
}
