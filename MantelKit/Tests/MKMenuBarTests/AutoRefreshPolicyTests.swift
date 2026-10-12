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
    private func failed(_ policy: inout AutoRefreshPolicy, at seconds: Int) -> AutoRefreshPolicy.Verdict {
        policy.scanFinished(agentAnswered: false, displaysWithSlots: [], displays: [], afterDisplayChange: false, now: at(seconds))
    }

    /// A read in which the agent answered and every display has slots.
    private func answered(_ policy: inout AutoRefreshPolicy, at seconds: Int) -> AutoRefreshPolicy.Verdict {
        policy.scanFinished(agentAnswered: true, displaysWithSlots: [main, portrait], displays: [main, portrait], afterDisplayChange: false,
                            now: at(seconds))
    }

    private let agentReason = "MenuBarAgent didn't answer 3 times in a row; refreshing once"
    private let emptyReason = "a display change left the menu bar empty; refreshing once"

    @Test func theNumbersAreThreeAndAMinute() {
        #expect(AutoRefreshPolicy.failuresBeforeRefresh == 3)
        #expect(AutoRefreshPolicy.cooldown == .seconds(60))
    }

    @Test func threeAgentFailuresRefreshOnce() {
        var policy = AutoRefreshPolicy()
        #expect(failed(&policy, at: 0) == .none)
        #expect(failed(&policy, at: 10) == .none)
        #expect(failed(&policy, at: 20) == .refresh(reason: agentReason))
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
        #expect(failed(&policy, at: 50) == .refresh(reason: agentReason), "and the third after the answer is the one")
    }

    @Test func emptyBarAfterDisplayChangeRefreshesOnce() {
        var policy = AutoRefreshPolicy()
        // The display that was plugged in has no slots yet, on the first read after the change.
        let verdict = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: true,
                                          now: at(0))
        #expect(verdict == .refresh(reason: emptyReason))
        // The read the refresh makes still shows the display empty, and that is not a second refresh (it isn't the first after a change).
        let again = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: false,
                                        now: at(1))
        #expect(again == .none)
    }

    @Test func anEmptyBarWithoutADisplayChangeIsNothing() {
        var policy = AutoRefreshPolicy()
        let verdict = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: false,
                                          now: at(0))
        #expect(verdict == .none, "a display with no slots is only a reason after the displays changed")
    }

    @Test func aDisplayChangeThatLeftEveryBarWithSlotsIsNothing() {
        var policy = AutoRefreshPolicy()
        let verdict = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main, portrait], displays: [main, portrait],
                                          afterDisplayChange: true, now: at(0))
        #expect(verdict == .none)
        // Slots on a display that has gone are no matter, and no displays at all is nothing to be empty.
        #expect(policy.scanFinished(agentAnswered: true, displaysWithSlots: [main, "gone"], displays: [main], afterDisplayChange: true,
                                    now: at(1)) == .none)
        #expect(policy.scanFinished(agentAnswered: true, displaysWithSlots: [], displays: [], afterDisplayChange: true, now: at(2)) == .none)
    }

    @Test func aDisplayChangeReadTheAgentDidNotAnswerIsAnAgentFailureNotAnEmptyBar() {
        var policy = AutoRefreshPolicy()
        let verdict = policy.scanFinished(agentAnswered: false, displaysWithSlots: [], displays: [main, portrait], afterDisplayChange: true,
                                          now: at(0))
        #expect(verdict == .none, "nothing was read, so nothing was found empty; it is the first of three")
        #expect(failed(&policy, at: 10) == .none)
        #expect(failed(&policy, at: 20) == .refresh(reason: agentReason))
    }

    @Test func cooldownBlocksSecondRefresh() {
        var policy = AutoRefreshPolicy()
        for second in [0, 10] { #expect(failed(&policy, at: second) == .none) }
        #expect(failed(&policy, at: 20) == .refresh(reason: agentReason))

        // A display change that leaves a bar empty, 30 seconds after: a minute hasn't gone by since the refresh.
        let blocked = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: true,
                                          now: at(50))
        #expect(blocked == .none)
        // The agent keeps failing: three more are counted, and still not before the minute is up.
        for second in [60, 70, 79] { #expect(failed(&policy, at: second) == .none, "\(second)") }
        // 60 seconds after the refresh, to the second, and the next failure of the streak is the one.
        #expect(failed(&policy, at: 80) == .refresh(reason: agentReason))
    }

    @Test func aMinuteAfterTheRefreshAnotherIsAllowed() {
        var policy = AutoRefreshPolicy()
        let first = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: true,
                                        now: at(0))
        #expect(first == .refresh(reason: emptyReason))
        let tooSoon = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: true,
                                          now: at(59))
        #expect(tooSoon == .none)
        let later = policy.scanFinished(agentAnswered: true, displaysWithSlots: [main], displays: [main, portrait], afterDisplayChange: true,
                                        now: at(60))
        #expect(later == .refresh(reason: emptyReason))
    }

    @Test func theReasonsAreSentencesForTheLog() {
        #expect(!agentReason.hasSuffix("."))
        #expect(!emptyReason.hasSuffix("."))
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
