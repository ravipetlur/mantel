import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// What the session does while the mic or camera is in use: with the person's setting on, and the switches usable, it hides with the
/// switches (macOS's orange and green indicators stay), and goes back when the use ends. The use is a fake source's, already steadied
/// (`MediaUseTrackerTests` has the 10 seconds); every engine is a fake.
@Suite("Session: the mic and camera in use", .serialized, .timeLimit(.minutes(1)))
struct MenuBarSessionMediaTests {
    private let needsTheFile = "Choose the “Allow in the Menu Bar” file in Settings › Permissions"
    private static let mic = MediaUse([.mic: ["com.example.recorder"]])

    private struct World {
        let rig: SessionRig
        let approvals: FakeEngine
        let log: CallLog
        let media: FakeMediaSource
        var settings: HidingSettings

        var engine: HidingEngineKind? { get async { await rig.state?.engine.kind } }
        /// How many times the controller was asked to choose (it asks each engine whether it can be used).
        var choices: Int { log.count("approvals.availability") }

        /// Returns once the session has published this use.
        func published(_ use: MediaUse) async -> Bool {
            let rig = rig
            return await waitUntil { await rig.state?.mediaUse == use }
        }

        func hasSwitched(to kind: HidingEngineKind) async -> Bool {
            let rig = rig
            return await waitUntil { await rig.state?.engine.kind == kind }
        }
    }

    private func started(use: MediaUse = .idle, keepVisible: Bool = true, approvals availability: EngineAvailability = .available) async -> World {
        let log = CallLog()
        let approvals = FakeEngine(.approvals, log: log)
        approvals.setAvailability(availability)
        var settings = HidingSettings()
        settings.keepMicVisibleDuringCalls = keepVisible
        let media = FakeMediaSource(use)
        let rig = SessionRig.withEngines(
            [.allowlist: FakeEngine(.allowlist, log: log), .approvals: approvals, .spacer: FakeEngine(.spacer, log: log)],
            sections: sections(hidden: [SessionWorld.weather]), settings: settings, events: log, mediaUse: media)
        await rig.session.start()
        return World(rig: rig, approvals: approvals, log: log, media: media, settings: settings)
    }

    @Test func theSessionChoosesAgainWhenUseStartsAndEnds() async throws {
        let world = await started()
        #expect(await world.engine == .allowlist)

        world.media.send(Self.mic)
        #expect(await world.hasSwitched(to: .approvals))
        let state = try #require(await world.rig.state)
        #expect(state.engine.reason == "The mic or camera is in use, so Mantel uses System Settings switches, which leave macOS's mic and camera indicators visible.")
        #expect(state.mediaUse == Self.mic)
        #expect(world.approvals.applied.count >= 1, "the switches were given the plan")

        world.media.send(.idle)
        #expect(await world.hasSwitched(to: .allowlist))
        #expect(await world.rig.state?.mediaUse == .idle)
        #expect(world.approvals.tornDown >= 1, "and were taken down again")
    }

    @Test func aUseThatBeganBeforeTheLaunchStartsOnTheSwitches() async throws {
        let world = await started(use: Self.mic)
        #expect(await world.engine == .approvals, "the first choice already knew")
        #expect(world.log.count("allowlist.apply") == 0, "the allowlist was never in charge, so nothing flashes")
        #expect(await world.rig.state?.mediaUse == Self.mic)
    }

    @Test func aChangeAmongTheDevicesInUseChoosesNothing() async throws {
        let world = await started()
        world.media.send(Self.mic)
        #expect(await world.hasSwitched(to: .approvals))
        let choices = world.choices

        // The camera starts too, with the mic still running: both are published, and the engine stays as it is.
        let both = MediaUse([.mic: ["com.example.recorder"], .camera: ["FaceTime HD Camera"]])
        world.media.send(both)
        #expect(await world.published(both))
        #expect(world.choices == choices, "no choice reached the controller")
        #expect(await world.engine == .approvals)
    }

    @Test func withTheSettingOffNothingIsSwitched() async throws {
        let world = await started(keepVisible: false)
        let choices = world.choices

        world.media.send(Self.mic)
        #expect(await world.published(Self.mic))
        #expect(await world.engine == .allowlist)
        #expect(world.choices == choices, "no choice reached the controller")
        #expect(world.approvals.applied.isEmpty)
    }

    @Test func turningTheSettingOnOrOffDuringUseChoosesAgain() async throws {
        var world = await started(keepVisible: false, approvals: .available)
        world.media.send(Self.mic)
        #expect(await world.published(Self.mic))
        #expect(await world.engine == .allowlist)

        world.settings.keepMicVisibleDuringCalls = true
        await world.rig.session.setSettings(world.settings)
        #expect(await world.engine == .approvals, "the use is on, and now the person asked for the indicators")

        world.settings.keepMicVisibleDuringCalls = false
        await world.rig.session.setSettings(world.settings)
        #expect(await world.engine == .allowlist)
    }

    @Test func withoutTheFileGrantNothingIsSwitchedAndTheCaptionSaysSo() async throws {
        let world = await started(approvals: .needsPermission(needsTheFile))
        world.media.send(Self.mic)
        #expect(await world.published(Self.mic))
        #expect(await world.engine == .allowlist, "the switches can't be used, so nothing is switched to")
        #expect(world.approvals.applied.isEmpty)

        // What Advanced shows: the switch is off for lack of the file, and says so, with the action that has the person choose it.
        let before = AdvancedCopy.micIndicator(engine: try #require(await world.rig.state).engine)
        #expect(!before.isEnabled)
        #expect(before.offersGrant)
        #expect(before.caption.hasSuffix(AdvancedCopy.micIndicatorNeedsGrant))

        // The file is given while the use goes on: the choice is made again, and the switches take over.
        world.approvals.setAvailability(.available)
        await world.rig.session.permissionsChanged()
        #expect(await world.engine == .approvals)
        let after = AdvancedCopy.micIndicator(engine: try #require(await world.rig.state).engine)
        #expect(after.isEnabled)
        #expect(!after.offersGrant)
    }

    @Test func quittingEndsTheListenerForTheUse() async throws {
        let world = await started()
        #expect(world.media.openStreams == 1)
        await world.rig.session.tearDownForQuit()
        #expect(await waitUntil { world.media.openStreams == 0 })
    }
}
