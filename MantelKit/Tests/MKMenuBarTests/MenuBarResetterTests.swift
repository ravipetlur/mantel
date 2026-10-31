import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What the app does around a reset: sets the flag that says one is under way, and refuses a second.
@Suite("Menu bar resetter", .timeLimit(.minutes(1)))
struct MenuBarResetterTests {
    private func started() async -> (rig: SessionRig, engine: FakeEngine, log: CallLog) {
        let log = CallLog()
        let engine = FakeEngine(.allowlist, log: log)
        let rig = SessionRig.withEngines([.allowlist: engine], sections: sections(hidden: [SessionWorld.weather]), events: log)
        await rig.session.start()
        return (rig, engine, log)
    }

    private func resetter(_ rig: SessionRig, restarter: FakeRestarter, log: CallLog, activity: ResetActivity = ResetActivity()) -> MenuBarResetter {
        MenuBarResetter(session: rig.session, restarter: restarter, replayJournal: { log.add("replay") }, activity: activity)
    }

    /// Reads the flag the way the product does, through `begin()`: a begin that is refused means a reset is under way. One that isn't has
    /// set the flag, and is undone.
    private func isUnderWay(_ activity: ResetActivity) -> Bool {
        guard activity.begin() else { return true }
        activity.end()
        return false
    }

    @Test func theActivityIsSetWhileAResetRuns() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        #expect(!isUnderWay(activity))

        let running = Task { await resetter(rig, restarter: restarter, log: log, activity: activity).reset() }
        #expect(await waitUntil { restarter.restarts == 1 })
        #expect(isUnderWay(activity), "while the menu bar is being restarted")

        gate.open()
        #expect(await running.value == .done)
        #expect(!isUnderWay(activity))
    }

    @Test func aSecondResetIsRefusedAtOnce() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        let first = Task { await resetter(rig, restarter: restarter, log: log, activity: activity).reset() }
        #expect(await waitUntil { restarter.restarts == 1 })

        let second = await resetter(rig, restarter: restarter, log: log, activity: activity).reset()

        #expect(second == .alreadyUnderWay)
        #expect(restarter.restarts == 1, "and it restarted nothing")
        #expect(isUnderWay(activity), "and the first one's flag stays up")
        gate.open()
        #expect(await first.value == .done)
        #expect(!isUnderWay(activity))
    }

    @Test func theFlagComesDownWhenAResetFails() async throws {
        let (rig, _, log) = await started()
        let activity = ResetActivity()
        let restarter = FakeRestarter(log: log)
        restarter.fail(with: .notRunning)

        let outcome = await resetter(rig, restarter: restarter, log: log, activity: activity).reset()

        #expect(outcome == .failed("macOS's menu bar isn't running. Log out and back in to start it."))
        #expect(!isUnderWay(activity))
    }

    @Test func theActivityIsSetOnceAtATime() {
        let activity = ResetActivity()
        #expect(activity.begin())
        #expect(!activity.begin(), "a second begin is refused")
        activity.end()
        #expect(activity.begin(), "and after end() it is set again")
    }
}
