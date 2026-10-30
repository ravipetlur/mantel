import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What the session does when the person gives Mantel a file, or puts back what a platform test left: what depends on it is asked again,
/// and the state says so. (Every engine here is a fake, or a real one over a file in a folder of the test's own.)
@Suite("Session: permissions that change", .serialized, .timeLimit(.minutes(1)))
struct MenuBarSessionPermissionsTests {
    private let needsTheFile = "Choose the “Allow in the Menu Bar” file in Settings › Permissions"

    private func rig(method: HidingMethodChoice, log: CallLog = CallLog(), approvals: EngineAvailability) -> (SessionRig, FakeEngine) {
        let approvalsEngine = FakeEngine(.approvals, log: log)
        approvalsEngine.setAvailability(approvals)
        var settings = HidingSettings()
        settings.method = method
        let rig = SessionRig.withEngines(
            [.allowlist: FakeEngine(.allowlist, log: log), .approvals: approvalsEngine, .spacer: FakeEngine(.spacer, log: log)],
            sections: sections(hidden: [SessionWorld.weather]), settings: settings, events: log)
        return (rig, approvalsEngine)
    }

    @Test func aGrantMakesTheSwitchesUsableAndTheListOfTurnedOffAppsReadable() async throws {
        let (rig, approvals) = rig(method: .systemSettingsSwitches, approvals: .needsPermission(needsTheFile))
        rig.turnedOff.set(.unavailable("Choose the “Allow in the Menu Bar” file in Permissions to see this list."))
        await rig.session.start()

        // Before: the saved choice can't be used, and says why; the list says it can't be read.
        let before = try #require(await rig.state)
        #expect(before.engine.unavailableReasons[.approvals] == needsTheFile)
        #expect(before.engine.kind == .allowlist, "Automatic's chain is in use meanwhile")
        #expect(before.lists.turnedOff == .unavailable("Choose the “Allow in the Menu Bar” file in Permissions to see this list."))

        // The person chooses the file in Permissions.
        approvals.setAvailability(.available)
        rig.turnedOff.set(.apps(["com.example.off"]))
        await rig.session.permissionsChanged()

        let after = try #require(await rig.state)
        #expect(after.engine.unavailableReasons[.approvals] == nil)
        #expect(after.engine.availability[.approvals] == "available")
        #expect(after.lists.turnedOff == .apps(["com.example.off"]))
        #expect(after.engine.kind == .approvals, "the choice that was saved is in use now that it can be")
    }

    @Test func aReplayThatClearsALeftoverClearsTheReasonToo() async throws {
        // A platform test's change that hasn't been put back keeps the switches from being used ("Replay now" puts it back).
        let (rig, approvals) = rig(method: .automatic, approvals: .broken("A platform test's change to this list hasn't been put back yet"))
        await rig.session.start()
        #expect(try #require(await rig.state).engine.unavailableReasons[.approvals] != nil)

        approvals.setAvailability(.available)
        await rig.session.permissionsChanged()

        #expect(try #require(await rig.state).engine.unavailableReasons.isEmpty)
    }

    @Test func aChangeThatLeavesTheChoiceAsItWasSwitchesNothing() async throws {
        let log = CallLog()
        let (rig, _) = rig(method: .automatic, log: log, approvals: .available)
        await rig.session.start()
        let engineCalls = { log.all.filter { $0.hasSuffix(".apply") || $0.hasSuffix(".tearDown") || $0.hasSuffix(".reapply") } }
        let before = engineCalls()
        let published = try #require(await rig.state)

        await rig.session.permissionsChanged()

        #expect(engineCalls() == before, "no engine was applied to, switched to or taken down")
        #expect(try #require(await rig.state) == published, "and nothing changed in what is said")
        #expect(published.engine.kind == .allowlist)
    }

    @Test func aGrantThatDoesNotMatterToTheEngineInUseStillUpdatesTheList() async throws {
        let (rig, _) = rig(method: .automatic, approvals: .available)
        rig.turnedOff.set(.unavailable("Choose the file."))
        await rig.session.start()
        #expect(try #require(await rig.state).lists.turnedOff == .unavailable("Choose the file."))

        rig.turnedOff.set(.apps([]))
        await rig.session.permissionsChanged()
        #expect(try #require(await rig.state).lists.turnedOff == .apps([]))
    }

    @Test func nothingIsAskedBeforeTheSessionStartsOrAfterQuitting() async {
        let (rig, _) = rig(method: .automatic, approvals: .available)
        await rig.session.permissionsChanged()
        #expect(rig.turnedOff.timesAsked == 0, "the start asks for itself")

        await rig.session.start()
        let asked = rig.turnedOff.timesAsked
        await rig.session.tearDownForQuit()
        await rig.session.permissionsChanged()
        #expect(rig.turnedOff.timesAsked == asked, "once quitting has begun nothing is chosen again")
    }

    @Test func aResetUnderWayRefusesItNothingIsReadChosenOrPublished() async throws {
        let log = CallLog()
        let (rig, approvals) = rig(method: .automatic, log: log, approvals: .available)
        await rig.session.start()
        let gate = Gate()
        let restarter = FakeRestarter(log: log)
        restarter.whileRestarting { await gate.wait() }
        let reset = Task { await rig.session.resetIfIdle(restarter: restarter, replayJournal: {}) }
        #expect(await waitUntil { restarter.restarts == 1 })
        #expect(await rig.session.isResetting)

        let asked = rig.turnedOff.timesAsked
        let availabilityQuestions = log.count("approvals.availability") + log.count("allowlist.availability") + log.count("spacer.availability")
        let published = await rig.session.lastPublished
        // What a call that went through would have found and said.
        rig.turnedOff.set(.unavailable("Choose the file."))
        approvals.setAvailability(.needsPermission(needsTheFile))

        await rig.session.permissionsChanged()

        #expect(rig.turnedOff.timesAsked == asked, "the list of turned-off apps wasn't read")
        #expect(log.count("approvals.availability") + log.count("allowlist.availability") + log.count("spacer.availability")
            == availabilityQuestions, "no engine was asked whether it can be used, so nothing was chosen")
        #expect(await rig.session.lastPublished == published, "and nothing was published")

        gate.open()
        #expect(await reset.value == .done)
    }
}
