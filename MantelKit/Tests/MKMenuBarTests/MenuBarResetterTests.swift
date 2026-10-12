import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// What the app does around a reset: asks whether it may, says to the probes that one is under way, and refuses a second.
@Suite("Menu bar resetter", .timeLimit(.minutes(1)))
struct MenuBarResetterTests {
    private let platformTestText = "A platform test is changing the menu bar. Try again when it finishes."

    private func started() async -> (rig: SessionRig, engine: FakeEngine, log: CallLog) {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [SessionWorld.weather]), events: log)
        await rig.session.start()
        return (rig, engine, log)
    }

    private func resetter(_ rig: SessionRig, restarter: FakeRestarter, log: CallLog, activity: ResetActivity = ResetActivity(),
                          refusal: @escaping @Sendable () async -> String? = { nil }) -> MenuBarResetter {
        MenuBarResetter(session: rig.session, restarter: restarter, replayJournal: { log.add("replay") }, refusal: refusal, activity: activity)
    }

    @Test func aResetDuringAPlatformTestIsRefused() async throws {
        let (rig, engine, log) = await started()
        let activity = ResetActivity()
        let restarter = FakeRestarter(log: log)
        let before = log.all

        let outcome = await resetter(rig, restarter: restarter, log: log, activity: activity, refusal: {
            ReplayNowPolicy.resetRefusal(probeChangingMenuBar: true)
        }).reset()

        #expect(outcome == .refused(platformTestText))
        #expect(outcome.result == .failure(code: .unavailable, message: platformTestText))
        // Nothing was torn down, replayed or signalled.
        #expect(log.all == before)
        #expect(engine.tornDown == 0)
        #expect(restarter.restarts == 0)
        #expect(!activity.isUnderWay, "and the probes are not held up")
    }

    @Test func theProbesAreToldWhileAResetRuns() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        #expect(!activity.isUnderWay)

        let running = Task { await resetter(rig, restarter: restarter, log: log, activity: activity).reset() }
        #expect(await waitUntil { restarter.restarts == 1 })
        #expect(activity.isUnderWay, "while the menu bar is being restarted")

        gate.open()
        #expect(await running.value == .done)
        #expect(!activity.isUnderWay)
    }

    @Test func theProbesAreToldBeforeAnythingIsAskedSoNoneStartsInBetween() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let seen = Mutex<Bool?>(nil)

        _ = await resetter(rig, restarter: FakeRestarter(log: log), log: log, activity: activity, refusal: {
            seen.withLock { $0 = activity.isUnderWay }
            return nil
        }).reset()

        #expect(seen.withLock { $0 } == true, "a probe that began while the refusal was being worked out would find the flag set")
    }

    @Test func aSecondResetIsRefusedBeforeItAsksAnything() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        let asked = Mutex(0)
        let counting: @Sendable () async -> String? = {
            asked.withLock { $0 += 1 }
            return nil
        }
        let first = Task { await resetter(rig, restarter: restarter, log: log, activity: activity, refusal: counting).reset() }
        #expect(await waitUntil { restarter.restarts == 1 })

        let second = await resetter(rig, restarter: restarter, log: log, activity: activity, refusal: counting).reset()

        #expect(second == .alreadyUnderWay)
        #expect(asked.withLock { $0 } == 1, "it didn't even ask")
        #expect(activity.isUnderWay, "and the first one's flag stays up")
        gate.open()
        #expect(await first.value == .done)
        #expect(!activity.isUnderWay)
    }

    @Test func theFlagComesDownWhenAResetFails() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let restarter = FakeRestarter(log: log)
        restarter.fail(with: .notRunning)

        let outcome = await resetter(rig, restarter: restarter, log: log, activity: activity).reset()

        #expect(outcome == .failed("macOS's menu bar isn't running. Log out and back in to start it."))
        #expect(!activity.isUnderWay)
    }

    @Test func theActivityIsSetOnceAtATime() {
        let activity = ResetActivity()
        #expect(activity.begin())
        #expect(!activity.begin(), "a second begin is refused")
        #expect(activity.isUnderWay)
        activity.end()
        #expect(!activity.isUnderWay)
        #expect(activity.begin())
    }
}
