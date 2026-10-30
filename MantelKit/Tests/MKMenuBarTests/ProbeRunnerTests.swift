import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Probe runner", .timeLimit(.minutes(1)))
struct ProbeRunnerTests {
    @Test func aReportIsWrittenToTheProbesFolderAndReturned() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistInfo)

        let files = harness.probeFiles()
        #expect(files == [ProbeReport.fileName(for: .allowlistInfo, startedAt: report.startedAt)])
        let data = try Data(contentsOf: harness.probesFolder.appending(path: files[0]))
        #expect(try JSONCoding.decoder().decode(ProbeReport.self, from: data) == report)
        #expect(report.name == .allowlistInfo)
    }

    @Test func theReportSaysWhatItWasMeasuredOn() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistInfo)
        #expect(report.environment["macOS"] == "27.0.1 (26A434)")
        #expect(report.environment["model"] == "Mac16,1")
        #expect(report.environment["mantelVersion"] == "0.1.0")
        #expect(report.environment["displays"] == DisplayLayout.desk.fingerprint.uuids.joined(separator: ","))
    }

    @Test func theStartTimeAndTheDurationAreTheClocks() async throws {
        let clock = SteppingClock()
        let harness = try ProbeHarness.make(clock: clock)
        let before = clock.now()
        let report = await harness.run(.allowlistActivate, ["hold": "5"])
        #expect(report.startedAt >= before)
        // The hold alone is 5 seconds of the clock's time.
        #expect(report.durationMs >= 5000)
        #expect(report.durationMs < 20_000)
    }

    @Test func aProbeIsRefusedOnceQuitHasBegun() async throws {
        let harness = try ProbeHarness.make()
        await harness.runner.shutDown()
        let report = await harness.run(.inventory)
        #expect(report.errors == ["Mantel is quitting"])
        #expect(report.restored)
        #expect(report.measurements.isEmpty)
        #expect(harness.probeFiles().isEmpty, "a refusal isn't a report that is kept")
    }

    @Test func aProbeThatChangesStateIsRefusedOnceQuitHasBegunAndNothingIsActivated() async throws {
        let harness = try ProbeHarness.make()
        await harness.runner.shutDown()
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors == ["Mantel is quitting"])
        #expect(harness.allowlist.calls.isEmpty)
    }

    // MARK: Only the installed copy changes anything

    private static let elsewhere = "/Users/someone/build/Mantel.app"

    private func harnessRunFromAnotherCopy() throws -> ProbeHarness {
        try ProbeHarness.make(clicks: [CGPoint(x: 3320, y: 10)]) { platform in
            platform.isInstalledCopy = false
            platform.copyPath = Self.elsewhere
        }
    }

    @Test(arguments: ProbeRunner.stateChangingProbes)
    func aProbeThatChangesStateIsRefusedFromACopyThatIsNotInApplications(name: ProbeName) async throws {
        let harness = try harnessRunFromAnotherCopy()
        let approvals = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": [ProbeHarness.fixtureID: true]])
        let layout = try await harness.installFile(.menuBarLayout, [LayoutKeys.trailingPositions: ["status:\(ProbeHarness.fixtureID)::x": 1]])
        let approvalsBefore = try Data(contentsOf: approvals)
        let layoutBefore = try Data(contentsOf: layout)

        let report = await harness.run(name)

        #expect(report.errors == ["Run this probe from the copy in /Applications. This copy is at \(Self.elsewhere)."])
        #expect(report.restored)
        #expect(report.measurements.isEmpty)
        #expect(harness.allowlist.calls.isEmpty, "nothing was activated")
        #expect(harness.taps.made.isEmpty, "no tap was made")
        #expect(try Data(contentsOf: approvals) == approvalsBefore, "no file was written")
        #expect(try Data(contentsOf: layout) == layoutBefore)
        #expect(await harness.journal.records().isEmpty)
        #expect(harness.probeFiles().isEmpty, "a refusal isn't a report that is kept")
    }

    @Test func aRefusalFromAnotherCopyLeavesTheNextProbeFree() async throws {
        let harness = try harnessRunFromAnotherCopy()
        _ = await harness.run(.allowlistActivate)
        // The "one at a time" lock wasn't taken by the refusal: a second refusal says the same, not "another probe is changing".
        let again = await harness.run(.layoutMove)
        #expect(again.errors == ["Run this probe from the copy in /Applications. This copy is at \(Self.elsewhere)."])
    }

    @Test(arguments: ProbeName.allCases.filter { !ProbeRunner.changesState($0) })
    func aProbeThatOnlyReadsIsNotRefusedForTheCopyItRunsFrom(name: ProbeName) async throws {
        let harness = try harnessRunFromAnotherCopy()
        let report = await harness.run(name, ["phase": "before"])
        #expect(report.name == name)
        #expect(!report.errors.contains { $0.hasPrefix("Run this probe from the copy in /Applications.") })
    }

    @Test(arguments: ProbeRunner.stateChangingProbes)
    func aProbeThatChangesStateIsNotRefusedForTheCopyItRunsFrom(name: ProbeName) async throws {
        let harness = try ProbeHarness.make(clicks: [CGPoint(x: 3320, y: 10)])
        let report = await harness.run(name)
        #expect(!report.errors.contains { $0.hasPrefix("Run this probe from the copy in /Applications.") })
        #expect(!report.errors.contains(ProbeRunner.platformTestOffMessage))
    }

    @Test func theProbesThatChangeStateAreTheNineTheRunnerGates() {
        #expect(Set(ProbeRunner.stateChangingProbes)
                == [.allowlistActivate, .approvalsToggle, .layoutMove, .clickReplay, .revealLatency, .approvalsFlip,
                    .clickPath, .layoutOrder, .spacing])
    }

    @Test func newStateChangingProbesAreGated() async throws {
        let newOnes: [ProbeName] = [.clickPath, .layoutOrder, .spacing]
        #expect(newOnes.allSatisfy(ProbeRunner.changesState))
        #expect(!ProbeRunner.changesState(.iconCapture) && !ProbeRunner.changesState(.layoutMap), "these two only read")

        for name in newOnes {
            // Without "Enable platform test": refused, and nothing is clicked, written, relaunched or told.
            let off = try ProbeHarness.make(platformTestEnabled: false)
            let refused = await off.run(name)
            #expect(refused.errors == [ProbeRunner.platformTestOffMessage], "\(name.rawValue)")
            #expect(refused.restored)
            #expect(refused.measurements.isEmpty)
            #expect(off.allowlist.calls.isEmpty && off.poster.clicks.isEmpty && off.poster.keys.isEmpty)
            #expect(off.presser.pressed.isEmpty && off.relauncher.asked.isEmpty && off.notifier.sent.isEmpty)
            #expect(off.preferences.writes.isEmpty)
            #expect(await off.journal.records().isEmpty)

            // From a copy that isn't the one in /Applications.
            let elsewhere = try ProbeHarness.make { platform in
                platform.isInstalledCopy = false
                platform.copyPath = Self.elsewhere
            }
            let other = await elsewhere.run(name)
            #expect(other.errors == ["Run this probe from the copy in /Applications. This copy is at \(Self.elsewhere)."], "\(name.rawValue)")

            // While a reset is under way.
            let resetting = try ProbeHarness.make()
            resetting.resetUnderWay.set(true)
            let waiting = await resetting.run(name)
            #expect(waiting.errors == [ProbeRunner.resetUnderWayMessage], "\(name.rawValue)")
            #expect(await resetting.runner.isChangingMenuBar == false)
        }
    }

    // MARK: Enable platform test

    @Test(arguments: ProbeRunner.stateChangingProbes)
    func stateChangingProbeRefusedWhenSwitchOff(name: ProbeName) async throws {
        let harness = try ProbeHarness.make(clicks: [CGPoint(x: 3320, y: 10)], platformTestEnabled: false)
        let approvals = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": [ProbeHarness.fixtureID: true]])
        let layout = try await harness.installFile(.menuBarLayout, [LayoutKeys.trailingPositions: ["status:\(ProbeHarness.fixtureID)::x": 1]])
        let approvalsBefore = try Data(contentsOf: approvals)
        let layoutBefore = try Data(contentsOf: layout)

        let report = await harness.run(name, ["flag-path": "k:allowed"])

        #expect(report.errors == ["Turn on “Enable platform test” in Settings › Diagnostics first."])
        #expect(report.restored)
        #expect(report.measurements.isEmpty)
        #expect(harness.allowlist.calls.isEmpty, "nothing was activated")
        #expect(harness.taps.made.isEmpty, "no tap was made")
        #expect(try Data(contentsOf: approvals) == approvalsBefore, "no file was written")
        #expect(try Data(contentsOf: layout) == layoutBefore)
        #expect(await harness.journal.records().isEmpty)
        #expect(harness.probeFiles().isEmpty, "a refusal isn't a report that is kept")
        #expect(await harness.runner.isChangingMenuBar == false, "and it didn't take the one-at-a-time place")
    }

    @Test(arguments: ProbeName.allCases.filter { !ProbeRunner.changesState($0) })
    func readingProbeRunsWhenSwitchOff(name: ProbeName) async throws {
        let harness = try ProbeHarness.make(platformTestEnabled: false)
        let report = await harness.run(name, ["phase": "before"])
        #expect(report.name == name)
        #expect(!report.errors.contains(ProbeRunner.platformTestOffMessage))
    }

    @Test func theSwitchIsAskedEachTimeAProbeIsRunAndTurningItOnNeedsNoNewRunner() async throws {
        let harness = try ProbeHarness.make(platformTestEnabled: false)
        let refused = await harness.run(.allowlistActivate)
        #expect(refused.errors == [ProbeRunner.platformTestOffMessage])

        harness.platformTest.set(true)
        let allowed = await harness.run(.allowlistActivate)
        #expect(allowed.errors.isEmpty)
        #expect(harness.allowlist.calls.count == 1)

        harness.platformTest.set(false)
        let again = await harness.run(.allowlistActivate)
        #expect(again.errors == [ProbeRunner.platformTestOffMessage])
    }

    @Test func aStateChangingProbeIsRefusedWhileAResetIsUnderWay() async throws {
        // The reset puts back the journal and restarts the menu bar's process: both would happen in the middle of what the probe measures.
        let harness = try ProbeHarness.make()
        harness.resetUnderWay.set(true)

        for name in ProbeRunner.stateChangingProbes {
            let refused = await harness.run(name, ["flag-path": "k:allowed"])
            #expect(refused.errors == [ProbeRunner.resetUnderWayMessage], "\(name.rawValue)")
            #expect(refused.restored)
        }
        #expect(ProbeRunner.resetUnderWayMessage == "A reset is already under way.")
        #expect(harness.allowlist.calls.isEmpty, "nothing was activated")
        #expect(harness.taps.made.isEmpty, "no tap was made")
        #expect(await harness.journal.records().isEmpty)
        #expect(await harness.runner.isChangingMenuBar == false, "and none of them took the one-at-a-time place")

        // Probes that only read go on, and once the reset is over a state-changing one runs.
        let reading = await harness.run(.overflow)
        #expect(!reading.errors.contains(ProbeRunner.resetUnderWayMessage))
        harness.resetUnderWay.set(false)
        let allowed = await harness.run(.allowlistActivate)
        #expect(allowed.errors.isEmpty)
    }

    @Test func aCopyThatIsNotInApplicationsIsToldSoBeforeTheSwitch() async throws {
        // Turning the switch on can't help it, so the reason that can't be fixed from Settings comes first.
        let harness = try ProbeHarness.make(platformTestEnabled: false) { platform in
            platform.isInstalledCopy = false
            platform.copyPath = Self.elsewhere
        }
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors == ["Run this probe from the copy in /Applications. This copy is at \(Self.elsewhere)."])
    }

    @Test func aSecondStateChangingProbeIsRefusedWhileOneRuns() async throws {
        let harness = try ProbeHarness.make()
        let gate = Gate()
        harness.allowlist.holdActivations(until: gate)

        let first = Task { await harness.run(.allowlistActivate) }
        await harness.allowlist.entered.wait()

        let second = await harness.run(.allowlistActivate)
        #expect(second.errors == ["Another probe is changing the menu bar; try again when it finishes"])
        #expect(second.restored)
        #expect(harness.allowlist.calls.count == 1, "the second never reached the allowlist")

        gate.open()
        let finished = await first.value
        #expect(finished.errors.isEmpty)
        #expect(finished.restored)

        // Once it is done, the next one runs.
        let third = await harness.run(.allowlistActivate)
        #expect(third.errors.isEmpty)
    }

    @Test func theRunnerSaysWhetherAProbeIsChangingTheMenuBarRightNow() async throws {
        let harness = try ProbeHarness.make()
        #expect(await harness.runner.isChangingMenuBar == false)
        let gate = Gate()
        harness.allowlist.holdActivations(until: gate)

        let first = Task { await harness.run(.allowlistActivate) }
        await harness.allowlist.entered.wait()
        #expect(await harness.runner.isChangingMenuBar, "while the probe holds its change")
        // One that only reads doesn't change anything.
        _ = await harness.run(.overflow)
        #expect(await harness.runner.isChangingMenuBar)

        gate.open()
        _ = await first.value
        #expect(await harness.runner.isChangingMenuBar == false, "and not after it has put it back")

        // A probe that was refused never changed anything.
        _ = await harness.run(.allowlistActivate, ["apps": "com.apple.Safari"])
        #expect(await harness.runner.isChangingMenuBar == false)
    }

    @Test func aProbeThatOnlyReadsRunsWhileAStateChangingOneDoes() async throws {
        let harness = try ProbeHarness.make()
        let gate = Gate()
        harness.allowlist.holdActivations(until: gate)

        let first = Task { await harness.run(.allowlistActivate) }
        await harness.allowlist.entered.wait()
        let reading = await harness.run(.overflow)
        #expect(reading.errors.isEmpty)

        gate.open()
        _ = await first.value
    }

    @Test func aRefusedProbeLeavesTheNextOneFree() async throws {
        // A refusal (the safety rule) must not leave the "one at a time" lock held.
        let harness = try ProbeHarness.make()
        let refused = await harness.run(.allowlistActivate, ["apps": "com.apple.Safari"])
        #expect(!refused.errors.isEmpty)
        let next = await harness.run(.allowlistActivate)
        #expect(next.errors.isEmpty)
    }

    @Test func shuttingDownCancelsARunningProbeAndItPutsEverythingBack() async throws {
        // A clock the test steps, so that the probe is held in its hold.
        let clock = FakeClock()
        let harness = try ProbeHarness.make(clock: clock)
        let running = Task { await harness.run(.allowlistActivate, ["hold": "30"]) }
        await clock.waitForSleepers(1)
        #expect(harness.allowlist.live == 1, "the probe is holding the allowlist")

        await harness.runner.shutDown()
        let report = await running.value

        #expect(harness.allowlist.live == 0)
        #expect(harness.allowlist.invalidations == 1)
        #expect(harness.hidden.all.isEmpty)
        #expect(report.restored)
        #expect(report.notes.contains { $0.contains("cut short") })
    }

    @Test func theLatestReportOfAProbeIsReadBackFromTheFolder() async throws {
        let clock = SteppingClock()
        let harness = try ProbeHarness.make(clock: clock)
        let first = await harness.run(.overflow)
        clock.advance(by: .seconds(60))
        let second = await harness.run(.overflow)
        #expect(second.startedAt > first.startedAt)
        #expect(await harness.runner.latestReport(of: .overflow) == second)
        #expect(await harness.runner.latestReport(of: .capture) == nil)
        #expect(await harness.runner.latestReports().keys.sorted { $0.rawValue < $1.rawValue } == [.overflow])
    }

    @Test func everyProbeTheCommandLineKnowsHasAnImplementation() async throws {
        // Every name runs without a crash and says who it is; the system is all fakes. A report is kept for each that ran (a refusal
        // isn't one: a probe given nothing it needs says so in its errors, and is still a report).
        let harness = try ProbeHarness.make()
        for name in ProbeName.allCases {
            let report = await harness.run(name, ["phase": "before"])
            #expect(report.name == name)
        }
        #expect(harness.probeFiles().count >= ProbeName.allCases.count)
    }
}
