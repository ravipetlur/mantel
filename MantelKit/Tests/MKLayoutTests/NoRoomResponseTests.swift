import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("No room response", .timeLimit(.minutes(1)))
struct NoRoomResponseTests {
    private func check(_ apps: Set<String> = ["com.example.one"], round: Int = 0, needed: CGFloat = 40) -> RoomCheck {
        RoomCheck(overflowedRevealedApps: apps, neededWidth: needed, round: round)
    }

    @Test func secondBarPolicyOpensSecondBar() {
        // However many apps, however many rounds, whatever was logged, and whether or not the bar was taken over before: the revealed
        // icons that have no room are shown in the second bar.
        for apps in [["com.example.one"], ["com.example.one", "com.example.two"]] {
            for round in [0, 1, 3, 10] {
                for alreadyLogged in [false, true] {
                    for taken in [false, true] {
                        let action = NoRoomResponse.decide(policy: .secondBar, check: check(Set(apps), round: round),
                                                           alreadyLogged: alreadyLogged, menuBarTakenOver: taken)
                        #expect(action == .openSecondBar, "\(apps.count) apps, round \(round), logged \(alreadyLogged), taken over \(taken)")
                    }
                }
            }
        }
    }

    @Test func takeoverFallbackStillLeavesOverflow() {
        // The line for icons left in the « menu is what is said when the menu bar was taken over and they still don't fit.
        #expect(NoRoomResponse.decide(policy: .hideAppMenus, check: check(), alreadyLogged: false, menuBarTakenOver: true)
            == .leaveOverflow(logOnce: true))
        #expect(NoRoomResponse.decide(policy: .hideAppMenus, check: check(), alreadyLogged: true, menuBarTakenOver: true)
            == .leaveOverflow(logOnce: false))
        #expect(NoRoomResponse.overflowLogLine == "no room for the revealed icons; macOS's « menu keeps them")
        // And a swap and a takeover never open the second bar.
        for policy in [NoRoomPolicy.swap, .hideAppMenus] {
            for taken in [false, true] {
                #expect(NoRoomResponse.decide(policy: policy, check: check(), alreadyLogged: false, menuBarTakenOver: taken) != .openSecondBar)
            }
        }
    }

    @Test func swapUpToThreeRoundsThenGivesUp() {
        #expect(SwapCalculator.maximumRounds == 3)
        // The rounds before the third are tried, each named by its own number.
        for round in 0..<SwapCalculator.maximumRounds {
            #expect(NoRoomResponse.decide(policy: .swap, check: check(round: round), alreadyLogged: false, menuBarTakenOver: false)
                == .swap(round: round), "round \(round)")
        }
        // Then it stops, with the text for the log, however often it is asked.
        for round in [3, 4, 100] {
            #expect(NoRoomResponse.decide(policy: .swap, check: check(round: round), alreadyLogged: false, menuBarTakenOver: false)
                == .giveUp("Couldn't make room for every hidden icon."), "round \(round)")
        }
        #expect(NoRoomResponse.giveUpText == "Couldn't make room for every hidden icon.")
        // What was logged and whether the menu bar is Mantel's don't matter to a swap.
        #expect(NoRoomResponse.decide(policy: .swap, check: check(round: 1), alreadyLogged: true, menuBarTakenOver: true) == .swap(round: 1))
        #expect(NoRoomResponse.decide(policy: .swap, check: check(round: 3), alreadyLogged: true, menuBarTakenOver: true)
            == .giveUp(NoRoomResponse.giveUpText))
    }

    @Test func hideAppMenusTakesOverOnce() {
        // Not taken over yet: take it over, whether or not the « line was logged, and however many tries.
        for alreadyLogged in [false, true] {
            for round in [0, 1, 5] {
                #expect(NoRoomResponse.decide(policy: .hideAppMenus, check: check(round: round), alreadyLogged: alreadyLogged,
                                              menuBarTakenOver: false) == .takeOverMenuBar)
            }
        }
        // Already taken over and the icons still don't fit: there is nothing more to do but leave them, and say so once.
        #expect(NoRoomResponse.decide(policy: .hideAppMenus, check: check(), alreadyLogged: false, menuBarTakenOver: true)
            == .leaveOverflow(logOnce: true))
        #expect(NoRoomResponse.decide(policy: .hideAppMenus, check: check(), alreadyLogged: true, menuBarTakenOver: true)
            == .leaveOverflow(logOnce: false))
    }

    @Test func noOverflowNoAction() {
        for policy in NoRoomPolicy.allCases {
            for alreadyLogged in [false, true] {
                for taken in [false, true] {
                    for round in [0, 2, 3, 9] {
                        let action = NoRoomResponse.decide(policy: policy, check: check([], round: round, needed: 0),
                                                           alreadyLogged: alreadyLogged, menuBarTakenOver: taken)
                        #expect(action == .none, "\(policy), logged \(alreadyLogged), taken over \(taken), round \(round)")
                    }
                }
            }
        }
    }
}
