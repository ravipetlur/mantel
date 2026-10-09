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
    func aProbeThatOnlyReadsRunsFromAnyCopy(name: ProbeName) async throws {
        let harness = try harnessRunFromAnotherCopy()
        let report = await harness.run(name, ["phase": "before"])
        #expect(report.name == name)
        #expect(!report.errors.contains { $0.hasPrefix("Run this probe from the copy in /Applications.") })
    }

    @Test(arguments: ProbeRunner.stateChangingProbes)
    func aProbeThatChangesStateRunsFromTheInstalledCopy(name: ProbeName) async throws {
        let harness = try ProbeHarness.make(clicks: [CGPoint(x: 3320, y: 10)])
        let report = await harness.run(name)
        #expect(!report.errors.contains { $0.hasPrefix("Run this probe from the copy in /Applications.") })
    }

    @Test func theFourProbesThatChangeStateAreTheOnesTheRunnerRefusesFromAnotherCopy() {
        #expect(Set(ProbeRunner.stateChangingProbes) == [.allowlistActivate, .approvalsToggle, .layoutMove, .clickReplay])
    }

    @Test func onlyTheCopyDirectlyInApplicationsIsTheInstalledCopy() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        func isInstalled(_ path: String) -> Bool {
            ProbePlatform.isInstalledCopy(at: URL(filePath: path, directoryHint: .isDirectory), home: home)
        }
        #expect(isInstalled("/Applications/Mantel.app"))
        #expect(!isInstalled("/Users/someone/Applications/Mantel.app"), "the person's own Applications is not where macOS honours the allowlist")
        #expect(!isInstalled("/Applications/Utilities/Mantel.app"))
        #expect(!isInstalled("/Users/someone/dev/Mantel/build/Debug/Mantel.app"))
        #expect(!isInstalled("/private/var/folders/xx/AppTranslocation/ABC/d/Mantel.app"))
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
        // The thirteen names run without a crash and say who they are; the system is all fakes.
        let harness = try ProbeHarness.make()
        for name in ProbeName.allCases {
            let report = await harness.run(name, ["phase": "before"])
            #expect(report.name == name)
        }
        #expect(harness.probeFiles().count >= 13)
    }
}
